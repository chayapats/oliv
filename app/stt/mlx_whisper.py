"""MLX Whisper backend -- vanilla whisper-large-v3 via Apple's MLX runtime.

This is the FALLBACK STT backend for OLIV (PRIMARY is Pathumma, wired in
W1-T4 -- see nectec/Pathumma-whisper-th-large-v3). This is the one working
placeholder backend required by the W1-T1 Definition of Done, and mirrors
benchmark/engines.py's MLXWhisperEngine (same repo id, same auto-decode
policy, same temperature=0.0).

Import discipline: the `mlx_whisper` pip package (and therefore mlx /
mlx-metal, which load the Metal GPU backend) is only imported inside
methods, never at module scope, so that `import app` / `import app.stt`
stays fast and does not touch the GPU or load any model weights.

Audio-loading path (see _prepare_audio docstring for the decision and
evidence): mlx_whisper.transcribe() accepts either a file path (it shells
out to the `ffmpeg` CLI to decode/downmix/resample) or a numpy array
(assumed already 16kHz mono float32, no further processing). We prefer the
path form when `ffmpeg` is on PATH -- verified on this project's WAV clips,
which are actually 48kHz stereo, not 16kHz mono -- and fall back to decoding
via soundfile + a scipy/numpy resample when ffmpeg is unavailable, so this
backend keeps working even on a machine without the ffmpeg CLI installed.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Union

import numpy as np

from .base import STTBackend

AudioInput = Union[str, Path, np.ndarray]

# Same repo as benchmark/engines.py's "mlx-large-v3" engine id.
DEFAULT_REPO = "mlx-community/whisper-large-v3-mlx"

# Community MLX conversion of nectec/Pathumma-whisper-th-large-v3 (format-only
# conversion, weights unchanged per its model card). Validated against the HF
# original over the full 66-clip eval set in the 2026-07-07 latency spike:
# 42/66 hypotheses byte-identical, thai_only WER identical, decode ~1.5s vs
# 7-9s (measured in the Phase-0 MLX latency spike).
PATHUMMA_MLX_REPO = "kinoppy555/Pathumma-whisper-th-large-v3-mlx"

# Whisper's standard temperature-fallback schedule: decoding retries at the
# next temperature when compression_ratio/avg_logprob thresholds reject the
# output (mlx_whisper implements the thresholds; they only apply when a
# schedule -- not a lone float -- is passed).
TEMPERATURE_FALLBACK = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)

TARGET_SR = 16000


class MLXWhisperBackend(STTBackend):
    id = "mlx-large-v3"

    # Decode temperature handed to mlx_whisper.transcribe(). This vanilla
    # large-v3 backend keeps the benchmark-validated greedy pin (0.0);
    # PathummaMLXBackend overrides it with TEMPERATURE_FALLBACK (see below).
    temperature: float | tuple[float, ...] = 0.0

    def __init__(self, repo: str = DEFAULT_REPO):
        self.repo = repo

    def available(self) -> tuple[bool, str]:
        try:
            import mlx_whisper  # noqa: F401
        except Exception:
            return False, "pip install mlx-whisper (Apple Silicon only)"
        return True, ""

    def warm_up(self) -> bool:
        """Pre-load model weights into mlx_whisper's internal ModelHolder
        cache so a subsequent transcribe() call only pays for decoding --
        lets callers (e.g. the selftest) report model-load time and
        transcription time separately.

        This reaches into mlx_whisper's internal (undocumented)
        ModelHolder cache; transcribe() itself calls
        `ModelHolder.get_model(path_or_hf_repo, dtype)`, so pre-populating
        that same cache here means the real transcribe() call below finds
        the model already loaded and skips reloading it. If this internal
        API ever changes across mlx_whisper versions, we just return False
        and callers fall back to combined load+transcribe timing.
        """
        try:
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder

            ModelHolder.get_model(self.repo, mx.float16)
            return True
        except Exception:
            return False

    def transcribe(
        self,
        audio: AudioInput,
        language: str | None = None,
        initial_prompt: str | None = None,
    ) -> str:
        import mlx_whisper

        payload = self._prepare_audio(audio)
        result = mlx_whisper.transcribe(
            payload,
            path_or_hf_repo=self.repo,
            language=language,  # None => auto/multilingual decode (never forced)
            temperature=self.temperature,
            # None => omitted; mlx_whisper treats a falsy initial_prompt as "no
            # prompt", so an empty vocabulary is byte-identical to the pre-B3 call.
            initial_prompt=initial_prompt or None,
        )
        return result["text"]

    def transcribe_ex(
        self,
        audio: AudioInput,
        language: str | None = None,
        initial_prompt: str | None = None,
    ) -> dict:
        """mlx_whisper decode exposing the per-segment avg_logprob (mean) and the
        auto-detected language -- the confidence signal the forced-en re-decode
        compares. See base.STTBackend.transcribe_ex."""
        import mlx_whisper

        payload = self._prepare_audio(audio)
        result = mlx_whisper.transcribe(
            payload, path_or_hf_repo=self.repo, language=language,
            temperature=self.temperature, initial_prompt=initial_prompt or None,
        )
        segs = result.get("segments") or []
        avg = (sum(s.get("avg_logprob", -10.0) for s in segs) / len(segs)
               if segs else None)
        return {"text": result["text"], "avg_logprob": avg,
                "language": result.get("language")}

    def _prepare_audio(self, audio: AudioInput):
        """Normalize `audio` into whatever mlx_whisper.transcribe() wants.

        - numpy array: assumed already 16kHz mono float32 per this
          backend's interface contract (this is what the W1-T2 capture
          stage will hand in directly, no file round-trip). Passed
          straight through.
        - path (str/Path): if the `ffmpeg` CLI is on PATH, hand the path
          straight to mlx_whisper -- its internal loader shells out to
          ffmpeg to decode/downmix/resample any input format to 16kHz
          mono. Verified: this project's sample clips are 48kHz stereo
          WAVs, and this path correctly round-trips them (transcript
          matches the manifest reference closely; see selftest output).
          If ffmpeg is NOT on PATH, we decode ourselves with soundfile
          (downmix to mono by averaging channels, then resample to 16kHz
          with scipy.signal.resample_poly, falling back further to plain
          numpy linear interpolation if scipy is unavailable) and hand
          mlx_whisper the resulting array instead.
        """
        if isinstance(audio, np.ndarray):
            return audio.astype(np.float32, copy=False)

        path = str(audio)
        if shutil.which("ffmpeg"):
            return path
        return self._load_wav_as_array(path)

    @staticmethod
    def _load_wav_as_array(path: str) -> np.ndarray:
        import soundfile as sf

        data, sr = sf.read(path, dtype="float32", always_2d=True)
        mono = data.mean(axis=1)  # downmix any channel count to mono
        if sr != TARGET_SR:
            mono = _resample(mono, sr, TARGET_SR)
        return mono.astype(np.float32, copy=False)


class PathummaMLXBackend(MLXWhisperBackend):
    """Pathumma via MLX -- the PRIMARY STT backend as of the 2026-07-07
    latency decision (option A).

    Same Thai fine-tune as pathumma.py's PathummaBackend, but running on
    mlx-whisper instead of HF transformers/MPS: ~1.5s/utterance vs 7-9s,
    with post-cleanup quality measured equal on the eval set (mixed bucket
    identical). The HF backend stays registered for A/B comparison.

    temperature: the fallback schedule is REQUIRED for this model, not a
    nicety -- with a pinned 0.0 the fine-tune collapses into a repetition
    loop on some pure-English utterances (eval clip en06: WER 383%); the
    compression-ratio threshold catches the loop and retries warmer, which
    fixed it in the spike while leaving all other clips' latency untouched
    (only rejected decodes pay for retries).
    """

    id = "pathumma-mlx"
    temperature = TEMPERATURE_FALLBACK

    def __init__(self, repo: str = PATHUMMA_MLX_REPO):
        super().__init__(repo=repo)


# Typhoon Whisper Turbo (SCB10X, MIT license) — a Thai fine-tune of
# whisper-large-v3-turbo (~800M, HALF Pathumma's ~1.5B). Benchmarked AHEAD of
# Pathumma on meaning at half the size (main 92.1 vs 90.6, unseen holdout 85.0 vs
# 72.5 — far better generalization to new jargon/English), and it exposes
# avg_logprob so the forced-en re-decode still applies. Convert once to MLX and
# host on HF; the repo id is overridable via OLIV_TYPHOON_MLX_REPO (a local path
# during bring-up, an HF repo id once published for the app to snapshot_download).
TYPHOON_TURBO_MLX_REPO = os.environ.get("OLIV_TYPHOON_MLX_REPO", "chayapats/typhoon-whisper-turbo-mlx")


class TyphoonTurboMLXBackend(MLXWhisperBackend):
    """Typhoon Whisper Turbo via MLX — candidate primary STT (see class comment
    above). Keeps the temperature-fallback schedule for robustness parity."""

    id = "typhoon-turbo-mlx"
    temperature = TEMPERATURE_FALLBACK
    # typhoon-turbo repetition-loops when its decode is primed with a vocab term
    # (verified on Cassandra/Vault); it transcribes clean WITHOUT a prompt, and the
    # post-STT vocab corrector restores the terms. So skip prompt seeding here.
    seed_prompt = False

    def __init__(self, repo: str = TYPHOON_TURBO_MLX_REPO):
        super().__init__(repo=repo)


def _resample(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    """Resample a 1-D float32 array from sr_in to sr_out.

    Prefers scipy.signal.resample_poly (scipy ships as a transitive
    mlx-whisper dependency, so it's already installed) and falls back to
    plain numpy linear interpolation if scipy is somehow unavailable --
    lower quality, but keeps this fallback-of-a-fallback dependency-free.
    """
    if sr_in == sr_out:
        return x
    try:
        from math import gcd

        from scipy.signal import resample_poly

        g = gcd(sr_in, sr_out)
        return resample_poly(x, sr_out // g, sr_in // g).astype(np.float32)
    except Exception:
        duration = len(x) / sr_in
        n_out = int(round(duration * sr_out))
        t_in = np.linspace(0, duration, num=len(x), endpoint=False)
        t_out = np.linspace(0, duration, num=n_out, endpoint=False)
        return np.interp(t_out, t_in, x).astype(np.float32)
