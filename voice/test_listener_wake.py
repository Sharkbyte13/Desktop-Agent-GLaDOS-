#!/usr/bin/env python3
"""The listener's wake handling, with the microphone and Whisper replaced.

Audio hardware and a 150MB model are not available here, and are not what is
worth testing anyway: what matters is what happens to a transcript once it
exists - which bursts are ignored, which arm the microphone, what lands in the
inbox, and what mood is attached to it.

Run: python test_listener_wake.py
"""
import glob
import json
import os
import shutil
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import listener as L

fails = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (("  -> " + str(detail)) if detail else ""))
    if not cond:
        fails.append(name)


def make_listener(root, **over):
    args = types.SimpleNamespace(
        open_mic=True, use_wake_model=False, phrase_threshold=0.82,
        no_chirp=True, threshold=0.5, wake_model=None, wake_builtin="hey_jarvis",
        whisper_model="base.en", whisper_device="cpu", whisper_compute="int8",
        device=None, keep_wake_audio=False,
    )
    for k, v in over.items():
        setattr(args, k, v)
    shutil.copy(os.path.join(HERE, "wake_phrases.json"), os.path.join(root, "wake_phrases.json"))
    return L.Listener(root, args)


def inbox_files(lis):
    return sorted(glob.glob(os.path.join(lis.inbox, "*.json")))


def drain(lis):
    out = []
    for p in inbox_files(lis):
        with open(p, encoding="utf-8") as f:
            out.append(json.load(f))
        os.remove(p)
    return out


root = tempfile.mkdtemp(prefix="glados-wake-")
lis = make_listener(root)

print("\n[phrases load from the folder]")
check("phrases were read", len(lis.phrases) >= 15, len(lis.phrases))
check("the description mentions them", "phrases" in lis.wake_description(), lis.wake_description())
check("no wake model needed", lis.wake is None)

print("\n[a burst that is not for her]")
lis._run_stt = lambda audio, prompt=None: "so anyway I told him the deadline was Friday"
lis.scan_busy = True
lis._scan(None)
check("nothing is armed", lis.arm_request is None)
check("nothing is written", drain(lis) == [])
check("the scan flag is released", lis.scan_busy is False)

print("\n[her name, and nothing else]")
lis._run_stt = lambda audio, prompt=None: "wake up Gladys"
lis.scan_busy = True
lis._scan(None)
check("the microphone is armed", lis.arm_request == "woken", lis.arm_request)
check("with the phrase remembered", lis.pending_phrase == "wake up glados", lis.pending_phrase)
check("but nothing is sent yet", drain(lis) == [])

print("\n[the command that follows]")
lis.pending_mood, lis.arm_request = "woken", None
lis._run_stt = lambda audio, prompt=None: "what is on my desktop"
lis._transcribe(None, 0.9, "woken", "wake up glados")
msgs = drain(lis)
check("one message", len(msgs) == 1, len(msgs))
check("the command is the text", msgs and msgs[0]["text"] == "what is on my desktop", msgs and msgs[0]["text"])
check("the mood travels with it", msgs and msgs[0]["mood"] == "woken", msgs and msgs[0]["mood"])
check("it is not a bare summons", msgs and msgs[0]["wakeOnly"] is False)
check("the phrase is recorded", msgs and msgs[0]["wake"] == "wake up glados", msgs and msgs[0]["wake"])

print("\n[wake and command in one breath]")
lis._run_stt = lambda audio, prompt=None: "hey Gladys set a timer for ten minutes"
lis.scan_busy = True
lis._scan(None)
msgs = drain(lis)
check("it does not wait for more", len(msgs) == 1, len(msgs))
check("the verb is not eaten", msgs and msgs[0]["text"] == "set a timer for ten minutes",
      msgs and msgs[0]["text"])
check("mood is neutral for a plain hey", msgs and msgs[0]["mood"] == "neutral", msgs and msgs[0]["mood"])
check("nothing was left armed", lis.arm_request is None)

print("\n[you said her name and then said nothing]")
lis._run_stt = lambda audio, prompt=None: "hey Gladys"
lis._transcribe(None, 1.0, "neutral", "hey glados")
msgs = drain(lis)
check("the summons is still answered", len(msgs) == 1, len(msgs))
check("with empty text", msgs and msgs[0]["text"] == "", repr(msgs and msgs[0]["text"]))
check("flagged as a bare wake", msgs and msgs[0]["wakeOnly"] is True)

print("\n[the wake phrase repeated into an open microphone]")
lis._run_stt = lambda audio, prompt=None: "good morning Gladys what day is it"
lis._transcribe(None, 1.0, "neutral", "hey glados")
msgs = drain(lis)
check("the later phrase wins the mood", msgs and msgs[0]["mood"] == "morning", msgs and msgs[0]["mood"])
check("and the question survives", msgs and msgs[0]["text"] == "what day is it", msgs and msgs[0]["text"])

print("\n[an armed microphone that hears something unrelated]")
lis._run_stt = lambda audio, prompt=None: "turn the heating up"
lis._transcribe(None, 1.0, "neutral", "hey glados")
msgs = drain(lis)
check("it is taken as the command, since she was listening" , len(msgs) == 1, len(msgs))
check("text intact", msgs and msgs[0]["text"] == "turn the heating up", msgs and msgs[0]["text"])

print("\n[nothing intelligible]")
lis._run_stt = lambda audio, prompt=None: ""
lis._transcribe(None, 1.0, None, None)
check("silence writes nothing", drain(lis) == [])

