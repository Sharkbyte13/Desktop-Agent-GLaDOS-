#!/usr/bin/env python3
"""
GLaDOS voice input daemon.

Microphone -> wake word -> endpointed capture -> speech recognition -> a file
the overlay picks up. Everything runs locally; no audio and no transcript ever
leaves this machine, and nothing is written to disk except the transcript text
itself (audio is kept in a ring buffer in memory and discarded).

There are two ways to get her attention.

The old way is a trained wake-word model: fast, cheap, and locked to the one
phrase it was trained on. The new way is an open microphone - every burst of
speech is transcribed and matched against the phrases in wake_phrases.json, so
"hey GLaDOS", "wake up GLaDOS" and "good morning GLaDOS" all work, each with
its own mood, and the list is a text file rather than a neural network. Whisper
spells her name a dozen different ways; the matcher knows them all.

Nothing leaves the machine either way, and the open microphone only transcribes
bursts of speech, never silence. A burst that does not contain her name is
discarded without being logged.

State machine:

    IDLE       waiting. Frames go to the wake model, and to the endpointer
    SCAN       a burst of speech is being collected to check for a wake phrase
    ARMED      wake detected; record until the speaker stops
    THINKING   transcribe, write the transcript, return to IDLE

Two lock files, both written by the overlay, suppress listening:

    speaking.lock   she is talking; otherwise she hears herself and answers
                    her own voice, forever
    mute.lock       the user muted the mic from the tray

Transcripts land in inbox/<epoch_ms>.json as {"text": ..., "score": ...}.
A file queue rather than a socket: no port, no handshake, survives either
side restarting, and trivial to inspect when something misbehaves.
"""

import argparse
import collections
import json
import logging
import os
import queue
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wake_match

SAMPLE_RATE = 16000
FRAME = 1280                 # 80 ms, the frame size openWakeWord expects
MAX_UTTERANCE_S = 12.0

# A quiet aside from two metres away is still speech. 0.30s of it is enough to
# be worth transcribing; below that it is a chair creaking.
MIN_SPEECH_S = 0.30

# These two were the same number, which was a bug. HANGOVER_S is how much
# silence means "you have finished talking"; LISTEN_WINDOW_S is how long to
# wait for you to START talking after the wake word. Sharing one 0.9s value
# meant that pausing after "Hey GLaDOS" - exactly what a person does, and
# exactly what I told the user to do - made it give up before they spoke.
HANGOVER_S = 0.9
LISTEN_WINDOW_S = 5.0

PREROLL_S = 0.25             # audio kept from before the wake word fired

# The open-microphone path. A burst shorter than MIN_SPEECH_S is a cough; one
# longer than SCAN_MAX_S is a conversation, and the wake phrase would be at the
# front of it anyway.
SCAN_HANGOVER_S = 0.45
SCAN_MAX_S = 4.5
SCAN_COOLDOWN_S = 0.6

# Whisper decodes towards what is likely in general English, not what is likely
# to be said to a desktop assistant: "start a timer" came back as "Sudden
# timer", which is ordinary English and useless here. An initial prompt biases
# the decoder towards the vocabulary that actually gets used. Two of them,
# because the two passes are listening for different things.
WAKE_PROMPT = ("Hey GLaDOS. Wake up GLaDOS. Good morning GLaDOS. "
               "GLaDOS, are you there?")
COMMAND_PROMPT = ("Set a timer for 30 seconds. Set a timer for 25 minutes. "
                  "Cancel the timer. Remind me at 5:30. What time is it? "
                  "What is on my desktop? Read my clipboard. Open Notepad. "
                  "Search my Documents folder. Add a note. GLaDOS.")

log = logging.getLogger("glados-voice")


def pid_alive(pid):
    """True if a process with this id is running."""
    if os.name == "nt":
        import ctypes
        PROCESS_QUERY_LIMITED = 0x1000
        h = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED, False, pid)
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(h)
        return bool(ok) and code.value == 259          # STILL_ACTIVE
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def chirp(kind):
    """Short tone so you know she heard the wake word and is waiting.

    Without this there is no way to tell 'listening' from 'not running',
    which is the single most disorienting thing about a voice assistant.
    """
    try:
        import winsound
        if kind == "wake":
            winsound.Beep(880, 90)
        elif kind == "got":
            winsound.Beep(1320, 70)
        elif kind == "giveup":
            winsound.Beep(440, 120)
    except Exception:
        pass


