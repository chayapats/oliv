"""Full push-to-talk dictation wire (W1-T6) -- the Wave-1 capstone.

Composes every earlier Wave-1 piece into one end-to-end pipeline:

    hold Right Option (app.hotkey via app.audio.DictationSession)
      -> capture 16kHz mono (app.audio.Recorder)
      -> STT             (app.stt: Pathumma primary / mlx-large-v3 fallback)
      -> cleanup         (app.cleanup.CleanupClient -> benchmark worker, gated
                          on config.cleanup_enabled)
      -> paste at cursor (app.inject.inject_text, Cmd+V)

`DictationApp` builds + warms the STT backend and (optionally) the CleanupClient,
then runs a `DictationSession` whose per-utterance callback runs
STT -> cleanup -> inject and records per-stage timings. It is the shared engine
behind three CLI entrypoints in app/__main__.py:

  --run          the real hold-speak-paste app (inject ON).
  --e2e-file     one clip through STT -> cleanup, NO inject (headless proof).
  --e2e-latency  ~5 clips through STT -> cleanup, latency table (NO inject).

Error philosophy: a failure in any single stage must never kill the listener or
lose the transcript. STT failure -> empty text logged; cleanup failure -> raw
STT text (CleanupClient's own guardrail); inject failure -> the final text is
logged so it is never silently lost. Exceptions still bubble to on_error, which
logs and continues.

Import discipline: only stdlib at module load. app.stt / app.cleanup / app.inject
are imported lazily inside methods so `import app.dictation` stays fast and loads
no model.

Per-app cleanup toggle (W2-T3)
-------------------------------
Cleanup used to be all-or-nothing (config.cleanup_enabled / --no-cleanup);
some apps want it off regardless: dictating into a code editor should stay
verbatim while email stays cleaned. `DictationApp.process()` resolves the
frontmost app (app/frontmost.py) ONCE per utterance, at the very start of
process() -- i.e. release-time, the app the user was actually dictating
into -- and looks its bundle id up in config.cleanup_apps. A per-app "off"
entry BYPASSES the cleanup worker entirely (CleanupClient.clean() is never
called -- no wasted subprocess round-trip); "on" or no entry falls through to
the existing global behavior. Frontmost detection can never crash the
pipeline: frontmost_app() itself never raises, and a caller-supplied
frontmost_fn is wrapped in its own try/except too; a None result (unknown
app, AppKit unavailable, or -- the mid-pipeline-app-switch caveat -- the user
Cmd-Tabbed to something else while STT/cleanup/inject were still running for
THIS utterance) degrades to "no per-app entry", i.e. the global on/off. This
is a deliberate by-design choice, not a limitation to fix: the app the user
released the hotkey in is the one whose policy applies, not whatever has
focus a few hundred ms later when inject would land.

`UtteranceRecord.log_line()` also prints a compact word-level diff (stdlib
`difflib`, e.g. `[-ไฟล์จูน +fine-tune]`) whenever cleanup changed the text --
the W2-T2 DoD's "diff preview in debug builds", surfaced here since this is
where every utterance is already logged.
"""

from __future__ import annotations

import difflib
import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Optional

from app.frontmost import FrontmostApp, frontmost_app

logger = logging.getLogger("oliv.dictation")


# --------------------------------------------------------------------------- #
# W2-T3: compact word-level debug diff (stdlib difflib only)
# --------------------------------------------------------------------------- #
def _word_diff(raw: str, final: str) -> str:
    """Compact single-line word-level diff between `raw` and `final`, e.g.
    "[-ไฟล์จูน +fine-tune]" -- shows ONLY the changed segments (equal runs are
    omitted entirely) so the line stays short even for a heavily-edited
    utterance. Tokens are plain whitespace splits (good enough for a debug
    preview; not meant to be a precise linguistic diff). Returns "" if there
    is nothing to show (e.g. only whitespace differs)."""
    a = raw.split()
    b = final.split()
    bits: list[str] = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        removed = " ".join(a[i1:i2])
        added = " ".join(b[j1:j2])
        if tag == "replace":
            bits.append(f"[-{removed} +{added}]")
        elif tag == "delete":
            bits.append(f"[-{removed}]")
        elif tag == "insert":
            bits.append(f"[+{added}]")
    return " ".join(bits)


