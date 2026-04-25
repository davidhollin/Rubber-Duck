#!/usr/bin/env python3
"""Kokoro TTS sidecar server for Duck Duck Duck.

Minimal HTTP server that wraps Kokoro TTS inference.
Managed as a subprocess by the widget — not intended to be run manually.

Endpoints:
    GET  /health  — {"status": "ready"|"loading"|"error", "message": "..."}
    POST /tts     — JSON {"text": "...", "speed": 1.0} → WAV bytes (24kHz mono)
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

pipeline = None
status = "loading"
status_message = "Loading Kokoro model..."
status_lock = threading.Lock()

VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
DEFAULT_SPEED = float(os.environ.get("KOKORO_SPEED", "1.0"))


def set_status(s, msg=""):
    global status, status_message
    with status_lock:
        status = s
        status_message = msg


def get_status():
    with status_lock:
        return {"status": status, "message": status_message}


# --- Model loading (runs in background thread) ---

def load_model():
    global pipeline
    try:
        set_status("loading", "Loading Kokoro model...")
        print("[kokoro] Loading KPipeline...", flush=True)
        from kokoro import KPipeline
        pipeline = KPipeline(lang_code="a")
        # Warm up with a short utterance to load voice + trigger any downloads
        print(f"[kokoro] Warming up with voice '{VOICE}'...", flush=True)
        for _ in pipeline("hello", voice=VOICE, speed=1.0):
            break
        set_status("ready", "Kokoro ready")
        print("[kokoro] Ready.", flush=True)
    except Exception as e:
        set_status("error", str(e))
        print(f"[kokoro] Load failed: {e}", file=sys.stderr, flush=True)


# --- Audio extraction (from talk_llama_kokoro.py) ---

def extract_audio(obj, default_sr=24000):
    """Extract (audio_array, sample_rate) from a Kokoro pipeline yield."""
    # Object with .audio attribute (KPipeline result)
    if hasattr(obj, "audio"):
        a = getattr(obj, "audio")
        try:
            arr = np.asarray(a, dtype=np.float32).reshape(-1)
            if arr.size > 0:
                sr = getattr(obj, "sr", getattr(obj, "sample_rate", default_sr))
                return arr, int(sr)
        except Exception:
            pass
    # Tuple: (graphemes, phonemes, audio) or (audio, sr)
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
    # Bare array
    try:
        arr = np.asarray(obj, dtype=np.float32).reshape(-1)
        if arr.size > 0:
            return arr, default_sr
    except Exception:
        pass
    return None, None


def synthesize(text, speed=DEFAULT_SPEED):
    """Synthesize text to WAV bytes. Returns (wav_bytes, sample_rate) or raises."""
    if pipeline is None:
        raise RuntimeError("Model not loaded")

    chunks = []
    sr = 24000
    for result in pipeline(text, voice=VOICE, speed=speed):
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
        # Suppress default access logging
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

            if not text:
                self.send_error(400, "Missing 'text' field")
                return

            wav_bytes, sr = synthesize(text, speed)

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

    # Start model loading in background
    loader = threading.Thread(target=load_model, daemon=True)
    loader.start()

    # Bind to port 0 (OS-assigned)
    server = ThreadingHTTPServer(("127.0.0.1", 0), TTSHandler)
    port = server.server_address[1]
    print(f"[kokoro] Listening on 127.0.0.1:{port}", flush=True)

    # Write port file so the widget can find us
    if port_file:
        with open(port_file, "w") as f:
            f.write(str(port))
        print(f"[kokoro] Port file: {port_file}", flush=True)

    # Graceful shutdown
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