# openWakeWord fires at the END of the phrase, so the captured audio starts
# mid-wake-word and Whisper transcribes it. The first successful capture came
# back as "service or a Gladys." - the wake word, not the command.
_WAKE_PREFIX = re.compile(
    r"""^\s*(?:
        (?:hey|hay|hi|ok|okay|a|uh)?\s*
        (?:jarvis|glados|gladys|gladiss|gladdis|glad\s*os+|service\s*or\s*a\s*gladys)
        |service\s*or\s*a\s*gladys
    )\s*[,.!?-]*\s*""",
    re.IGNORECASE | re.VERBOSE)


def strip_wake_prefix(text):
    out = _WAKE_PREFIX.sub("", text, count=1)
    return out.strip() or text.strip()


# ---------------------------------------------------------------------------
# Endpointing
# ---------------------------------------------------------------------------

class Endpointer:
    """Decides when the speaker has stopped.

    Energy against an adaptive noise floor. Calibrates from the room during
    idle frames, so a noisy desk raises the bar instead of jamming it open.
    Whisper's own VAD cleans up whatever slips through.
    """

    # How far above the room's noise floor counts as speech. Lower is more
    # sensitive: 9 dB wanted a raised voice, 6 dB hears a mutter. Too low and
    # a fan becomes a conversation, which the wake phrase then has to reject.
    def __init__(self, margin_db=6.0):
        self.margin_db = margin_db
        self.floor = None
        self._recent = collections.deque(maxlen=50)   # ~4s of idle frames

    @staticmethod
    def _db(frame):
        import math
        rms = float((frame.astype("float32") ** 2).mean()) ** 0.5
        if rms <= 0:
            return -120.0
        return 20.0 * math.log10(rms / 32768.0 + 1e-12)

    def observe_idle(self, frame):
        d = self._db(frame)
        self._recent.append(d)
        if len(self._recent) >= 10:
            ordered = sorted(self._recent)
            self.floor = ordered[len(ordered) // 2]      # median
        return d

    def is_speech(self, frame):
        d = self._db(frame)
        floor = self.floor if self.floor is not None else -55.0
        return d > (floor + self.margin_db), d


# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------

class Listener:
    def __init__(self, root, args):
        self.root = root
        self.args = args
        self.inbox = os.path.join(root, "inbox")
        os.makedirs(self.inbox, exist_ok=True)
        self.speaking_lock = os.path.join(root, "speaking.lock")
        self.mute_lock = os.path.join(root, "mute.lock")
        self.state_path = os.path.join(root, "state.json")
        self.pid_path = os.path.join(root, "listener.pid")
        self.audio_q = queue.Queue(maxsize=200)
        self.stop = threading.Event()
        self.wake = None
        self.stt = None
        self._state = None
        self._stt_lock = threading.Lock()

        # Open-microphone wake phrases.
        self.phrase_path = os.path.join(root, "wake_phrases.json")
        self.phrases = []
        self.phrase_stamp = None
        self.scan_busy = False
        # A window during which she answers without being named again: she has
        # asked you something and is waiting for the reply.
        self.followup_path = os.path.join(root, "followup.json")
        self.followup_until = 0.0
        self.followup_grace = 30.0
        self.followup_seen = None
        self.arm_request = None          # a mood, set by the scan thread
        self.pending_mood = None
        self.pending_phrase = None
        self.last_scan = 0.0
        self.load_phrases()

    # -- wake phrases -----------------------------------------------------
    def load_phrases(self):
        """(Re)read the phrase file. Called at startup and whenever it changes,
        so editing the list takes effect without a restart."""
        raw, err = wake_match.load_phrases(self.phrase_path)
        if err:
            log.warning("wake_phrases.json unusable (%s); using the built-in list", err)
        self.phrases = wake_match.prepare(raw)
        try:
            self.phrase_stamp = os.path.getmtime(self.phrase_path)
        except OSError:
            self.phrase_stamp = None
        log.info("wake phrases: %d (%s)", len(self.phrases),
                 ", ".join(sorted({p["mood"] for p in self.phrases})))

    # -- follow-up --------------------------------------------------------
    def read_followup(self):
        """The overlay opens this window when she asks you a question.

        The clock is refreshed while she is still talking, so the thirty
        seconds are thirty seconds of YOUR silence, not hers.
        """
        try:
            stamp = os.path.getmtime(self.followup_path)
        except OSError:
            if self.followup_until:
                log.info("follow-up window closed")
            self.followup_until = 0.0
            self.followup_seen = None
            return False

        if stamp != self.followup_seen:
            self.followup_seen = stamp
            try:
                with open(self.followup_path, encoding="utf-8") as f:
                    data = json.load(f)
                self.followup_grace = float(data.get("grace", 30.0))
            except (OSError, ValueError):
                self.followup_grace = 30.0
            self.followup_until = time.time() + self.followup_grace
            log.info("follow-up window open for %.0fs - no wake phrase needed",
                     self.followup_grace)

        if time.time() > self.followup_until:
            self.close_followup("timed out")
            return False
        return True

    def close_followup(self, why=""):
        if not self.followup_until:
            return
        self.followup_until = 0.0
        self.followup_seen = None
        try:
            os.remove(self.followup_path)
        except OSError:
            pass
        log.info("follow-up window closed%s", (" (" + why + ")") if why else "")

    def phrases_changed(self):
        try:
            stamp = os.path.getmtime(self.phrase_path)
        except OSError:
            return False
        return stamp != self.phrase_stamp

    # -- single instance ---------------------------------------------------
    def claim_singleton(self):
        """Refuse to start if another listener is alive.

        Two listeners both open the microphone, both detect the wake word and
        both write transcripts. The symptom is duplicated and interleaved
        behaviour that looks like the thing is broken, which is what happened.
        """
        other = None
        try:
            with open(self.pid_path) as f:
                other = int(f.read().strip())
        except (OSError, ValueError):
            other = None

        if other and other != os.getpid() and pid_alive(other):
            log.error("another listener is already running (pid %d). Exiting.", other)
            log.error("Use Stop-Voice.cmd first, or Restart-Voice.cmd.")
            return False

        try:
            with open(self.pid_path, "w") as f:
                f.write(str(os.getpid()))
        except OSError as exc:
            log.warning("could not write pid file: %s", exc)
        return True

    def release_singleton(self):
        try:
            with open(self.pid_path) as f:
                if int(f.read().strip()) == os.getpid():
                    os.remove(self.pid_path)
        except (OSError, ValueError):
            pass

    # -- state, so the overlay can show whether she is listening -----------
    def set_state(self, state, detail=""):
        if state == self._state:
            return
        self._state = state
        payload = {"state": state, "detail": detail, "ts": time.time(),
                   "pid": os.getpid(),
                   "wake": self.wake_description(),
                   "phrases": len(self.phrases)}
        try:
            tmp = self.state_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f)
            os.replace(tmp, self.state_path)
        except OSError:
            pass

    def wake_description(self):
        bits = []
        if self.phrases and self.args.open_mic:
            bits.append("%d phrases" % len(self.phrases))
        if self.wake is not None:
            bits.append(os.path.basename(self.args.wake_model or self.args.wake_builtin))
        return " + ".join(bits) if bits else "nothing"

    # -- suppression ------------------------------------------------------
    def suppressed(self):
        if os.path.exists(self.mute_lock):
            return "muted"
        if os.path.exists(self.speaking_lock):
            # Stale lock guard: if she crashed mid-sentence the lock would
            # otherwise deafen the listener permanently.
            try:
                age = time.time() - os.path.getmtime(self.speaking_lock)
                if age > 120:
                    os.remove(self.speaking_lock)
                    return None
            except OSError:
                return None
            return "speaking"
        return None

    # -- models -----------------------------------------------------------
    def load_models(self):
        import numpy as np  # noqa: F401  (imported early so failures are obvious)

        # The trained wake model is now optional. With the phrase list doing
        # the work it is a fast path rather than the only way in, and on a
        # machine with no custom model it was only ever listening for the
        # word "Jarvis", which is not her name.
        self.wake = None
        if self.args.use_wake_model:
            try:
                from openwakeword.model import Model as WakeModel
                kwargs = {"inference_framework": "onnx"}
                if self.args.wake_model and os.path.isfile(self.args.wake_model):
                    kwargs["wakeword_models"] = [self.args.wake_model]
                    log.info("wake model: %s", self.args.wake_model)
                else:
                    kwargs["wakeword_models"] = [self.args.wake_builtin]
                    log.info("wake model: built-in %r (no custom model at %s)",
                             self.args.wake_builtin, self.args.wake_model)
                self.wake = WakeModel(**kwargs)
            except Exception as exc:                              # noqa: BLE001
                log.warning("wake model unavailable (%s); phrases only", exc)
                self.wake = None
        else:
            log.info("wake model off; listening for the phrases in wake_phrases.json")

        if self.wake is None and not self.args.open_mic:
            log.error("no wake model and the open microphone is off: nothing can wake her")
            raise SystemExit(5)

        from faster_whisper import WhisperModel
        log.info("loading whisper %s on %s (%s)",
                 self.args.whisper_model, self.args.whisper_device, self.args.whisper_compute)
        self.stt = WhisperModel(self.args.whisper_model,
                                device=self.args.whisper_device,
                                compute_type=self.args.whisper_compute)
        log.info("models ready")

    # -- audio ------------------------------------------------------------
    def _audio_cb(self, indata, frames, time_info, status):
        if status:
            log.debug("audio status: %s", status)
        try:
            self.audio_q.put_nowait(bytes(indata))
        except queue.Full:
            pass

    def run(self):
        import numpy as np
        try:
            import sounddevice as sd
        except Exception as exc:                                  # noqa: BLE001
            log.error("audio system unavailable: %s", exc)
            raise SystemExit(4)

        self.load_models()

        device = self.args.device
        if device is not None and str(device).isdigit():
            device = int(device)

        log.info("opening microphone (device=%s)", device if device is not None else "default")
        try:
            stream = sd.RawInputStream(samplerate=SAMPLE_RATE, blocksize=FRAME,
                                       dtype="int16", channels=1,
                                       device=device, callback=self._audio_cb)
        except Exception as exc:                                  # noqa: BLE001
            log.error("could not open the microphone: %s", exc)
            log.error("check the Windows input device and the microphone privacy setting")
            raise SystemExit(4)

        endp = Endpointer(margin_db=self.args.mic_margin)
        preroll = collections.deque(maxlen=max(1, int(PREROLL_S * SAMPLE_RATE / FRAME)))
        state = "IDLE"
        captured = []
        silence_frames = 0
        speech_frames = 0
        armed_frames = 0
        wake_score = 0.0
        was_suppressed = None
        self.set_state("idle")

        with stream:
            log.info("listening. say the wake word.")
            while not self.stop.is_set():
                try:
                    raw = self.audio_q.get(timeout=0.5)
                except queue.Empty:
                    continue

                frame = np.frombuffer(raw, dtype=np.int16)

                why = self.suppressed()
                if why:
                    # Her own voice does not eat your thirty seconds.
                    if self.followup_until and why == "speaking":
                        self.followup_until = time.time() + self.followup_grace
                    if why != was_suppressed:
                        log.info("suppressed (%s)", why)
                        was_suppressed = why
                        self.set_state("suppressed", why)
                    # Drop the wake model's history so the tail of her own
                    # sentence cannot score against the next real one.
                    if state != "IDLE":
                        state, captured, speech_frames, silence_frames = "IDLE", [], 0, 0
                    try:
                        self.wake.reset()
                    except Exception:
                        pass
                    continue
                if was_suppressed:
                    log.info("listening again")
                    was_suppressed = None
                    self.set_state("idle")

                if state == "IDLE":
                    # The scan thread asks for the microphone by leaving a mood
                    # here; the loop owns the state machine, so it does the
                    # transition itself.
                    if self.arm_request is not None:
                        self.pending_mood = self.arm_request
                        self.arm_request = None
                        state = "ARMED"
                        captured = list(preroll)
                        speech_frames = silence_frames = armed_frames = 0
                        wake_score = 1.0
                        self.set_state("armed")
                        continue

                    if self.phrases_changed():
                        self.load_phrases()

                    follow = self.read_followup()
                    if follow and self._state != "followup":
                        self.set_state("followup", "waiting for your answer")
                    elif not follow and self._state == "followup":
                        self.set_state("idle")

                    speaking_now, _ = endp.is_speech(frame)
                    if not speaking_now:
                        endp.observe_idle(frame)
                    preroll.append(frame)

                    # Open microphone: collect the burst and let Whisper decide
                    # whether it was addressed to her.
                    if (self.args.open_mic and speaking_now and not self.scan_busy
                            and (time.time() - self.last_scan) > SCAN_COOLDOWN_S):
                        state = "SCAN"
                        scan_frames = list(preroll)
                        scan_speech = 1
                        scan_silence = 0
                        continue

                    if self.wake is None:
                        continue
                    try:
                        scores = self.wake.predict(frame)
                    except Exception as exc:                      # noqa: BLE001
                        log.exception("wake model failed: %s", exc)
                        continue
                    best_name, best = None, 0.0
                    for name, score in scores.items():
                        if score > best:
                            best_name, best = name, float(score)
                    if best >= self.args.threshold:
                        log.info("wake: %s (%.2f) - listening for up to %.0fs",
                                 best_name, best, LISTEN_WINDOW_S)
                        wake_score = best
                        state = "ARMED"
                        self.pending_mood = "neutral"
                        self.pending_phrase = best_name
                        captured = list(preroll)
                        speech_frames = silence_frames = 0
                        armed_frames = 0
                        self.set_state("armed")
                        if not self.args.no_chirp:
                            threading.Thread(target=chirp, args=("wake",), daemon=True).start()
                        try:
                            self.wake.reset()
                        except Exception:
                            pass

                elif state == "SCAN":
                    scan_frames.append(frame)
                    speaking_now, _ = endp.is_speech(frame)
                    if speaking_now:
                        scan_speech += 1
                        scan_silence = 0
                    else:
                        scan_silence += 1

                    secs = len(scan_frames) * FRAME / SAMPLE_RATE
                    speech_secs = scan_speech * FRAME / SAMPLE_RATE
                    silent_secs = scan_silence * FRAME / SAMPLE_RATE

                    if silent_secs >= SCAN_HANGOVER_S or secs >= SCAN_MAX_S:
                        audio = np.concatenate(scan_frames).astype("float32") / 32768.0
                        scan_frames = []
                        state = "IDLE"
                        self.last_scan = time.time()
                        if speech_secs >= MIN_SPEECH_S:
                            self.scan_busy = True
                            threading.Thread(target=self._scan, args=(audio,),
                                             daemon=True).start()

                elif state == "ARMED":
                    captured.append(frame)
                    armed_frames += 1
                    speaking, _ = endp.is_speech(frame)
                    if speaking:
                        speech_frames += 1
                        silence_frames = 0
                    else:
                        silence_frames += 1

                    secs = len(captured) * FRAME / SAMPLE_RATE
                    armed_secs = armed_frames * FRAME / SAMPLE_RATE
                    silent_secs = silence_frames * FRAME / SAMPLE_RATE
                    enough = (speech_frames * FRAME / SAMPLE_RATE) >= MIN_SPEECH_S

                    # Once you have started talking, 0.9s of silence ends it.
                    # Before you have started, you get the full window - a
                    # person naturally pauses after the wake word.
                    finished = enough and silent_secs >= HANGOVER_S
                    gave_up = (not enough) and armed_secs >= LISTEN_WINDOW_S

                    if finished or secs >= MAX_UTTERANCE_S:
                        audio = np.concatenate(captured).astype("float32") / 32768.0
                        captured = []
                        state = "IDLE"
                        preroll.clear()
                        self.set_state("thinking")
                        if not self.args.no_chirp:
                            threading.Thread(target=chirp, args=("got",), daemon=True).start()
                        threading.Thread(target=self._transcribe,
                                         args=(audio, wake_score, self.pending_mood,
                                               self.pending_phrase),
                                         daemon=True).start()
                        self.pending_mood = None
                        self.pending_phrase = None
                    elif gave_up:
                        log.info("wake fired but you never spoke (waited %.1fs)", armed_secs)
                        if self.pending_mood:
                            # You said her name and nothing else. That is still
                            # something to answer.
                            self.dispatch("", 1.0, self.pending_mood,
                                          self.pending_phrase, wake_only=True)
                        self.pending_mood = None
                        self.pending_phrase = None
                        captured = []
                        state = "IDLE"
                        preroll.clear()
                        self.set_state("idle")
                        if not self.args.no_chirp:
                            threading.Thread(target=chirp, args=("giveup",), daemon=True).start()

    # -- recognition ------------------------------------------------------
    def _run_stt(self, audio, prompt=None):
        """One transcription. WhisperModel is not safe to call concurrently."""
        with self._stt_lock:
            segments, _info = self.stt.transcribe(
                audio, language="en", vad_filter=True, beam_size=1,
                condition_on_previous_text=False,
                initial_prompt=prompt)
            return " ".join(s.text.strip() for s in segments).strip()

    def _scan(self, audio):
        """Open-microphone path: was that burst addressed to her?

        Anything that does not match a wake phrase is dropped here and never
        written anywhere. The transcript of an unmatched burst is logged only
        at debug level, and truncated, because it is whatever happened to be
        said in the room.
        """
        t0 = time.time()
        try:
            text = self._run_stt(audio, WAKE_PROMPT)
        except Exception:                                         # noqa: BLE001
            log.exception("wake scan failed")
            return
        finally:
            self.scan_busy = False
            self.last_scan = time.time()

        if not text:
            return
        hit = wake_match.match_wake(text, self.phrases,
                                    threshold=self.args.phrase_threshold)
        if not hit:
            # Inside a follow-up window she has just asked you something, so
            # anything said next is the answer - no need to say her name again
            # to finish a conversation she started.
            if self.followup_until and time.time() <= self.followup_until:
                log.info("follow-up: %r in %.1fs", text, time.time() - t0)
                self.close_followup("answered")
                self.dispatch(wake_match.fix_command_text(text), 1.0, "followup", "(follow-up)")
                return
            log.debug("not for me: %r (%.1fs)", text[:40], time.time() - t0)
            return

        # Naming her inside the window is allowed; it just closes it.
        self.close_followup("wake phrase used instead")

        # The raw transcript goes in the log too. Without it a false wake is
        # unexplainable after the fact: the log said which phrase matched and
        # at what score, but not what Whisper thought it heard, and the audio
        # was gone. This adds nothing that is not already written to
        # glados.log when the burst is dispatched.
        log.info("wake phrase %r (%.2f, %s) in %.1fs - heard: %r",
                 hit["phrase"], hit["score"], hit["mood"], time.time() - t0, text)
        if self.args.keep_wake_audio:
            self._keep_wake_audio(audio, text, hit)
        if not self.args.no_chirp:
            threading.Thread(target=chirp, args=("wake",), daemon=True).start()

        if hit["rest"]:
            # Wake word and command in one breath. Nothing more to wait for.
            self.dispatch(wake_match.fix_command_text(hit["rest"]),
                          hit["score"], hit["mood"], hit["phrase"])
        else:
            # Just her name. Open the microphone for the command; if none
            # comes, the give-up path answers the summons itself.
            self.pending_phrase = hit["phrase"]
            self.arm_request = hit["mood"]

    def _keep_wake_audio(self, audio, text, hit):
        """Write the burst that woke her to disk, for diagnosis.

        Off unless --keep-wake-audio is passed. It is the only way to tell a
        mishearing from a hallucination after the fact - you need the audio
        and the transcript side by side - but it writes recordings of the room
        to disk, so it stays opt-in and says so in the log every time it runs.
        """
        try:
            import wave

            import numpy as np      # module-level import is deliberately avoided here

            d = os.path.join(self.args.root, "wake-audio")
            os.makedirs(d, exist_ok=True)
            stamp = str(int(time.time() * 1000))
            pcm = (np.clip(np.asarray(audio, dtype=np.float32), -1.0, 1.0)
                   * 32767.0).astype(np.int16)
            with wave.open(os.path.join(d, stamp + ".wav"), "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(SAMPLE_RATE)
                w.writeframes(pcm.tobytes())
            with open(os.path.join(d, stamp + ".txt"), "w", encoding="utf-8") as f:
                f.write("transcript : %r\n" % text)
                f.write("phrase     : %r\n" % hit["phrase"])
                f.write("score      : %.3f\n" % hit["score"])
                f.write("mood       : %s\n" % hit["mood"])
                f.write("rest       : %r\n" % hit["rest"])
            log.info("kept wake audio %s.wav (--keep-wake-audio is on)", stamp)
        except Exception:                                         # noqa: BLE001
            log.exception("could not keep the wake audio")

    def _transcribe(self, audio, score, mood=None, phrase=None):
        t0 = time.time()
        try:
            text = self._run_stt(audio, COMMAND_PROMPT)
        except Exception:                                         # noqa: BLE001
            log.exception("transcription failed")
            self.set_state("idle")
            return
        finally:
            self.set_state("idle")

        raw = text
        # The wake word is often still at the front of the captured audio. If
        # it is a phrase we know, take its mood too: repeating "wake up GLaDOS"
        # into an already-open microphone should still read as being woken.
        hit = wake_match.match_wake(text, self.phrases,
                                    threshold=self.args.phrase_threshold)
        if hit:
            text = hit["rest"]
            if not mood or mood == "neutral":
                mood = hit["mood"]
                phrase = hit["phrase"]
        else:
            text = strip_wake_prefix(text)

        fixed = wake_match.fix_command_text(text)
        if fixed != text:
            log.info("corrected: %r -> %r", text, fixed)
            text = fixed

        if not text:
            if mood:
                log.info("only the wake phrase, nothing after it")
                self.dispatch("", score, mood, phrase, wake_only=True)
            else:
                log.info("nothing intelligible (%.1fs)", time.time() - t0)
            return
        if raw != text:
            log.info("stripped wake phrase: %r -> %r", raw, text)

        log.info("heard %r in %.1fs", text, time.time() - t0)
        self.dispatch(text, score, mood, phrase)

    def dispatch(self, text, score, mood=None, phrase=None, wake_only=False):
        """Hand one utterance to the overlay."""
        payload = {
            "text": text,
            "score": round(float(score), 3),
            "ts": time.time(),
            "mood": mood or "neutral",
            "wake": phrase or "",
            "wakeOnly": bool(wake_only),
        }
        path = os.path.join(self.inbox, "%d.json" % int(time.time() * 1000))
        tmp = path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f)
            os.replace(tmp, path)       # atomic: the overlay never sees a partial file
        except OSError as exc:
            log.error("could not write transcript: %s", exc)


