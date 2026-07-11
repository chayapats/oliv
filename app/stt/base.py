"""STT backend base class.

Mirrors benchmark/engines.py's `Engine` shape so the Phase-0 benchmark
harness and this app prototype share the same mental model:

    backend.transcribe(audio, language: str | None) -> str
    backend.available() -> (bool, str)

`language=None` means auto / multilingual decode -- the default decode
policy for Thai+English code-switching (never force a language token).
`language="th"` / `"en"` forces that language's token.

Unlike engines.py (which only accepts a WAV path), `transcribe()` here also
accepts a 16kHz mono float32 numpy array directly, since the future W1-T2
capture stage hands audio to the STT stage in-memory rather than round-
tripping through a file.
"""

from __future__ import annotations

from pathlib import Path
from typing import Union

import numpy as np

# A WAV path, or a 16kHz mono float32 numpy array.
AudioInput = Union[str, Path, np.ndarray]


class Unavailable(RuntimeError):
    """Raised by build_backend() when a backend's deps/weights are missing."""


class STTBackend:
    """Common interface every STT backend implements."""

    id: str = "base"

    # Whether it is SAFE to seed this backend's decode with an initial_prompt
    # (the custom-vocabulary / format-command hint). Whisper prompt-following is
    # model-specific: some ignore it, and some (typhoon-turbo) fall into a
    # repetition loop when primed with a term the audio only weakly supports. When
    # False, the sidecar skips prompt seeding and relies on the deterministic
    # post-STT vocab corrector / format matcher instead (which are more robust).
    seed_prompt: bool = True

    def available(self) -> tuple[bool, str]:
        """Return (True, "") if this backend is ready to use right now,
        else (False, human-readable hint) -- e.g. missing pip package."""
        return True, ""

    def warm_up(self) -> bool:
        """Best-effort: pre-load model weights so a later transcribe() call's
        wall time reflects decoding only, not model load.

        Returns True if this backend actually separated load from decode
        (caller can time warm_up() and transcribe() independently), or
        False if it's a no-op (caller should then treat the first
        transcribe() call's timing as combined load+transcribe). Default
        implementation is a no-op -- override where the backend's library
        exposes a cacheable model-load step.
        """
        return False

    def transcribe(
        self,
        audio: AudioInput,
        language: str | None = None,
        initial_prompt: str | None = None,
    ) -> str:
        """Transcribe `audio` and return plain text.

        audio: WAV path (str/Path, any sample rate/channel layout -- the
               backend normalizes it) or a 16kHz mono float32 numpy array.
        language: None => auto/multilingual decode (default policy).
                  "th" / "en" => force that language's token.
        initial_prompt: optional decode-time context string that biases the
               model toward the words/spelling it contains -- the Whisper
               `initial_prompt` mechanism, used by OLIV's custom-vocabulary
               feature to steer recognition of names / jargon / product terms
               that post-hoc replacement can't fix (it only helps when STT
               already got "close"). None (default) => no prompt, behaviour
               byte-identical to before. A backend that has no prompt hook
               MAY ignore it (documented per backend).
        """
        raise NotImplementedError

    def transcribe_ex(
        self,
        audio: AudioInput,
        language: str | None = None,
        initial_prompt: str | None = None,
    ) -> dict:
        """Like transcribe() but return a dict with a confidence signal:
        {"text": str, "avg_logprob": float | None, "language": str | None}.

        avg_logprob is the mean per-segment log-probability of the decode
        (higher = more confident); None on backends that don't expose it. Used by
        the garble-triggered forced-English re-decode: decode auto, and if the
        transcript looks like a wrong-language garble, decode again with
        language="en" and keep whichever decode is more confident. The default
        wraps transcribe() with avg_logprob=None so callers degrade gracefully."""
        return {"text": self.transcribe(audio, language, initial_prompt),
                "avg_logprob": None, "language": language}
