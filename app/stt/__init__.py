"""STT backend registry + factory.

Mirrors benchmark/engines.py's registry / build_engine() shape:

    BACKENDS               -- id -> STTBackend subclass
    build_backend(id)       -- construct + availability-check a backend

Import discipline: this module imports the *class definitions* of every
registered backend eagerly (cheap -- just class bodies), but each backend
module (e.g. mlx_whisper.py) only imports its heavy pip package (mlx_whisper,
transformers, torch, ...) lazily inside methods. So `import app.stt` stays
fast and loads no model, matching `import app` itself.
"""

from __future__ import annotations

from .base import AudioInput, STTBackend, Unavailable
from .groq_cloud import GroqCloudBackend
from .mlx_whisper import MLXWhisperBackend, PathummaMLXBackend, TyphoonTurboMLXBackend
from .pathumma import PathummaBackend

BACKENDS: dict[str, type[STTBackend]] = {
    "mlx-large-v3": MLXWhisperBackend,
    "pathumma": PathummaBackend,
    "pathumma-mlx": PathummaMLXBackend,
    "typhoon-turbo-mlx": TyphoonTurboMLXBackend,
    # Cloud, STRICTLY OPT-IN and off by default (W3-T4) -- available() gates on
    # the groq SDK + GROQ_API_KEY, so a local-only setup never reaches it.
    "groq-large-v3": GroqCloudBackend,
}

ALL_BACKEND_IDS = list(BACKENDS)


def build_backend(backend_id: str) -> STTBackend:
    """Factory: construct a backend by registry id.

    Mirrors benchmark/engines.py's build_engine(): validates the id is
    known, constructs it, and checks available() so callers get a clear
    error instead of a confusing failure deep inside transcribe().
    """
    if backend_id not in BACKENDS:
        known = ", ".join(ALL_BACKEND_IDS)
        raise Unavailable(f"unknown STT backend '{backend_id}' (known: {known})")
    backend = BACKENDS[backend_id]()
    ok, hint = backend.available()
    if not ok:
        raise Unavailable(f"backend '{backend_id}' unavailable -- {hint}")
    return backend


__all__ = [
    "AudioInput",
    "STTBackend",
    "Unavailable",
    "MLXWhisperBackend",
    "PathummaBackend",
    "PathummaMLXBackend",
    "GroqCloudBackend",
    "BACKENDS",
    "ALL_BACKEND_IDS",
    "build_backend",
]