def selftest(root, args):
    """Record, measure, transcribe. Proves the microphone and the recognizer
    end to end without involving the wake word, which is the part most likely
    to need tuning and the least likely to be broken."""
    import numpy as np
    try:
        import sounddevice as sd
    except Exception as exc:                                      # noqa: BLE001
        print("  AUDIO SYSTEM UNAVAILABLE: %s" % exc, flush=True)
        print("  Windows normally bundles this with the package. A reinstall of", flush=True)
        print("  the voice environment usually fixes it.", flush=True)
        return 4

    device = args.device
    if device is not None and str(device).isdigit():
        device = int(device)

    secs = float(args.selftest)
    print("Recording %.0f seconds. Say something." % secs, flush=True)
    frames = int(secs * SAMPLE_RATE)
    try:
        rec = sd.rec(frames, samplerate=SAMPLE_RATE, channels=1, dtype="int16", device=device)
        sd.wait()
    except Exception as exc:                                      # noqa: BLE001
        print("  COULD NOT OPEN THE MICROPHONE: %s" % exc, flush=True)
        print("  Check Settings > System > Sound > Input, and", flush=True)
        print("  Settings > Privacy > Microphone > let desktop apps access it.", flush=True)
        return 4
    audio = rec.reshape(-1)

    peak = int(np.abs(audio).max())
    rms = float((audio.astype("float32") ** 2).mean()) ** 0.5
    import math
    peak_db = 20 * math.log10(peak / 32768.0) if peak > 0 else -120.0
    rms_db = 20 * math.log10(rms / 32768.0 + 1e-12)
    print("  peak %.1f dBFS, average %.1f dBFS" % (peak_db, rms_db), flush=True)

    if peak < 300:
        print("  LEVEL TOO LOW - the microphone captured almost nothing.", flush=True)
        print("  Check the Windows input device and its level, then run this again.", flush=True)
        return 2
    if peak > 32000:
        print("  CLIPPING - the input level is too high; turn the mic gain down.", flush=True)

    from faster_whisper import WhisperModel
    print("  loading %s on %s ..." % (args.whisper_model, args.whisper_device), flush=True)
    t0 = time.time()
    stt = WhisperModel(args.whisper_model, device=args.whisper_device,
                       compute_type=args.whisper_compute)
    print("  model loaded in %.1fs" % (time.time() - t0), flush=True)

    t0 = time.time()
    segments, _ = stt.transcribe(audio.astype("float32") / 32768.0,
                                 language="en", vad_filter=True, beam_size=1)
    text = " ".join(s.text.strip() for s in segments).strip()
    took = time.time() - t0

    print("", flush=True)
    if text:
        print("  HEARD: %r" % text, flush=True)
        print("  (%.1fs to transcribe %.0fs of audio - %.1fx real time)"
              % (took, secs, secs / max(took, 0.001)), flush=True)
        return 0
    print("  Heard nothing intelligible. The mic works but no speech was recognised.", flush=True)
    return 3


