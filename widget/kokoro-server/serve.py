#!/usr/bin/env python3
"""Kokoro TTS sidecar server for Duck Duck Duck.

Minimal HTTP server that wraps Kokoro TTS inference.
Managed as a subprocess by the widget — not intended to be run manually.

Endpoints:
    GET  /health  — {"status": "ready"|"loading"|"error", "message": "..."}
    POST /tts     — JSON {"text": "...", "speed": 1.0, "lang": "a", "voice": "af_heart"} → WAV bytes (24kHz mono)
"""

import io
import json
import os
import signal
import sys
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

import numpy as np
import soundfile as sf

# --- Global state ---

pipelines = {}  # lang_code -> KPipeline (lazy-loaded)
pipelines_lock = threading.Lock()
status = "loading"
status_message = "Loading Kokoro model..."
status_lock = threading.Lock()

DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
DEFAULT_SPEED = float(os.environ.get("KOKORO_SPEED", "1.0"))
DEFAULT_LANG = os.environ.get("KOKORO_LANG", "a")


def set_status(s, msg=""):
    global status, status_message
    with status_lock:
        status = s
        status_message = msg


def get_status():
    with status_lock:
        return {"status": status, "message": status_message}


def get_pipeline(lang_code):
    """Get or create a KPipeline for the given language code. Thread-safe."""
    with pipelines_lock:
        if lang_code in pipelines:
            return pipelines[lang_code]

    # Load outside the lock (slow operation)
    from kokoro import KPipeline
    print(f"[kokoro] Loading pipeline for lang_code='{lang_code}'...", flush=True)
    p = KPipeline(lang_code=lang_code)
    with pipelines_lock:
        pipelines[lang_code] = p
    print(f"[kokoro] Pipeline '{lang_code}' ready.", flush=True)
    return p


# --- Model loading (runs in background thread) ---

def load_model():
    try:
        set_status("loading", "Loading Kokoro model...")
        print("[kokoro] Loading default pipeline...", flush=True)
        p = get_pipeline(DEFAULT_LANG)
        # Warm up with a short utterance to load voice + trigger any downloads
        print(f"[kokoro] Warming up with voice '{DEFAULT_VOICE}'...", flush=True)
        for _ in p("hello", voice=DEFAULT_VOICE, speed=1.0):
            break
        set_status("ready", "Kokoro ready")
        print("[kokoro] Ready.", flush=True)
    except Exception as e:
        set_status("error", str(e))
        print(f"[kokoro] Load failed: {e}", file=sys.stderr, flush=True)


# --- Audio extraction (from talk_llama_kokoro.py) ---

def extract_audio(obj, default_sr=24000):
    """Extract (audio_array, sample_rate) from a Kokoro pipeline yield."""
    if hasattr(obj, "audio"):
        a = getattr(obj, "audio")
        try:
            arr = np.asarray(a, dtype=np.float32).reshape(-1)
            if arr.size > 0:
                sr = getattr(obj, "sr", getattr(obj, "sample_rate", default_sr))
                return arr, int(sr)
        except Exception:
            pass
    if isinstance(obj, tuple):
        if len(obj) >= 3:
            try:
                arr = np.asarray(obj[2], dtype=np.float32).reshape(-1)
                if arr.size > 0:
                    return arr, default_sr
            except Exception:
                pass
        if len(obj) == 2 and isinstance(obj[1], (int, np.integer)):
            try:
                arr = np.asarray(obj[0], dtype=np.float32).reshape(-1)
                if arr.size > 0:
                    return arr, int(obj[1])
            except Exception:
                pass
    try:
        arr = np.asarray(obj, dtype=np.float32).reshape(-1)
        if arr.size > 0:
            return arr, default_sr
    except Exception:
        pass
    return None, None


def synthesize(text, voice=DEFAULT_VOICE, speed=DEFAULT_SPEED, lang=DEFAULT_LANG):
    """Synthesize text to WAV bytes. Returns (wav_bytes, sample_rate) or raises."""
    pipeline = get_pipeline(lang)

    chunks = []
    sr = 24000
    for result in pipeline(text, voice=voice, speed=speed):
        audio, result_sr = extract_audio(result)
        if audio is not None:
            chunks.append(audio)
            sr = result_sr

    if not chunks:
        raise RuntimeError("No audio produced")

    audio = np.concatenate(chunks)
    buf = io.BytesIO()
    sf.write(buf, audio, sr, format="WAV", subtype="FLOAT")
    return buf.getvalue(), sr


# --- HTTP handler ---

class TTSHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            body = json.dumps(get_status()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/tts":
            self.handle_tts()
        else:
            self.send_error(404)

    def handle_tts(self):
        s = get_status()
        if s["status"] != "ready":
            body = json.dumps({"error": "not ready", "status": s["status"]}).encode()
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length > 0 else b"{}"
            params = json.loads(raw)
            text = params.get("text", "").strip()
            speed = float(params.get("speed", DEFAULT_SPEED))
            voice = params.get("voice", DEFAULT_VOICE)
            lang = params.get("lang", DEFAULT_LANG)

            if not text:
                self.send_error(400, "Missing 'text' field")
                return

            wav_bytes, sr = synthesize(text, voice=voice, speed=speed, lang=lang)

            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(wav_bytes)))
            self.send_header("X-Sample-Rate", str(sr))
            self.end_headers()
            self.wfile.write(wav_bytes)

        except Exception as e:
            print(f"[kokoro] TTS error: {e}", file=sys.stderr, flush=True)
            body = json.dumps({"error": str(e)}).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


# --- Main ---

def main():
    port_file = os.environ.get("DUCK_KOKORO_PORT_FILE", "")

    loader = threading.Thread(target=load_model, daemon=True)
    loader.start()

    server = ThreadingHTTPServer(("127.0.0.1", 0), TTSHandler)
    port = server.server_address[1]
    print(f"[kokoro] Listening on 127.0.0.1:{port}", flush=True)

    if port_file:
        with open(port_file, "w") as f:
            f.write(str(port))
        print(f"[kokoro] Port file: {port_file}", flush=True)

    def shutdown(sig, frame):
        print("[kokoro] Shutting down...", flush=True)
        server.shutdown()
        if port_file:
            try:
                os.remove(port_file)
            except OSError:
                pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    server.serve_forever()


if __name__ == "__main__":
    main()