# --------------------------------------------------------------------------- #
# Per-utterance record + session summary
# --------------------------------------------------------------------------- #
@dataclass
class UtteranceRecord:
    """One STT -> cleanup -> (inject) pass, with per-stage timings."""

    index: int
    raw: str                 # STT output
    final: str               # after cleanup (== raw if cleanup off/fell back)
    t_stt: float
    t_cleanup: float
    t_inject: float
    t_total: float           # STT + cleanup + inject (i.e. release->paste minus capture-stop)
    llm_ran: bool = False
    gate_reason: str = ""
    guardrail_flag: str = ""
    cleanup_fallback: bool = False
    cleanup_error: Optional[str] = None
    stt_error: Optional[str] = None
    inject_error: Optional[str] = None
    inject_posted: Optional[bool] = None
    duration_s: float = 0.0  # captured audio duration
    # W2-T3 (additive): frontmost app the utterance was dictated into + which
    # cleanup mode applied. app_bundle_id is "" when frontmost detection
    # failed/returned None (unknown app). cleanup_applied is one of:
    #   "on"           -- cleanup was active and not per-app-bypassed
    #   "off-per-app"  -- config.cleanup_apps[bundle_id] == "off" (bypassed)
    #   "off-global"   -- cleanup_enabled is false (client never built)
    #   ""              -- cleanup active but there was no text to clean
    app_bundle_id: str = ""
    cleanup_applied: str = ""

    def log_line(self) -> str:
        bits = [
            f"utt#{self.index}",
            f"audio={self.duration_s:.2f}s",
            f"t_stt={self.t_stt * 1000:.0f}ms",
            f"t_cleanup={self.t_cleanup * 1000:.0f}ms",
            f"t_inject={self.t_inject * 1000:.0f}ms",
            f"t_total={self.t_total * 1000:.0f}ms",
            f"llm_ran={self.llm_ran}",
            f"gate={self.gate_reason or '-'}",
            f"guardrail={self.guardrail_flag or '-'}",
            f"cleanup_fallback={self.cleanup_fallback}",
            f"app={self.app_bundle_id or '-'}",
            f"cleanup_applied={self.cleanup_applied or '-'}",
        ]
        if self.inject_posted is not None:
            bits.append(f"posted={self.inject_posted}")
        if self.stt_error:
            bits.append(f"stt_error={self.stt_error!r}")
        if self.cleanup_error:
            bits.append(f"cleanup_error={self.cleanup_error!r}")
        if self.inject_error:
            bits.append(f"inject_error={self.inject_error!r}")
        line = "  ".join(bits)
        out = f"{line}\n    raw  : {self.raw!r}\n    final: {self.final!r}"
        # W2-T2 DoD "diff preview in debug builds": only when cleanup actually
        # changed something -- no line at all when final == raw.
        if self.final != self.raw:
            diff = _word_diff(self.raw, self.final)
            if diff:
                out += f"\n    diff : {diff}"
        return out


@dataclass
class DictationSummary:
    records: list = field(default_factory=list)

    @property
    def count(self) -> int:
        return len(self.records)

    def add(self, rec: UtteranceRecord) -> None:
        self.records.append(rec)

    def _mean(self, attr: str) -> float:
        if not self.records:
            return 0.0
        return sum(getattr(r, attr) for r in self.records) / len(self.records)

    def pretty(self) -> str:
        n = self.count
        if n == 0:
            return "  (no utterances processed)"
        return (
            f"  utterances:      {n}\n"
            f"  mean t_stt:      {self._mean('t_stt') * 1000:.0f}ms\n"
            f"  mean t_cleanup:  {self._mean('t_cleanup') * 1000:.0f}ms\n"
            f"  mean t_inject:   {self._mean('t_inject') * 1000:.0f}ms\n"
            f"  mean t_total:    {self._mean('t_total') * 1000:.0f}ms"
        )