def main():
    ap = argparse.ArgumentParser(description="GLaDOS voice input daemon")
    ap.add_argument("--root", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--device", default=None, help="input device index or name substring")
    ap.add_argument("--wake-model", default=None, help="path to a custom .onnx wake model")
    ap.add_argument("--wake-builtin", default="hey_jarvis", help="fallback pretrained model")
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--open-mic", dest="open_mic", action="store_true", default=True,
                    help="transcribe bursts of speech and match wake_phrases.json (default)")
    ap.add_argument("--no-open-mic", dest="open_mic", action="store_false",
                    help="only the trained wake model wakes her")
    ap.add_argument("--use-wake-model", dest="use_wake_model", action="store_true", default=False,
                    help="also run the openWakeWord model as a fast path")
    ap.add_argument("--phrase-threshold", type=float, default=0.80,
                    help="how close a transcript must be to a wake phrase, 0..1")
    ap.add_argument("--mic-margin", type=float, default=6.0,
                    help="dB above the room's noise floor that counts as speech; "
                         "lower hears more (6 is a mutter, 9 wants a raised voice)")
    ap.add_argument("--whisper-model", default="base.en")
    ap.add_argument("--whisper-device", default="cpu", choices=["cpu", "cuda", "auto"])
    ap.add_argument("--whisper-compute", default="int8")
    ap.add_argument("--list-devices", action="store_true")
    ap.add_argument("--no-chirp", action="store_true",
                    help="do not beep on wake / capture / timeout")
    ap.add_argument("--keep-wake-audio", dest="keep_wake_audio", action="store_true",
                    default=False,
                    help="write every burst that matched a wake phrase to "
                         "voice/wake-audio as WAV + transcript. Diagnostic only: "
                         "it records the room to disk. Off by default.")
    ap.add_argument("--selftest", type=float, default=0.0, metavar="SECONDS",
                    help="record for SECONDS, transcribe it, print the result and exit")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    os.makedirs(root, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.StreamHandler(sys.stdout),
                  logging.FileHandler(os.path.join(root, "voice.log"), encoding="utf-8")])

    if args.list_devices:
        try:
            import sounddevice as sd
            found = 0
            for i, d in enumerate(sd.query_devices()):
                if d["max_input_channels"] > 0:
                    found += 1
                    print("%d: %s (%d ch, %.0f Hz)" %
                          (i, d["name"], d["max_input_channels"], d["default_samplerate"]))
            if not found:
                print("(no input devices - Windows sees no microphone)")
        except Exception as exc:                                  # noqa: BLE001
            print("(could not enumerate audio devices: %s)" % exc)
            return 4
        return 0

    if args.selftest:
        return selftest(root, args)

    if args.wake_model is None:
        guess = os.path.join(root, "models", "hey_glados.onnx")
        args.wake_model = guess if os.path.isfile(guess) else None

    listener = Listener(root, args)
    if not listener.claim_singleton():
        return 5
    try:
        listener.run()
    except KeyboardInterrupt:
        log.info("stopping")
    except Exception as exc:                                      # noqa: BLE001
        log.exception("listener died: %s", exc)
        return 1
    finally:
        listener.set_state("stopped")
        listener.release_singleton()
    return 0


if __name__ == "__main__":
    sys.exit(main())
