"""Push-to-talk audio capture (W1-T3).

Wave-1 pipeline: hold hotkey -> **capture 16kHz mono audio (this stage)** ->
STT -> cleanup -> paste. `app.hotkey.PushToTalkListener` turns the physical
key hold into `on_press` / `on_release` callbacks (see that module's
threading contract); this module turns those into the actual 16kHz mono
float32 numpy array that is the STT stage's array contract (see
`app/stt/base.py`'s `AudioInput`).

Implementation: `sounddevice` (PortAudio bindings). `Recorder.start()` opens
a callback-based `sounddevice.InputStream` that appends raw chunks to a list
from PortAudio's own audio thread; `Recorder.stop()` stops/joins the stream,
concatenates + normalizes the buffered chunks into one 16kHz mono float32
array, and computes capture stats (`.stats`) along the way.

Samplerate strategy: we *try* to open the input device directly at the
target rate (16kHz) first -- verified on this dev machine (MacBook Pro
built-in mic via Core Audio) to just work, no resampling needed. If opening
at 16kHz raises (some external/aggregate devices only expose their own
native rate, e.g. 48kHz), we fall back to opening at the device's default
samplerate and resample to 16kHz mono on `stop()` via
`scipy.signal.resample_poly` -- the same helper `app/stt/mlx_whisper.py`
uses for its WAV-decode fallback path. Either way, `.stats.resampled` /
`.stats.device_samplerate` (and `.stats.path`) report which path ran.

Threading / callback contract
------------------------------
`Recorder.start()` only opens + starts the PortAudio stream and returns --
non-blocking, safe to call from `PushToTalkListener`'s callback thread.
`Recorder.stop()` is a short blocking call (stream stop/join + an in-memory
concatenate/resample); fine from a worker thread (see `DictationSession`
below) but should not be called directly from the hotkey listener thread,
since resampling a long utterance can take tens of milliseconds and
pynput's contract says don't block there.

Import discipline: only stdlib/numpy at module load. `sounddevice`,
`soundfile`, `scipy.signal`, and `AVFoundation` are imported lazily inside
the functions/methods that need them, mirroring app/stt/mlx_whisper.py, so
`import app.audio` stays fast and pulls in no audio/Core Audio machinery.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import numpy as np

logger = logging.getLogger("oliv.audio")

TARGET_SAMPLERATE = 16000


# ---------------------------------------------------------------------------
# Microphone permission probing (macOS TCC, mirrors app.hotkey's
# check_event_access / permission_hint shape)
# ---------------------------------------------------------------------------
_AUTH_STATUS_NAMES = {0: "not_determined", 1: "restricted", 2: "denied", 3: "authorized"}


def check_microphone_access() -> tuple[bool, str]:
    """Preflight macOS Microphone (TCC) authorization via AVFoundation.

    Returns (authorized, status_name) where status_name is one of
    "authorized", "denied", "restricted", "not_determined" (never asked --
    the first real capture attempt will trigger the system prompt), or
    "unknown" (AVFoundation unavailable -- non-macOS, or the framework
    binding isn't installed). Never prompts, same as
    app.hotkey.check_event_access()'s CGPreflight* semantics.
    """
    try:
        import AVFoundation  # pyobjc-framework-AVFoundation, lazy
    except Exception:
        return False, "unknown"
    try:
        status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(
            AVFoundation.AVMediaTypeAudio
        )
    except Exception:
        return False, "unknown"
    name = _AUTH_STATUS_NAMES.get(int(status), "unknown")
    return name == "authorized", name


def microphone_permission_hint() -> str:
    """The exact, human-facing hint to show when microphone access is missing."""
    return (
        "Grant Microphone access to your terminal: System Settings -> Privacy & "
        "Security -> Microphone -> enable your terminal app (then fully quit and "
        "relaunch it)."
    )


# ---------------------------------------------------------------------------
# Capture stats
# ---------------------------------------------------------------------------
@dataclass
class CaptureStats:
    """Stats for one Recorder.start()/stop() capture cycle."""

    duration_s: float = 0.0
    n_samples: int = 0
    samplerate: int = TARGET_SAMPLERATE  # rate of the *returned* array
    device_samplerate: float = TARGET_SAMPLERATE  # rate the stream actually opened at
    resampled: bool = False
    peak: float = 0.0
    rms: float = 0.0
    input_overflow_count: int = 0
    input_underflow_count: int = 0
    other_status_count: int = 0
    stop_forced: bool = False  # PortAudio wedged on stop; stream abandoned, buffer salvaged

    @property
    def path(self) -> str:
        """Which samplerate path this capture took -- 'native' (opened the
        device directly at the target rate) or 'resampled' (device only
        offered its own default rate; we resampled on stop())."""
        if self.resampled:
            return f"resampled ({self.device_samplerate:g}Hz -> {self.samplerate}Hz)"
        return f"native ({self.samplerate}Hz)"

    def pretty(self) -> str:
        lines = [
            f"  duration:         {self.duration_s:.3f}s",
            f"  n_samples:        {self.n_samples}",
            f"  samplerate:       {self.samplerate}Hz ({self.path})",
            f"  peak amplitude:   {self.peak:.5f}",
            f"  rms:              {self.rms:.6f}",
            f"  overflow count:   {self.input_overflow_count}",
            f"  underflow count:  {self.input_underflow_count}",
        ]
        if self.other_status_count:
            lines.append(f"  other status flags: {self.other_status_count}")
        if self.stop_forced:
            lines.append("  stop_forced:      True (PortAudio wedged; stream abandoned, audio salvaged)")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Recorder
# ---------------------------------------------------------------------------
# Pa_StopStream can block *indefinitely* on macOS when coreaudiod/the HAL is in
# a bad state (observed live on this machine: stop() wedged >8min at 0% CPU
# with the identical code passing moments later). A dictation app must never
# lose the captured utterance to that, so stopping is staged and every
# PortAudio call is bounded:
#   1. graceful: signal the audio callback to raise sd.CallbackStop -- PortAudio
#      then stops the stream from its own side and fires finished_callback
#      (this path completed even in the context where Pa_StopStream wedged);
#   2. forced: abort() then close(), each in a daemon thread with a timeout;
#   3. abandoned: if PortAudio still blocks, leak the wedged stream (daemon
#      thread may finish later), log loudly, set stats.stop_forced -- and in
#      every case return the salvaged audio buffer.
_STOP_GRACEFUL_TIMEOUT_S = 1.0
_STOP_FORCE_TIMEOUT_S = 2.0


def _bounded_call(fn: Callable[[], object], timeout: float, label: str) -> bool:
    """Run fn() on a daemon thread, wait up to `timeout`s. True = completed
    (exceptions count as completed and are logged); False = still blocked."""
    done = threading.Event()

    def _run() -> None:
        try:
            fn()
        except Exception:
            logger.warning("%s raised (ignored; stream being torn down)", label, exc_info=True)
        finally:
            done.set()

    threading.Thread(target=_run, name=f"oliv-{label}", daemon=True).start()
    completed = done.wait(timeout)
    if not completed:
        logger.warning("%s did not return within %.1fs -- abandoning wedged stream", label, timeout)
    return completed


class Recorder:
    """Callback-based microphone capture, normalized to 16kHz mono float32.

    Repeated `start()`/`stop()` cycles on one instance are supported (each
    `start()` opens a fresh `sounddevice.InputStream`; PortAudio streams, like
    pynput Listeners, are one-shot). Misuse raises a clear `RuntimeError`
    rather than crashing or leaving a zombie stream:
      - `stop()` with no active capture -> RuntimeError.
      - `start()` while already started -> RuntimeError (previous stream is
        left running untouched; call `stop()` first).
    """

    def __init__(
        self,
        samplerate: int = TARGET_SAMPLERATE,
        channels: int = 1,
        dtype: str = "float32",
        device: "int | str | None" = None,
    ) -> None:
        self.samplerate = int(samplerate)
        self.channels = int(channels)
        self.dtype = dtype
        self.device = device

        self._lifecycle_lock = threading.RLock()
        self._stream = None  # sounddevice.InputStream | None
        self._stream_samplerate: float = float(self.samplerate)
        self._resampled_path = False
        self._stop_requested: Optional[threading.Event] = None  # per-capture, set by stop()
        self._finished: Optional[threading.Event] = None  # per-capture, set by PortAudio

        self._buffer_lock = threading.Lock()
        self._chunks: list[np.ndarray] = []
        self._statuses: list = []

        self.stats: Optional[CaptureStats] = None

    @property
    def running(self) -> bool:
        return self._stream is not None

    def start(self) -> "Recorder":
        """Begin capturing into an internal buffer. Non-blocking -- safe to
        call from the hotkey listener thread (see module docstring)."""
        with self._lifecycle_lock:
            if self._stream is not None:
                raise RuntimeError(
                    "Recorder already started -- call stop() before starting again"
                )
            with self._buffer_lock:
                self._chunks = []
                self._statuses = []

            stream, opened_samplerate, resampled_path = self._open_stream()
            self._stream = stream
            self._stream_samplerate = opened_samplerate
            self._resampled_path = resampled_path
            stream.start()
        return self

    def _open_stream(self):
        """Try opening the input device at `self.samplerate` directly; on
        failure, fall back to the device's default samplerate (resampled to
        `self.samplerate` on stop()). Returns (stream, opened_samplerate,
        resampled_path)."""
        import sounddevice as sd

        stop_requested = threading.Event()
        finished = threading.Event()
        self._stop_requested = stop_requested
        self._finished = finished

        def _callback(indata, frames, time_info, status) -> None:
            # Runs on PortAudio's own audio thread.
            if status:
                with self._buffer_lock:
                    self._statuses.append(status)
            with self._buffer_lock:
                self._chunks.append(indata.copy())
            if stop_requested.is_set():
                # Stop the stream from the audio side (graceful path of stop()):
                # PortAudio finishes up and fires finished_callback.
                raise sd.CallbackStop

        common = dict(
            channels=self.channels,
            dtype=self.dtype,
            device=self.device,
            callback=_callback,
            finished_callback=finished.set,
        )
        try:
            stream = sd.InputStream(samplerate=self.samplerate, **common)
            return stream, float(self.samplerate), False
        except Exception as exc:
            logger.warning(
                "opening input device at %dHz failed (%s) -- falling back to "
                "the device's default samplerate + resample-on-stop",
                self.samplerate,
                exc,
            )
            device_info = sd.query_devices(self.device, "input")
            default_sr = float(device_info["default_samplerate"])
            stream = sd.InputStream(samplerate=default_sr, **common)
            return stream, default_sr, True

    def stop(self) -> np.ndarray:
        """Stop capturing and return the full 16kHz mono float32 array. Also
        refreshes `.stats`. Raises RuntimeError if no capture is active.

        Bounded: never blocks longer than ~_STOP_GRACEFUL_TIMEOUT_S +
        2*_STOP_FORCE_TIMEOUT_S even if PortAudio wedges (see the staged-stop
        note above the class); the captured audio is returned in every case,
        with `stats.stop_forced=True` when the stream had to be abandoned."""
        with self._lifecycle_lock:
            stream = self._stream
            if stream is None:
                raise RuntimeError(
                    "Recorder.stop() called with no active capture -- call start() first"
                )
            self._stream = None
            stop_requested, finished = self._stop_requested, self._finished
            self._stop_requested = None
            self._finished = None

            stop_forced = False
            # 1. graceful: audio-thread-side stop via CallbackStop
            stop_requested.set()
            if finished.wait(timeout=_STOP_GRACEFUL_TIMEOUT_S):
                if not _bounded_call(stream.close, _STOP_FORCE_TIMEOUT_S, "stream.close"):
                    stop_forced = True
            else:
                # 2. forced: no callback came back (device gone / HAL wedged)
                logger.warning(
                    "graceful stop not confirmed within %.1fs -- forcing abort",
                    _STOP_GRACEFUL_TIMEOUT_S,
                )
                aborted = _bounded_call(stream.abort, _STOP_FORCE_TIMEOUT_S, "stream.abort")
                closed = _bounded_call(stream.close, _STOP_FORCE_TIMEOUT_S, "stream.close")
                stop_forced = not (aborted and closed)
            stream_samplerate = self._stream_samplerate
            resampled_path = self._resampled_path

        with self._buffer_lock:
            chunks = self._chunks
            statuses = self._statuses
            self._chunks = []
            self._statuses = []

        if chunks:
            raw = np.concatenate(chunks, axis=0)
        else:
            raw = np.zeros((0, self.channels), dtype=np.float32)

        # Downmix to mono if captured with >1 channel (default channels=1
        # makes this a no-op in practice, but stay honest for other configs).
        if raw.ndim == 2 and raw.shape[1] > 1:
            mono = raw.mean(axis=1)
        else:
            mono = raw.reshape(-1)
        mono = mono.astype(np.float32, copy=False)

        if resampled_path and mono.size > 0:
            mono = _resample(mono, stream_samplerate, self.samplerate)

        overflow = sum(1 for s in statuses if getattr(s, "input_overflow", False))
        underflow = sum(1 for s in statuses if getattr(s, "input_underflow", False))
        other = sum(
            1
            for s in statuses
            if not getattr(s, "input_overflow", False) and not getattr(s, "input_underflow", False)
        )

        n = int(mono.size)
        peak = float(np.abs(mono).max()) if n else 0.0
        rms = float(np.sqrt(np.mean(np.square(mono, dtype=np.float64)))) if n else 0.0
        duration = n / float(self.samplerate) if n else 0.0

        self.stats = CaptureStats(
            duration_s=duration,
            n_samples=n,
            samplerate=self.samplerate,
            device_samplerate=stream_samplerate,
            resampled=resampled_path,
            peak=peak,
            rms=rms,
            input_overflow_count=overflow,
            input_underflow_count=underflow,
            other_status_count=other,
            stop_forced=stop_forced,
        )
        return mono


def _resample(x: np.ndarray, sr_in: float, sr_out: int) -> np.ndarray:
    """Resample a 1-D float32 array from sr_in to sr_out via
    scipy.signal.resample_poly -- same approach as
    app/stt/mlx_whisper.py's WAV-decode fallback path."""
    sr_in_i = int(round(sr_in))
    if sr_in_i == sr_out:
        return x
    from math import gcd

    from scipy.signal import resample_poly

    g = gcd(sr_in_i, sr_out)
    return resample_poly(x, sr_out // g, sr_in_i // g).astype(np.float32)


# ---------------------------------------------------------------------------
# WAV I/O + optional silence trim
# ---------------------------------------------------------------------------
def save_wav(path: "str | Path", audio: np.ndarray, samplerate: int = TARGET_SAMPLERATE) -> None:
    """Write a mono float32 array to a 16-bit PCM WAV file via soundfile."""
    import soundfile as sf

    sf.write(str(path), audio, samplerate, subtype="PCM_16")


def trim_silence(
    audio: np.ndarray,
    threshold_db: float = -45.0,
    pad_ms: float = 150.0,
    samplerate: int = TARGET_SAMPLERATE,
    frame_ms: float = 20.0,
) -> np.ndarray:
    """Trim leading/trailing silence only -- never mid-utterance.

    Frames `audio` into `frame_ms` windows, computes each frame's RMS in dB
    relative to full scale, and finds the first/last frame at or above
    `threshold_db`. Keeps everything between those frames (inclusive) plus
    `pad_ms` of padding on each side. If no frame clears the threshold (the
    whole clip reads as "silence"), returns `audio` unchanged rather than
    risking nuking a real, just-quiet utterance.

    Off by default in the pipeline -- see `OLIVConfig.trim_silence`
    (default False) in app/config.py.
    """
    n = audio.size
    if n == 0:
        return audio

    frame_len = max(1, int(samplerate * frame_ms / 1000))
    n_frames = int(np.ceil(n / frame_len))
    threshold_amp = 10.0 ** (threshold_db / 20.0)

    loud = np.zeros(n_frames, dtype=bool)
    for i in range(n_frames):
        start = i * frame_len
        end = min(n, start + frame_len)
        frame = audio[start:end]
        rms = float(np.sqrt(np.mean(np.square(frame, dtype=np.float64)))) if frame.size else 0.0
        loud[i] = rms >= threshold_amp

    if not loud.any():
        return audio

    idx = np.flatnonzero(loud)
    first, last = int(idx[0]), int(idx[-1])

    pad = int(samplerate * pad_ms / 1000)
    start = max(0, first * frame_len - pad)
    end = min(n, (last + 1) * frame_len + pad)
    return audio[start:end]


# ---------------------------------------------------------------------------
# DictationSession -- the reusable press/record/release/deliver seam
# ---------------------------------------------------------------------------
class DictationSession:
    """Wires `PushToTalkListener` + `Recorder` into a full press-to-record /
    release-to-deliver utterance loop.

    This is the reusable seam W1-T4 (real STT wiring) and W1-T6 (+ cleanup +
    paste, full E2E) build on top of, instead of each re-implementing the
    press/release plumbing:

        on_press   -> Recorder.start()      (non-blocking, listener thread)
        on_release -> hand off Recorder.stop() + on_utterance(audio, stats)
                      to a dedicated per-utterance worker thread, so a slow
                      on_utterance (STT transcription, cleanup, paste --
                      anything that blocks) never stalls pynput's CGEvent tap
                      (see app/hotkey.py's threading contract).

    Parameters
    ----------
    key:
        Hotkey name, forwarded to `PushToTalkListener` (default
        "right_option").
    recorder:
        A `Recorder` instance to reuse, or None to construct a default one.
    on_utterance(audio, stats):
        Called on a worker thread once per completed press/release cycle
        with the captured 16kHz mono float32 array and its `CaptureStats`.
        W1-T4 plugs `backend.transcribe(audio, ...)` in here; W1-T6 adds
        cleanup + paste after that. Required.
    on_error(exc):
        Optional; called (on the same worker thread) if `on_utterance` (or
        `Recorder.stop()`) raises, instead of the exception vanishing
        silently on a background thread. Defaults to logging it.
    """

    def __init__(
        self,
        key: str = "right_option",
        *,
        recorder: Optional[Recorder] = None,
        on_utterance: Callable[[np.ndarray, CaptureStats], None],
        on_error: Optional[Callable[[Exception], None]] = None,
    ) -> None:
        if on_utterance is None:
            raise ValueError("on_utterance is a required callback")
        from app.hotkey import PushToTalkListener  # lazy: keep app.audio import light

        self.recorder = recorder if recorder is not None else Recorder()
        self._on_utterance = on_utterance
        self._on_error = on_error
        self._workers: list[threading.Thread] = []
        self._workers_lock = threading.Lock()
        self._listener = PushToTalkListener(
            key, on_press=self._handle_press, on_release=self._handle_release
        )

    @property
    def hotkey(self) -> str:
        return self._listener.key_name

    def start(self) -> "DictationSession":
        self._listener.start()
        return self

    def stop(self, *, join_timeout: float = 30.0) -> None:
        """Stop listening and wait (bounded by join_timeout) for any
        in-flight utterance worker(s) so callers see a clean summary."""
        self._listener.stop()
        with self._workers_lock:
            workers = list(self._workers)
            self._workers.clear()
        for w in workers:
            w.join(timeout=join_timeout)

    def _handle_press(self) -> None:
        try:
            self.recorder.start()
        except Exception:
            logger.exception("DictationSession: Recorder.start() failed on hotkey press")

    def _handle_release(self) -> None:
        def _finish() -> None:
            try:
                audio = self.recorder.stop()
                self._on_utterance(audio, self.recorder.stats)
            except Exception as exc:
                if self._on_error is not None:
                    try:
                        self._on_error(exc)
                    except Exception:
                        logger.exception("DictationSession: on_error callback itself raised")
                else:
                    logger.exception("DictationSession: on_utterance/Recorder.stop() failed")

        t = threading.Thread(target=_finish, daemon=True, name="oliv-utterance-worker")
        with self._workers_lock:
            self._workers.append(t)
        t.start()


__all__ = [
    "Recorder",
    "CaptureStats",
    "DictationSession",
    "save_wav",
    "trim_silence",
    "check_microphone_access",
    "microphone_permission_hint",
    "TARGET_SAMPLERATE",
]