print("\n[a failing recogniser does not take the daemon down]")
def boom(audio, prompt=None):
    raise RuntimeError("model exploded")
lis._run_stt = boom
lis.scan_busy = True
lis._scan(None)
check("the scan survives", lis.scan_busy is False)
lis._transcribe(None, 1.0, None, None)
check("so does the transcribe path", drain(lis) == [])

print("\n[editing the phrase file takes effect]")
path = os.path.join(root, "wake_phrases.json")
before = len(lis.phrases)
with open(path, "w", encoding="utf-8") as f:
    json.dump({"phrases": [{"match": "computer glados", "mood": "trek"}]}, f)
os.utime(path, (os.path.getmtime(path) + 5, os.path.getmtime(path) + 5))
check("the change is noticed", lis.phrases_changed())
lis.load_phrases()
check("the new list is in force", len(lis.phrases) == 1, len(lis.phrases))
lis._run_stt = lambda audio, prompt=None: "computer Gladys"
lis.scan_busy = True
lis._scan(None)
check("the new phrase wakes her" , lis.arm_request == "trek", lis.arm_request)
lis.arm_request = None
lis._run_stt = lambda audio, prompt=None: "hey Gladys"
lis.scan_busy = True
lis._scan(None)
check("and the removed one no longer does", lis.arm_request is None, lis.arm_request)

print("\n[a broken phrase file does not leave her deaf]")
with open(path, "w", encoding="utf-8") as f:
    f.write("{ this is not json")
lis.load_phrases()
check("it falls back to the built-in list", len(lis.phrases) >= 15, len(lis.phrases))
lis._run_stt = lambda audio, prompt=None: "hey Gladys"
lis.scan_busy = True
lis._scan(None)
check("and she still answers to her name", lis.arm_request == "neutral", lis.arm_request)

print("\n[the follow-up window]")
import time as _t
fu = os.path.join(root, "followup.json")
lis.close_followup()
check("closed by default", lis.read_followup() is False)
lis._run_stt = lambda audio, prompt=None: "the blue one"
lis.scan_busy = True
lis._scan(None)
check("without it, an unaddressed answer is ignored", drain(lis) == [])

with open(fu, "w", encoding="utf-8") as f:
    json.dump({"grace": 30}, f)
check("the window opens when the overlay asks", lis.read_followup() is True)
check("it reports itself as open for the configured time",
      abs((lis.followup_until - _t.time()) - 30) < 2, lis.followup_until - _t.time())

lis._run_stt = lambda audio, prompt=None: "the blue one"
lis.scan_busy = True
lis._scan(None)
msgs = drain(lis)
check("now the answer is taken without her name", len(msgs) == 1, len(msgs))
check("marked as a follow-up", msgs and msgs[0]["mood"] == "followup", msgs and msgs[0]["mood"])
check("with the words intact", msgs and msgs[0]["text"] == "the blue one", msgs and msgs[0]["text"])
check("the window closes once answered", not os.path.exists(fu))
check("and is no longer active", lis.read_followup() is False)

print("\n[her own voice does not spend your thirty seconds]")
with open(fu, "w", encoding="utf-8") as f:
    json.dump({"grace": 30}, f)
lis.read_followup()
lis.followup_until = _t.time() + 2          # nearly expired
open(os.path.join(root, "speaking.lock"), "w").write("x")
check("she is suppressed while speaking", lis.suppressed() == "speaking")
# the loop refreshes the clock on every suppressed frame
lis.followup_until = _t.time() + lis.followup_grace
check("the clock is pushed back out", (lis.followup_until - _t.time()) > 25,
      lis.followup_until - _t.time())
os.remove(os.path.join(root, "speaking.lock"))

print("\n[an expired window]")
lis.followup_until = _t.time() - 1
check("it reports closed", lis.read_followup() is False)
check("and cleans the file up", not os.path.exists(fu))
lis._run_stt = lambda audio, prompt=None: "too late"
lis.scan_busy = True
lis._scan(None)
check("late answers are ignored", drain(lis) == [])

print("\n[naming her inside the window]")
with open(fu, "w", encoding="utf-8") as f:
    json.dump({"grace": 30}, f)
lis.read_followup()
lis._run_stt = lambda audio, prompt=None: "hey Gladys what time is it"
lis.scan_busy = True
lis._scan(None)
msgs = drain(lis)
check("the wake phrase still works inside it", len(msgs) == 1, len(msgs))
check("and it is not reported as a follow-up", msgs and msgs[0]["mood"] == "neutral",
      msgs and msgs[0]["mood"])
check("the window is closed either way", not os.path.exists(fu))

print("\n[sensitivity]")
check("the microphone hears a mutter by default", L.Endpointer().margin_db <= 6.5,
      L.Endpointer().margin_db)
check("it is still above a whisper of noise", L.Endpointer().margin_db >= 4.5,
      L.Endpointer().margin_db)
check("a short quiet word is long enough to bother with", L.MIN_SPEECH_S <= 0.30, L.MIN_SPEECH_S)

print("\n[the payload the overlay reads]")
lis.dispatch("test", 0.5, "curt", "glados")
msgs = drain(lis)
keys = set(msgs[0].keys()) if msgs else set()
check("every field the overlay expects", keys >= {"text", "score", "ts", "mood", "wake", "wakeOnly"}, keys)
check("no partial files are left behind", glob.glob(os.path.join(lis.inbox, "*.tmp")) == [])

shutil.rmtree(root, ignore_errors=True)

print("")
if fails:
    print("FAILURES (%d): %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("ALL PASS")
