"""Developer-only driver for the shipped Rust worker. Never bundled in OLIV.

Files are normalized once to capture-shaped Float32 mono/16 kHz. The same PCM
can be passed to the Python reference for an inference comparison.
"""
from __future__ import annotations

import base64
import json
import os
import queue
import shutil
import subprocess
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ENGINE = "typhoon-turbo-mlx"
CLEANUP_MODEL = "mlx-community/gemma-4-e2b-it-4bit"


def captured_pcm(filename: str) -> bytes:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("Install ffmpeg to normalize benchmark files")
    return subprocess.run([ffmpeg, "-v", "error", "-nostdin", "-i", filename,
                           "-ar", "16000", "-ac", "1", "-f", "f32le", "-"],
                          check=True, capture_output=True).stdout


def capture_request(body: dict) -> dict:
    body = dict(body)
    if "wav_path" in body:
        body["pcm_b64"] = base64.b64encode(captured_pcm(body.pop("wav_path"))).decode("ascii")
    return body


class NativeRuntime:
    def __init__(self, directory: Path | None = None):
        directory = directory or ROOT / "build/native-runtime"
        worker = directory / "oliv-sidecar"
        if not worker.is_file():
            raise RuntimeError("Build the native runtime first: bash scripts/build_native.sh")
        env = os.environ.copy()
        env.update(OLIV_INFERENCE_EXECUTABLE=str(directory / "oliv-inference"),
                   OLIV_WHISPER_TOKENIZER=str(directory / "whisper-tokenizer"))
        if "HF_HOME" not in env:
            app_cache = Path.home() / "Library/Application Support/OLIV/models"
            if app_cache.is_dir():
                env["HF_HOME"] = str(app_cache)
        self.child = subprocess.Popen([str(worker)], env=env, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.frames: queue.Queue = queue.Queue(maxsize=8)
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            while True:
                frame = self.child.stdout.readline(2 * 1024 * 1024 + 1)
                if not frame:
                    raise RuntimeError("Native worker exited before replying")
                if len(frame) > 2 * 1024 * 1024 or not frame.endswith(b"\n"):
                    raise RuntimeError("Native reply exceeded protocol limit")
                self.frames.put(json.loads(frame), timeout=5)
        except Exception as error:
            try:
                self.frames.put(error, timeout=5)
            except queue.Full:
                pass

    def request(self, body: dict) -> dict:
        body = capture_request(body)
        self.next_id += 1
        body["id"] = self.next_id
        self.child.stdin.write(json.dumps(body, ensure_ascii=False).encode() + b"\n")
        self.child.stdin.flush()
        timeout = 120 if body["cmd"] == "warm" else 35
        while True:
            reply = self.frames.get(timeout=timeout)
            if isinstance(reply, Exception):
                raise reply
            if reply.get("id") != self.next_id or reply.get("event") == "progress":
                continue
            if not reply.get("ok"):
                raise RuntimeError("Native request failed: " + str(reply.get("error", reply.get("code", "unknown"))))
            return reply

    def close(self):
        self.child.stdin.close()
        try:
            self.child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait()
        self.child.stdout.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
