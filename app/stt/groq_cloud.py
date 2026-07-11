"""Groq cloud STT backend -- vanilla whisper-large-v3 via Groq's hosted API.

PRIVACY CAVEAT (this backend is the ONE exception to OLIV's on-device rule):
OLIV is a privacy-first, local-by-default app -- every other STT backend
(pathumma-mlx, mlx-large-v3, pathumma) runs entirely on this Mac and no audio
ever leaves the machine. This backend does the opposite: it UPLOADS the
utterance's audio to Groq's servers for transcription. It is therefore
STRICTLY OPT-IN and OFF by default (the W3-T4 DoD: "opt-in Groq cloud fallback
tier surfaced (off by default)"). The macOS app only ever selects this engine
after the user turns on the "Cloud fallback" toggle AND enters an API key; a
local-only setup never constructs or reaches this class.

Mirrors benchmark/engines.py's proven GroqEngine (W0 baseline oracle): same
whisper-large-v3 model, same `audio.transcriptions.create` call shape,
response_format="json", temperature=0.0, and the same auto-vs-forced language
policy (omit `language` for auto-detect, pass "th"/"en" to force a token).

Import discipline (identical to the sibling backends): the `groq` pip package
is imported ONLY inside methods, never at module scope, so `import app` /
`import app.stt` stays fast and pulls in no cloud SDK on a local-only run. The
key never lives in the module either -- it is read from the GROQ_API_KEY
environment variable at call time (the sidecar receives it in its spawn env
only when the app's opt-in toggle is on).
"""

from __future__ import annotations

import os
import tempfile
from functools import lru_cache
from pathlib import Path
from typing import Union

import numpy as np

from .base import STTBackend

AudioInput = Union[str, Path, np.ndarray]

# Same model id as benchmark/engines.py's "groq-large-v3" engine.
DEFAULT_MODEL = "whisper-large-v3"
TARGET_SR = 16000


class GroqCloudBackend(STTBackend):
    id = "groq-large-v3"

    def __init__(self, model: str = DEFAULT_MODEL):
        self.model = model

    def available(self) -> tuple[bool, str]:
        """Ready only when BOTH the SDK is installed AND a key is set. Either
        gap returns (False, hint) so a local-only setup (no groq SDK, or no
        GROQ_API_KEY) is untouched -- build_backend() turns this into a clear
        Unavailable rather than a confusing failure mid-transcribe()."""
        try:
            import groq  # noqa: F401
        except Exception:
            return False, "pip install groq"
        if not os.environ.get("GROQ_API_KEY"):
            return False, "set GROQ_API_KEY (cloud engine is opt-in)"
        return True, ""

    @lru_cache(maxsize=1)
    def _client(self):
        """Construct (and cache) the Groq client. lru_cache keyed on `self`
        (identity) so repeated transcribe() calls reuse one client. Reads the
        key at construction time -- never network here (matches the benchmark
        GroqEngine)."""
        from groq import Groq

        return Groq(api_key=os.environ["GROQ_API_KEY"])

    def transcribe(
        self,
        audio: AudioInput,
        language: str | None = None,
        initial_prompt: str | None = None,
    ) -> str:
        """Upload `audio` to Groq and return the transcript text.

        audio: a WAV path (str/Path -- uploaded as-is; Groq decodes it) OR a
               16kHz mono float32 numpy array (this project's in-memory capture
               shape), which we spill to a temporary WAV first since the HTTP
               API takes a file, not an array. The temp file is always removed.
        language: None => auto-detect (default policy); "th"/"en" => forced.
        initial_prompt: passed as the transcription `prompt` (Groq/Whisper's
               vocabulary-biasing field) when non-empty; omitted otherwise so a
               no-vocabulary call is unchanged.
        """
        path, tmp = self._as_wav_path(audio)
        try:
            kwargs = dict(
                model=self.model,
                response_format="json",
                temperature=0.0,
            )
            if language:
                kwargs["language"] = language  # omit entirely => auto-detect
            if initial_prompt:
                kwargs["prompt"] = initial_prompt  # vocabulary bias (Whisper prompt)
            with open(path, "rb") as fh:
                resp = self._client().audio.transcriptions.create(
                    file=(os.path.basename(path), fh.read()), **kwargs
                )
            return resp.text
        finally:
            if tmp is not None:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass

    @staticmethod
    def _as_wav_path(audio: AudioInput) -> tuple[str, "str | None"]:
        """Return (path_to_upload, temp_path_to_delete_or_None).

        A path is uploaded directly (no temp file). A numpy array is written to
        a fresh temp WAV via soundfile (16kHz mono float32) -- the caller
        deletes it in a finally. soundfile ships as a sidecar/.venv dependency."""
        if isinstance(audio, np.ndarray):
            import soundfile as sf

            data = audio.astype(np.float32, copy=False)
            fd, tmp = tempfile.mkstemp(suffix=".wav", prefix="oliv_groq_")
            os.close(fd)
            sf.write(tmp, data, TARGET_SR, subtype="FLOAT")
            return tmp, tmp
        return str(audio), None
