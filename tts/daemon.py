#!/usr/bin/env python3
"""
Local GLaDOS text-to-speech daemon.

Wraps the glados-tts model in a small HTTP service so the desktop overlay can
speak arbitrary text. Binds to loopback only. No framework, no external web
dependencies - standard library plus torch.

    GET /health                 -> JSON status
    GET /synthesize?text=...    -> audio/wav (22050 Hz, mono, 16-bit)
    GET /speak?text=...         -> alias for /synthesize

Model files expected under <root>/models/ :
    glados-new.pt                 TorchScript acoustic model
    vocoder-gpu.pt                TorchScript vocoder
    emb/glados_p2.pt              speaker embedding
    en_us_cmudict_ipa_forward.pt  deep-phonemizer checkpoint
"""

import argparse
import hashlib
import io
import json
import logging
import os
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

SAMPLE_RATE = 22050
MAX_TEXT = 1000
CACHE_MAX_TEXT = 300
VERSION = "1.0"

log = logging.getLogger("glados-tts")

# --------------------------------------------------------------------------
# Model
# --------------------------------------------------------------------------

class Engine:
    """Lazily loads the model and synthesizes. Inference is serialized:
    the TorchScript modules are not safe to call concurrently."""

    REQUIRED = [
        os.path.join("models", "glados-new.pt"),
        os.path.join("models", "vocoder-gpu.pt"),
        os.path.join("models", "emb", "glados_p2.pt"),
        os.path.join("models", "en_us_cmudict_ipa_forward.pt"),
    ]

    def __init__(self, root):
        self.root = root
        self._lock = threading.Lock()
        self._loaded = False
        self.device = "cpu"
        self.error = None

    def missing_files(self):
        return [p for p in self.REQUIRED if not os.path.isfile(os.path.join(self.root, p))]

    def load(self):
        with self._lock:
            if self._loaded:
                return
            missing = self.missing_files()
            if missing:
                raise FileNotFoundError("missing model files: " + ", ".join(missing))

            import torch

            # Checkpoints predate PyTorch 2.6, which flipped weights_only to
            # True by default. Without this they fail to deserialize.
            original_load = torch.load

            def patched_load(*args, **kwargs):
                kwargs.setdefault("weights_only", False)
                return original_load(*args, **kwargs)

            torch.load = patched_load

            # Synthesis runs on the CPU, next to whatever the user is playing.
            # Left alone torch claims every core for a job that needs about
            # four, and a 0.4-second line becomes a frame-time spike in a game.
            # Cap it. GLADOS_TTS_THREADS overrides for anyone who disagrees.
            cores = os.cpu_count() or 4
            try:
                want = int(os.environ.get("GLADOS_TTS_THREADS", "0"))
            except ValueError:
                want = 0
            if want <= 0:
                want = min(4, max(1, cores // 4))
                if cores >= 4:
                    want = max(want, 2)
            try:
                torch.set_num_threads(want)
            except Exception:
                pass
            try:
                # Throws if any inter-op parallel work has already run. Not
                # worth failing a voice over.
                torch.set_num_interop_threads(1)
            except Exception:
                pass
            log.info("torch threads: %d of %d cores, 1 inter-op", want, cores)

            self.torch = torch
            self.device = "cuda" if torch.cuda.is_available() else "cpu"
            log.info("loading models on %s", self.device)
            t0 = time.time()

            # utils.text.cleaners loads the phonemizer from a path relative to
            # the working directory, so this has to be the daemon's root.
            os.chdir(self.root)

            from utils.tools import prepare_text
            self.prepare_text = prepare_text

            self.emb = torch.load(os.path.join("models", "emb", "glados_p2.pt"))
            self.glados = torch.jit.load(os.path.join("models", "glados-new.pt"))
            self.vocoder = torch.jit.load(
                os.path.join("models", "vocoder-gpu.pt"), map_location=self.device)

            # Warm up. The first real request is otherwise several seconds
            # slower than every one after it.
            with torch.no_grad():
                for i in range(2):
                    out = self.glados.generate_jit(self.prepare_text(str(i)), self.emb, 1.0)
                    self.vocoder(out["mel_post"].to(self.device))

            self._loaded = True
            log.info("models ready in %.1fs", time.time() - t0)

    def synthesize(self, text):
        if not self._loaded:
            self.load()
        with self._lock:
            torch = self.torch
            with torch.no_grad():
                x = self.prepare_text(text)
                out = self.glados.generate_jit(x, self.emb, 1.0)
                mel = out["mel_post"].to(self.device)
                audio = self.vocoder(mel)
                audio = audio.squeeze() * 32768.0
                audio = audio.cpu().numpy().astype("int16")
            return audio.tobytes()


def wav_bytes(pcm):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


# --------------------------------------------------------------------------
# Cache
# --------------------------------------------------------------------------

class Cache:
    def __init__(self, directory):
        self.dir = directory
        os.makedirs(self.dir, exist_ok=True)

    def _path(self, text):
        h = hashlib.sha1(text.encode("utf-8")).hexdigest()[:24]
        return os.path.join(self.dir, h + ".wav")

    def get(self, text):
        p = self._path(text)
        if os.path.isfile(p):
            try:
                with open(p, "rb") as f:
                    data = f.read()
                os.utime(p, None)
                return data
            except OSError:
                return None
        return None

    def put(self, text, data):
        try:
            p = self._path(text)
            tmp = p + ".tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, p)
        except OSError as exc:
            log.warning("cache write failed: %s", exc)

    def count(self):
        try:
            return len([n for n in os.listdir(self.dir) if n.endswith(".wav")])
        except OSError:
            return 0


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "glados-tts/" + VERSION
    protocol_version = "HTTP/1.1"

    engine = None
    cache = None

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)

    def _send(self, code, body, content_type):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, code, obj):
        self._send(code, json.dumps(obj), "application/json")

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        if path == "/health":
            missing = self.engine.missing_files()
            return self._json(200, {
                "ok": not missing,
                "version": VERSION,
                "model_loaded": self.engine._loaded,
                "device": self.engine.device,
                "missing_files": missing,
                "cached": self.cache.count(),
            })

        if path in ("/synthesize", "/speak"):
            qs = parse_qs(parsed.query)
            text = (qs.get("text") or [""])[0].strip()
            return self._synthesize(text)

        # /synthesize/<text> for convenience from a browser bar
        for prefix in ("/synthesize/", "/speak/"):
            if parsed.path.startswith(prefix):
                return self._synthesize(unquote(parsed.path[len(prefix):]).strip())

        return self._json(404, {"ok": False, "error": "not found"})

    def _synthesize(self, text):
        if not text:
            return self._json(400, {"ok": False, "error": "no text"})
        if len(text) > MAX_TEXT:
            return self._json(413, {"ok": False,
                                    "error": "text too long (max %d)" % MAX_TEXT})

        cacheable = len(text) <= CACHE_MAX_TEXT
        if cacheable:
            hit = self.cache.get(text)
            if hit:
                log.info("cache hit (%d chars)", len(text))
                return self._send(200, hit, "audio/wav")

        t0 = time.time()
        try:
            data = wav_bytes(self.engine.synthesize(text))
        except FileNotFoundError as exc:
            log.error("model missing: %s", exc)
            return self._json(503, {"ok": False, "error": str(exc)})
        except Exception as exc:                      # noqa: BLE001
            log.exception("synthesis failed")
            return self._json(500, {"ok": False, "error": repr(exc)})

        log.info("synthesized %d chars in %.2fs", len(text), time.time() - t0)
        if cacheable:
            self.cache.put(text, data)
        return self._send(200, data, "audio/wav")


