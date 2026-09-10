"""Pathumma STT backend -- nectec/Pathumma-whisper-th-large-v3 via HF
transformers.

This is the PRIMARY STT backend for OLIV (FALLBACK is mlx_whisper.py's
MLXWhisperBackend). It mirrors benchmark/engines.py's
TransformersWhisperEngine exactly (same pipeline() call shape, same MPS/CPU
device selection, same float32 dtype, same chunk_length_s=30, same
generate_kwargs) -- that implementation was validated against all 66
benchmark clips, so this backend copies its behavior rather than
reinventing it.

Import discipline: `transformers` / `torch` / `librosa` (and therefore the
Metal/MPS backend torch touches on import) are only imported inside
methods, never at module scope, so that `import app` / `import app.stt`
stays fast and does not load any model weights or touch the GPU.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Union

import numpy as np

from .base import STTBackend

AudioInput = Union[str, Path, np.ndarray]

# Same repo as benchmark/engines.py's "pathumma" engine id.
DEFAULT_REPO = "nectec/Pathumma-whisper-th-large-v3"
TARGET_SR = 16000


class PathummaBackend(STTBackend):
    id = "pathumma"

    def __init__(self, repo: str = DEFAULT_REPO):
        self.repo = repo

    def available(self) -> tuple[bool, str]:
        try:
            import librosa  # noqa: F401
            import torch  # noqa: F401
            import transformers  # noqa: F401
        except Exception:
            return False, "pip install transformers torch librosa soundfile"
        return True, ""

    def warm_up(self) -> bool:
        """Pre-build the HF pipeline (model + processor load onto the
        target device) so a later transcribe() call's wall time reflects
        decoding only -- lets callers (e.g. --stt-test) report model-load
        time and per-clip decode time separately.

        _pipe() is lru_cache'd (keyed on `self`), so calling it here just
        means the real transcribe() call below finds the pipeline already
        built and reuses it -- same trick as benchmark/engines.py's
        TransformersWhisperEngine._pipe().
        """
        try:
            self._pipe()
            return True
        except Exception:
            return False

    def transcribe(
        self,
        audio: AudioInput,
        language: str | None = None,
        initial_prompt: str | None = None,
    ) -> str:
        # initial_prompt is accepted for interface parity with the shipping
        # backends (base.STTBackend.transcribe) but is a NO-OP here: this HF
        # transformers backend is dev-only (A/B comparison against pathumma-mlx;
        # never selectable in the app), so wiring prompt_ids through the ASR
        # pipeline isn't worth the risk. The vocabulary feature rides the MLX /
        # Groq backends, which honour it.
        _ = initial_prompt
        payload = self._prepare_audio(audio)
        gen = {"task": "transcribe"}
        if language:
            gen["language"] = language  # omit => Whisper auto-detects (default policy)
        out = self._pipe()(
            payload,
            generate_kwargs=gen,
            return_timestamps=False,
        )
        return out["text"]

    def _prepare_audio(self, audio: AudioInput) -> dict:
        """Normalize `audio` into the {"raw": ..., "sampling_rate": 16000}
        dict shape the HF ASR pipeline wants.

        - numpy array: assumed already 16kHz mono float32 per this
          backend's interface contract (this is what the W1-T2 capture
          stage hands in directly, no file round-trip) -- passed straight
          through as the pipeline's "raw" payload.
        - path (str/Path): loaded via librosa at sr=16000, mono=True --
          exactly like benchmark/engines.py's TransformersWhisperEngine,
          which correctly round-trips this project's 48kHz-stereo sample
          clips.
        """
        if isinstance(audio, np.ndarray):
            raw = audio.astype(np.float32, copy=False)
        else:
            import librosa

            raw, _ = librosa.load(str(audio), sr=TARGET_SR, mono=True)
        return {"raw": raw, "sampling_rate": TARGET_SR}

    @lru_cache(maxsize=1)
    def _pipe(self):
        """Build (and cache) the HF ASR pipeline for this backend instance.

        Identical shape to benchmark/engines.py's TransformersWhisperEngine
        ._pipe(): MPS if available else CUDA else CPU, float32 dtype,
        chunk_length_s=30. lru_cache keyed on `self` (default hash/eq is
        identity), so repeated transcribe()/warm_up() calls on the same
        PathummaBackend instance reuse one loaded model.
        """
        import torch
        from transformers import pipeline

        if torch.backends.mps.is_available():
            device = torch.device("mps")
        elif torch.cuda.is_available():
            device = torch.device("cuda")
        else:
            device = torch.device("cpu")
        # float32 on MPS: safest for Whisper generate; short clips keep it fast.
        dtype = torch.float32
        return pipeline(
            "automatic-speech-recognition",
            model=self.repo,
            device=device,
            torch_dtype=dtype,
            chunk_length_s=30,
        )
