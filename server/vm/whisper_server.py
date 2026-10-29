#!/usr/bin/env python3
"""Keep Typhoon Whisper Turbo resident on the GPU and transcribe one clip at a time."""

import json
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

# Keep the legacy launcher/PID contract while selecting the configured ASR.
# Qwen owns its llama-server child; the inactive Whisper weights stay on disk.
if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from oliv_config import load as load_asr_config
    if load_asr_config().get("api", {}).get("asr_profile", "turbo") == "qwen3asr":
        from qwen_asr import main as qwen_main
        qwen_main(Path(__file__).with_name("qwen-profile.json"))
        raise SystemExit(0)

import faster_whisper
import numpy as np
from faster_whisper import WhisperModel
from faster_whisper.audio import pad_or_trim

sys.path.insert(0, str(Path(__file__).resolve().parent))
from oliv_config import ConfigError, load, resolve_model

try:
    _cfg = load()["whisper"]
except ConfigError as exc:
    raise SystemExit(str(exc)) from exc

MODEL_DIR = str(resolve_model(_cfg["model"], "whisper"))
HOST = _cfg["host"]
PORT = _cfg["port"]
DEVICE = _cfg["device"]
COMPUTE_TYPE = _cfg["compute_type"]
BEAM = _cfg["beam_size"]

class SharedEncoderModel(WhisperModel):
    """WhisperModel that runs the encoder once per clip instead of two or three times.

    Stock faster-whisper encodes the first 30 s window to detect the language,
    then encodes it again to decode (generate_segments is always handed
    encoder_output=None), and oliv-api's forced-English re-decode encodes it a
    third time. The encoder is ~0.6-1 s on a 6 GB reference GPU, the decode ~0.1 s.
    Here language detection encodes exactly the window decoding will use, and
    the last encoder output is kept, so later encodes of the same window are free.
    Detection differs from stock only in that window: stock keeps one extra
    trailing mel frame of a sub-30 s clip.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._enc_lock = threading.Lock()
        self._enc_key = None
        self._enc_out = None

    def encode(self, features):
        with self._enc_lock:
            if self._enc_key is not None and np.array_equal(self._enc_key, features):
                return self._enc_out
            out = super().encode(features)
            self._enc_key, self._enc_out = np.array(features, copy=True), out
            return out

    def detect_language(self, audio=None, features=None, vad_filter=False,
                        vad_parameters=None, language_detection_segments=1,
                        language_detection_threshold=0.5):
        if features is None or features.ndim != 2 or language_detection_segments != 1:
            return super().detect_language(audio, features, vad_filter, vad_parameters,
                                           language_detection_segments,
                                           language_detection_threshold)
        # The first window exactly as generate_segments cuts it (seek 0).
        n = self.feature_extractor.nb_max_frames
        window = pad_or_trim(features[:, : min(n, features.shape[-1] - 1)])
        results = self.model.detect_language(self.encode(window))[0]
        probs = [(token[2:-2], prob) for token, prob in results]
        return probs[0][0], probs[0][1], probs


# SharedEncoderModel relies on faster-whisper internals (how generate_segments
# cuts the first window, model.detect_language). It was checked against 1.2.1
# (identical output on the eval set); any other version falls back to stock.
SHARED_ENCODER_VERSION = "1.2.1"
if faster_whisper.__version__ == SHARED_ENCODER_VERSION:
    model = SharedEncoderModel(MODEL_DIR, device=DEVICE, compute_type=COMPUTE_TYPE)
else:
    print(f"faster-whisper {faster_whisper.__version__} != {SHARED_ENCODER_VERSION}: "
          "shared encoder off", flush=True)
    model = WhisperModel(MODEL_DIR, device=DEVICE, compute_type=COMPUTE_TYPE)


# An oliv-api HTTP timeout does not cancel a model iterator already running here.
# Keep admission at the actual inference owner; never queue a second request
# behind a decode whose caller may have disconnected.
_inference_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/health":
            self._json(
                200,
                {
                    "ok": True,
                    "model": MODEL_DIR,
                    "device": DEVICE,
                    "compute_type": COMPUTE_TYPE,
                    "beam_size": BEAM,
                },
            )
        else:
            self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/transcribe":
            self._json(404, {"ok": False, "error": "not found"})
            return
        if not _inference_lock.acquire(blocking=False):
            # The body has not been read. Close so its bytes cannot be treated
            # as a new request on this HTTP/1.1 connection.
            self.close_connection = True
            self._json(503, {"ok": False, "error": "inference busy"})
            return
        try:
            self._transcribe()
        except (BrokenPipeError, ConnectionResetError):
            # A timed-out caller is expected; inference has already completed
            # before writing its reply, and the finally block releases the slot.
            self.close_connection = True
        finally:
            _inference_lock.release()

    def _transcribe(self):
        length = int(self.headers.get("Content-Length", "0"))
        audio = self.rfile.read(length)
        if not audio:
            self._json(400, {"ok": False, "error": "empty body"})
            return
        suffix = ".wav"
        ctype = self.headers.get("Content-Type", "")
        if "webm" in ctype:
            suffix = ".webm"
        elif "ogg" in ctype:
            suffix = ".ogg"
        elif "mpeg" in ctype or "mp3" in ctype:
            suffix = ".mp3"
        # Optional percent-encoded initial prompt, and X-Language to force a
        # language (oliv-api's forced-English re-decode). Without the headers
        # the call is exactly what it was before.
        extra = {}
        prompt = unquote(self.headers.get("X-Initial-Prompt", "")).strip()
        if prompt:
            extra["initial_prompt"] = prompt
        language = self.headers.get("X-Language", "").strip() or None
        with tempfile.NamedTemporaryFile(suffix=suffix) as tmp:
            tmp.write(audio)
            tmp.flush()
            # Opt-in per-word confidence (experiment); off by default, so the
            # decode and the reply are exactly what they were without the header.
            want_words = self.headers.get("X-Words", "").strip() == "1"
            segments, info = model.transcribe(
                tmp.name,
                beam_size=BEAM,
                vad_filter=True,
                language=language,
                word_timestamps=want_words,
                **extra,
            )
            segments = list(segments)
            text = "".join(seg.text for seg in segments).strip()
        # Mean per-segment avg_logprob, the confidence Oliv's re-decode compares.
        avg = sum(s.avg_logprob for s in segments) / len(segments) if segments else None
        reply = {"ok": True, "text": text, "language": info.language,
                 "avg_logprob": avg}
        if want_words:
            reply["words"] = [
                {"w": w.word, "p": round(w.probability, 4)}
                for seg in segments for w in (seg.words or [])
            ]
        self._json(200, reply)


if __name__ == "__main__":
    print(f"whisper ready on http://{HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