def main():
    ap = argparse.ArgumentParser(description="Local GLaDOS TTS daemon")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8124)
    ap.add_argument("--root", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--preload", action="store_true",
                    help="load the model at startup instead of on first request")
    ap.add_argument("--say", metavar="TEXT",
                    help="synthesize TEXT to say.wav and exit (no server)")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.StreamHandler(sys.stdout),
                  logging.FileHandler(os.path.join(root, "tts.log"), encoding="utf-8")])

    sys.path.insert(0, root)
    engine = Engine(root)
    cache = Cache(os.path.join(root, "cache"))

    if args.say:
        try:
            engine.load()
            out = os.path.join(root, "say.wav")
            with open(out, "wb") as f:
                f.write(wav_bytes(engine.synthesize(args.say)))
            print("wrote " + out)
            return 0
        except FileNotFoundError as exc:
            print("ERROR: " + str(exc), file=sys.stderr)
            print("Run Setup-TTS.cmd to fetch the model.", file=sys.stderr)
            return 2
        except Exception as exc:                      # noqa: BLE001
            log.exception("synthesis failed")
            print("ERROR: synthesis failed: " + repr(exc), file=sys.stderr)
            return 3

    missing = engine.missing_files()
    if missing:
        log.warning("model files missing, /synthesize will return 503: %s",
                    ", ".join(missing))
    elif args.preload:
        engine.load()

    Handler.engine = engine
    Handler.cache = cache

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        log.warning("binding to %s - this exposes the daemon beyond this machine",
                    args.host)

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    log.info("listening on http://%s:%d  (root=%s)", args.host, args.port, root)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
