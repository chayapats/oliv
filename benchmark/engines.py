"""STT engine adapters for the OLIV Phase 0 benchmark.

Every engine exposes the same tiny interface:

    engine.transcribe(audio_path: str, language: str | None) -> str

`language=None` means *auto / multilingual decode* (do NOT force a token — the
default for code-switching). `language="th"`/`"en"` forces that language token
(the policy we A/B test).

Engines self-report `available()` so the harness can silently skip anything whose
dependency or API key is missing — you can run the benchmark incrementally
(e.g. Groq baseline first, local Thai models once conversion works).

Built-in engine ids:
    groq-large-v3      cloud  — vanilla whisper-large-v3        (baseline oracle)
    groq-turbo         cloud  — vanilla whisper-large-v3-turbo  (baseline oracle)
    mlx-large-v3       local  — vanilla whisper-large-v3 via MLX
    mlx-turbo          local  — vanilla whisper-large-v3-turbo via MLX
    thonburian         local  — biodatlab/whisper-th-large-v3-combined (HF transformers)
    pathumma           local  — nectec/Pathumma-whisper-th-large-v3    (HF transformers)
"""

from __future__ import annotations

import os
from functools import lru_cache


class Unavailable(RuntimeError):
    """Raised by build_engine when an engine's deps/keys are missing."""


class Engine:
    id: str = "base"
    kind: str = "local"  # or "cloud"

    def available(self) -> tuple[bool, str]:
        return True, ""

    def transcribe(self, audio_path: str, language: str | None) -> str:
        raise NotImplementedError


# --------------------------------------------------------------------------- #
# Groq — cloud baseline oracle (vanilla Whisper large-v3 / turbo)
# --------------------------------------------------------------------------- #
class GroqEngine(Engine):
    kind = "cloud"

    def __init__(self, engine_id: str, model: str):
        self.id = engine_id
        self.model = model

    def available(self) -> tuple[bool, str]:
        try:
            import groq  # noqa: F401
        except Exception:
            return False, "pip install groq"
        if not os.environ.get("GROQ_API_KEY"):
            return False, "set GROQ_API_KEY"
        return True, ""

    @lru_cache(maxsize=1)
    def _client(self):
        from groq import Groq

        return Groq(api_key=os.environ["GROQ_API_KEY"])

    def transcribe(self, audio_path: str, language: str | None) -> str:
        kwargs = dict(
            model=self.model,
            response_format="json",
            temperature=0.0,
        )
        if language:
            kwargs["language"] = language  # omit entirely for auto-detect
        with open(audio_path, "rb") as fh:
            resp = self._client().audio.transcriptions.create(
                file=(os.path.basename(audio_path), fh.read()), **kwargs
            )
        return resp.text


# --------------------------------------------------------------------------- #
# MLX — local vanilla Whisper on Apple Silicon
# --------------------------------------------------------------------------- #
class MLXWhisperEngine(Engine):
    kind = "local"

    def __init__(self, engine_id: str, repo: str):
        self.id = engine_id
        self.repo = repo

    def available(self) -> tuple[bool, str]:
        try:
            import mlx_whisper  # noqa: F401
        except Exception:
            return False, "pip install mlx-whisper (Apple Silicon only)"
        return True, ""

    def transcribe(self, audio_path: str, language: str | None) -> str:
        import mlx_whisper

        res = mlx_whisper.transcribe(
            audio_path,
            path_or_hf_repo=self.repo,
            language=language,   # None => auto/multilingual
            temperature=0.0,
        )
        return res["text"]


# --------------------------------------------------------------------------- #
# HF transformers — local Thai fine-tunes (Thonburian / Pathumma)
# This is the reliable path for the fine-tunes; MLX conversion is a separate
# milestone.
# --------------------------------------------------------------------------- #
class TransformersWhisperEngine(Engine):
    kind = "local"

    def __init__(self, engine_id: str, repo: str):
        self.id = engine_id
        self.repo = repo

    def available(self) -> tuple[bool, str]:
        try:
            import librosa  # noqa: F401
            import torch  # noqa: F401
            import transformers  # noqa: F401
        except Exception:
            return False, "pip install transformers torch librosa soundfile"
        return True, ""

    @lru_cache(maxsize=1)
    def _pipe(self):
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

    def transcribe(self, audio_path: str, language: str | None) -> str:
        import librosa

        audio, _ = librosa.load(audio_path, sr=16000, mono=True)
        gen = {"task": "transcribe"}
        if language:
            gen["language"] = language  # omit => Whisper auto-detects
        out = self._pipe()(
            {"raw": audio, "sampling_rate": 16000},
            generate_kwargs=gen,
            return_timestamps=False,
        )
        return out["text"]


# --------------------------------------------------------------------------- #
# Registry
# --------------------------------------------------------------------------- #
_REGISTRY = {
    "groq-large-v3": lambda: GroqEngine("groq-large-v3", "whisper-large-v3"),
    "groq-turbo": lambda: GroqEngine("groq-turbo", "whisper-large-v3-turbo"),
    "mlx-large-v3": lambda: MLXWhisperEngine("mlx-large-v3", "mlx-community/whisper-large-v3-mlx"),
    "mlx-turbo": lambda: MLXWhisperEngine("mlx-turbo", "mlx-community/whisper-large-v3-turbo"),
    "thonburian": lambda: TransformersWhisperEngine("thonburian", "biodatlab/whisper-th-large-v3-combined"),
    "pathumma": lambda: TransformersWhisperEngine("pathumma", "nectec/Pathumma-whisper-th-large-v3"),
}

ALL_ENGINE_IDS = list(_REGISTRY)


def build_engine(engine_id: str) -> Engine:
    if engine_id not in _REGISTRY:
        raise Unavailable(f"unknown engine '{engine_id}' (known: {', '.join(ALL_ENGINE_IDS)})")
    eng = _REGISTRY[engine_id]()
    ok, hint = eng.available()
    if not ok:
        raise Unavailable(f"engine '{engine_id}' unavailable — {hint}")
    return eng