# --------------------------------------------------------------------------- #
# DictationApp -- build / warm / process / run
# --------------------------------------------------------------------------- #
class DictationApp:
    """Owns the STT backend + optional CleanupClient and drives the pipeline.

    Parameters
    ----------
    config:          a OLIVConfig.
    backend_id:      STT backend registry id override (else config.stt_backend).
    cleanup_enabled: force cleanup on/off (else config.cleanup_enabled).
    frontmost_fn:    W2-T3 -- callable returning the frontmost app (or None)
                     used to resolve config.cleanup_apps per utterance.
                     Defaults to the real app.frontmost.frontmost_app; tests
                     inject a fake here so --cleanup-toggle-unittest needs no
                     AppKit / OS permissions (see app/__main__.py).
    log:             a print-like callable for human-facing lines (default print).
    """

    def __init__(
        self,
        config,
        *,
        backend_id: Optional[str] = None,
        cleanup_enabled: Optional[bool] = None,
        frontmost_fn: Callable[[], Optional[FrontmostApp]] = frontmost_app,
        log: Callable[[str], None] = print,
    ) -> None:
        self.config = config
        self.backend_id = backend_id or config.stt_backend
        self.cleanup_enabled = (
            config.cleanup_enabled if cleanup_enabled is None else bool(cleanup_enabled)
        )
        self.frontmost_fn = frontmost_fn
        self.log = log

        self.backend = None
        self.cleanup = None
        self.summary = DictationSummary()
        self._session = None
        self._stt_load_time: Optional[float] = None
        self._cleanup_load_time: Optional[float] = None

    # -- decode language from policy --------------------------------------- #
    def _language(self) -> Optional[str]:
        policy = (self.config.decode_policy or "auto").strip().lower()
        return None if policy == "auto" else policy

    # -- build + warm ------------------------------------------------------ #
    def build(self) -> None:
        """Construct the STT backend and (if enabled) the CleanupClient. Does
        NOT load any model weights yet -- see warm()."""
        from app.stt import build_backend

        self.backend = build_backend(self.backend_id)
        if self.cleanup_enabled:
            from app.cleanup import CleanupClient

            self.cleanup = CleanupClient()

    def warm(self) -> None:
        """Load model weights: STT backend + cleanup worker. Records load times.
        A cleanup warm failure is non-fatal (cleanup falls back at runtime)."""
        if self.backend is None:
            self.build()

        t0 = time.time()
        warmed = self.backend.warm_up()
        if warmed:
            self._stt_load_time = time.time() - t0

        if self.cleanup is not None:
            self._cleanup_load_time = self.cleanup.warm_up()

    # -- the core pipeline ------------------------------------------------- #
    def process(self, audio, *, duration_s: float = 0.0, inject: bool) -> UtteranceRecord:
        """Run one utterance: STT -> cleanup -> (optional inject). Every stage
        is individually guarded so one failure never sinks the whole record."""
        idx = self.summary.count + 1
        t_total_0 = time.perf_counter()

        # -- W2-T3: resolve the frontmost app ONCE, at utterance start -- i.e.
        # release-time, the app the user actually dictated into (see the
        # module docstring for the mid-pipeline-app-switch caveat). Never
        # allowed to crash the pipeline: a failing frontmost_fn degrades to
        # "unknown app" exactly like a None return.
        try:
            frontmost = self.frontmost_fn()
        except Exception:
            logger.exception("frontmost_fn failed; treating as unknown app (global behavior)")
            frontmost = None
        app_bundle_id = frontmost.bundle_id if frontmost is not None else ""
        # Bundle-id keys in config.cleanup_apps are lowercased in
        # OLIVConfig.__post_init__ (macOS treats bundle ids
        # case-insensitively); lowercase the lookup side to match. `.lower()`
        # on "" is a no-op, but the `if app_bundle_id` guard keeps the
        # "unknown app" case an explicit None rather than a "" lookup.
        per_app_mode = self.config.cleanup_apps.get(app_bundle_id.lower()) if app_bundle_id else None

        # -- STT --
        raw = ""
        stt_error = None
        t0 = time.perf_counter()
        try:
            raw = self.backend.transcribe(audio, language=self._language())
        except Exception as exc:
            stt_error = f"{type(exc).__name__}: {exc}"
            logger.exception("STT stage failed")
        t_stt = time.perf_counter() - t0

        # -- cleanup (guardrails live in CleanupClient: never loses raw text) --
        # W2-T3: per_app_mode == "off" BYPASSES cleanup entirely -- the
        # worker is never called (not just discarded), so final is raw,
        # byte-identical, and t_cleanup stays 0.0. self.cleanup is None
        # whenever cleanup is off GLOBALLY (config.cleanup_enabled=false /
        # --no-cleanup): that always wins over the table, since a per-app
        # entry can only REFINE a globally-ON config, never turn it back on.
        final = raw
        llm_ran = False
        gate_reason = ""
        guardrail_flag = ""
        cleanup_fallback = False
        cleanup_error = None
        t_cleanup = 0.0
        if self.cleanup is None:
            cleanup_applied = "off-global"
        elif per_app_mode == "off":
            cleanup_applied = "off-per-app"
        else:
            cleanup_applied = ""
            if raw.strip():
                t0 = time.perf_counter()
                outcome = self.cleanup.clean(raw)
                t_cleanup = time.perf_counter() - t0
                final = outcome.text
                llm_ran = outcome.llm_ran
                gate_reason = outcome.gate_reason
                guardrail_flag = outcome.guardrail_flag
                cleanup_fallback = outcome.used_fallback
                cleanup_error = outcome.error
                cleanup_applied = "on"

        # -- inject --
        t_inject = 0.0
        inject_error = None
        inject_posted: Optional[bool] = None
        if inject and final.strip():
            from app.inject import inject_text

            t0 = time.perf_counter()
            try:
                result = inject_text(final, mode=self.config.paste_mode)
                inject_posted = result.posted
                if not result.posted:
                    # Not an error per se (may be clipboard_only / gated), but
                    # surface the note so the text is never silently lost.
                    logger.info("inject did not post (mode=%s): %s", result.mode, result.notes)
            except Exception as exc:
                inject_error = f"{type(exc).__name__}: {exc}"
                # inject failed -> log the final text so it isn't lost.
                logger.error("inject stage failed; final text NOT pasted: %r", final)
            t_inject = time.perf_counter() - t0

        t_total = time.perf_counter() - t_total_0

        rec = UtteranceRecord(
            index=idx,
            raw=raw,
            final=final,
            t_stt=t_stt,
            t_cleanup=t_cleanup,
            t_inject=t_inject,
            t_total=t_total,
            llm_ran=llm_ran,
            gate_reason=gate_reason,
            guardrail_flag=guardrail_flag,
            cleanup_fallback=cleanup_fallback,
            cleanup_error=cleanup_error,
            stt_error=stt_error,
            inject_error=inject_error,
            inject_posted=inject_posted,
            duration_s=duration_s,
            app_bundle_id=app_bundle_id,
            cleanup_applied=cleanup_applied,
        )
        self.summary.add(rec)
        return rec

    # -- the live --run loop ----------------------------------------------- #
    def run(self, *, duration: Optional[float] = None) -> None:
        """Start the push-to-talk session and process utterances until Ctrl-C
        (or `duration` seconds elapse -- used by the headless startup smoke).
        Each utterance's structured log line is printed via self.log.

        Ctrl-C handling: pynput's macOS event-tap listener runs its own
        CFRunLoop and swallows the process SIGINT, so a plain
        `except KeyboardInterrupt` around `time.sleep` never fires while the
        listener is up. We therefore install our own SIGINT handler that just
        sets a stop Event, and poll that Event -- this makes Ctrl-C reliably
        stop the app. (Falls back to KeyboardInterrupt if run() isn't on the
        main thread, where signal.signal is illegal.)"""
        import signal

        from app.audio import DictationSession

        stop = threading.Event()

        def on_utterance(audio, stats) -> None:
            rec = self.process(audio, duration_s=stats.duration_s, inject=True)
            self.log("\n" + rec.log_line())

        def on_error(exc: Exception) -> None:
            logger.exception("utterance worker error (listener continues)")
            self.log(f"\n[utterance error] {exc!r}")

        self._session = DictationSession(
            self.config.hotkey, on_utterance=on_utterance, on_error=on_error
        )
        self._session.start()
        self.log(
            f"\nHold {self.config.hotkey.replace('_', ' ').title()} and speak; "
            "release to paste. Ctrl-C to quit.\n"
        )

        prev_handler = None
        installed = False
        try:
            prev_handler = signal.signal(signal.SIGINT, lambda *_a: stop.set())
            installed = True
        except (ValueError, OSError):
            installed = False  # not main thread -> rely on KeyboardInterrupt below

        interrupted = False
        try:
            deadline = None if duration is None else time.monotonic() + duration
            while not stop.is_set():
                if deadline is not None and time.monotonic() >= deadline:
                    break
                time.sleep(0.1)
            interrupted = stop.is_set()
        except KeyboardInterrupt:
            interrupted = True
        finally:
            if installed and prev_handler is not None:
                try:
                    signal.signal(signal.SIGINT, prev_handler)
                except Exception:
                    pass
            self._session.stop()
        if interrupted:
            self.log("\n(interrupted)")

    # -- teardown ---------------------------------------------------------- #
    def close(self) -> None:
        """Reap the cleanup worker (no zombie). Idempotent."""
        if self.cleanup is not None:
            self.cleanup.close()
            self.cleanup = None

    def __enter__(self) -> "DictationApp":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


__all__ = ["DictationApp", "DictationSummary", "UtteranceRecord"]
