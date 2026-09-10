"""Cleanup client (W1-T6) -- the app-side half of the venv bridge.

Wave-1 pipeline: hold hotkey -> capture -> STT -> **cleanup (this stage)** ->
paste. The cleanup stage (benchmark/pipeline.py's dict -> gate -> Gemma-4 pass)
CANNOT run in-process: it needs mlx-lm 0.31.3 + transformers==5.0.0, which
conflict with the STT stack's transformers 5.13 living in `.venv-app`. So it
runs as a subprocess worker (benchmark/cleanup_worker.py) in its own
`.venv-gemma4`, and this `CleanupClient` talks to it over a line-oriented JSON
stdio protocol (see cleanup_worker.py for the protocol spec). This is what the
config knob `cleanup_mode = "worker"` (was "inprocess_or_worker_tbd") resolves
to.

GUARDRAIL (correctness-critical)
--------------------------------
Cleanup is a *nice-to-have* on top of the raw transcript, so it must NEVER lose
or corrupt what STT produced. On ANY failure -- worker never spawned, dead
process, read timeout, non-JSON reply, ok:false -- `clean()` returns the
ORIGINAL text unchanged with `used_fallback=True` and `error` set. Pasting raw
STT text is acceptable; pasting nothing or garbage is not. This mirrors the
pipeline's own philosophy (its guardrails fall back to the post-dictionary
text; here the fallback target is the raw STT text the app handed in).

Timeout without hanging
-----------------------
`subprocess`'s `readline()` blocks uninterruptibly, so a wedged worker would
hang the app forever. Instead a daemon reader thread drains the worker's stdout
into a `queue.Queue`, and `clean()` does a bounded `queue.get(timeout=...)`. A
request that times out leaves the worker in an unknown state (it may still be
mid-generation), so we kill it and respawn on the next call -- the timed-out
request itself falls back to the raw text.

Import discipline: only stdlib at module load (subprocess/threading/queue/json)
-- no mlx/transformers/torch -- so `import app.cleanup` stays fast, matching the
rest of the package.
"""

from __future__ import annotations

import json
import logging
import os
import queue
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

logger = logging.getLogger("oliv.cleanup")

# app/cleanup.py -> app/ -> <project root>
_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_BENCHMARK_DIR = _PROJECT_ROOT / "benchmark"
_WORKER_SCRIPT = _BENCHMARK_DIR / "cleanup_worker.py"

# The cleanup venv lives under benchmark/ on this machine; also accept a
# project-root location for portability. First existing candidate wins.
_VENV_PYTHON_CANDIDATES = (
    _BENCHMARK_DIR / ".venv-gemma4" / "bin" / "python",
    _PROJECT_ROOT / ".venv-gemma4" / "bin" / "python",
)


def _default_worker_python() -> Path:
    for cand in _VENV_PYTHON_CANDIDATES:
        if cand.exists():
            return cand
    # None found: return the primary candidate anyway so spawn fails loudly
    # (and clean() falls back), rather than silently picking the wrong python.
    return _VENV_PYTHON_CANDIDATES[0]


@dataclass
class CleanupOutcome:
    """Result of a CleanupClient.clean() call.

    text:            the cleaned text, OR the original input if used_fallback.
    llm_ran:         did the Gemma-4 pass actually run (vs gate-skip)?
    gate_reason:     pipeline gate reason (no-thai / clean-thai / dict-hit / ...)
                     or "fallback" when the guardrail returned the raw text.
    guardrail_flag:  pipeline guardrail flag (ok / skipped / *->dict) or
                     "fallback".
    t_total:         seconds the worker spent in clean_ex (0.0 on fallback).
    used_fallback:   True iff cleanup failed and text is the untouched input.
    error:           human-readable failure reason when used_fallback, else None.
    dict_hits:       deterministic dictionary replacements (0 on fallback).
    t_llm:           seconds in generate() (0.0 if skipped / fallback).
    """

    text: str
    llm_ran: bool
    gate_reason: str
    guardrail_flag: str
    t_total: float
    used_fallback: bool
    error: Optional[str] = None
    dict_hits: int = 0
    t_llm: float = 0.0


class CleanupClient:
    """Spawns + drives the cleanup worker subprocess. Lazy: the worker is only
    spawned on the first `warm_up()` or `clean()`, never at construction."""

    def __init__(
        self,
        python_exe: "str | Path | None" = None,
        worker_script: "str | Path | None" = None,
        cwd: "str | Path | None" = None,
        stderr_path: "str | Path | None" = None,
    ) -> None:
        self.python_exe = Path(python_exe) if python_exe else _default_worker_python()
        self.worker_script = Path(worker_script) if worker_script else _WORKER_SCRIPT
        self.cwd = Path(cwd) if cwd else _BENCHMARK_DIR
        # Worker stderr (mlx/HF chatter + tracebacks) is captured to a file so a
        # spawn/load failure is diagnosable; None -> a temp file is created.
        self._stderr_path = Path(stderr_path) if stderr_path else None

        self._proc: Optional[subprocess.Popen] = None
        self._q: "queue.Queue[Optional[str]]" = queue.Queue()
        self._reader: Optional[threading.Thread] = None
        self._stderr_file = None
        self._lock = threading.RLock()  # serialize requests over the single pipe
        self._req_id = 0

    # -- lifecycle ---------------------------------------------------------- #
    @property
    def alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def _next_id(self) -> int:
        self._req_id += 1
        return self._req_id

    def _ensure_spawned(self) -> bool:
        """Spawn the worker if it isn't running. Returns True if a live worker
        process is available afterwards."""
        if self.alive:
            return True
        # Reap a dead process before respawning.
        if self._proc is not None:
            self._kill()
        return self._spawn()

    def _spawn(self) -> bool:
        if not self.python_exe.exists():
            logger.warning("cleanup worker python not found: %s", self.python_exe)
            return False
        if not self.worker_script.exists():
            logger.warning("cleanup worker script not found: %s", self.worker_script)
            return False
        try:
            if self._stderr_path is None:
                import tempfile

                fd, path = tempfile.mkstemp(prefix="oliv_cleanup_worker_", suffix=".log")
                os.close(fd)
                self._stderr_path = Path(path)
            self._stderr_file = open(self._stderr_path, "w", encoding="utf-8")
            self._proc = subprocess.Popen(
                [str(self.python_exe), str(self.worker_script)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self._stderr_file,
                cwd=str(self.cwd),
                text=True,
                encoding="utf-8",
                bufsize=1,  # line-buffered stdin/stdout in text mode
            )
        except Exception:
            logger.exception("failed to spawn cleanup worker")
            self._proc = None
            return False

        # Fresh queue per process so a respawn can never read a dead worker's
        # leftover lines.
        self._q = queue.Queue()
        proc, q = self._proc, self._q

        def _reader_loop() -> None:
            try:
                for line in proc.stdout:  # blocks; ends when the pipe closes
                    q.put(line)
            except Exception:
                logger.debug("cleanup worker reader thread error", exc_info=True)
            finally:
                q.put(None)  # EOF sentinel

        self._reader = threading.Thread(
            target=_reader_loop, name="oliv-cleanup-reader", daemon=True
        )
        self._reader.start()
        return True

    def _kill(self) -> None:
        """Terminate the worker (bounded), close pipes. Leaves self._proc=None."""
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2.0)
                except Exception:
                    proc.kill()
                    try:
                        proc.wait(timeout=2.0)
                    except Exception:
                        pass
        except Exception:
            logger.debug("error killing cleanup worker", exc_info=True)
        for stream in (proc.stdin, proc.stdout):
            try:
                if stream is not None:
                    stream.close()
            except Exception:
                pass
        try:
            if self._stderr_file is not None:
                self._stderr_file.close()
        except Exception:
            pass
        self._stderr_file = None

    # -- request/reply plumbing -------------------------------------------- #
    def _drain_queue(self) -> None:
        """Discard any buffered lines (stale replies / EOF markers) before a
        new request, so _read_reply sees only this request's output."""
        while True:
            try:
                self._q.get_nowait()
            except queue.Empty:
                return

    def _send(self, obj: dict) -> None:
        assert self._proc is not None and self._proc.stdin is not None
        self._proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self._proc.stdin.flush()

    def _read_reply(self, rid: int, timeout: float) -> "dict | None":
        """Read lines until one parses as JSON with the matching id. Returns the
        reply dict, or None on timeout / EOF / worker death."""
        deadline = time.monotonic() + max(0.0, float(timeout))
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            try:
                line = self._q.get(timeout=remaining)
            except queue.Empty:
                return None
            if line is None:  # EOF sentinel: worker exited
                return None
            line = line.strip()
            if not line:
                continue
            try:
                reply = json.loads(line)
            except Exception:
                logger.debug("cleanup worker emitted non-JSON line: %r", line)
                continue
            if reply.get("id") == rid:
                return reply
            # A stale/foreign line under the lock is unexpected; skip it.
            logger.debug("cleanup worker reply id mismatch (want %s): %r", rid, reply)

    # -- public API --------------------------------------------------------- #
    def _fallback(self, text: str, error: str) -> CleanupOutcome:
        logger.warning("cleanup fell back to raw text: %s", error)
        return CleanupOutcome(
            text=text,
            llm_ran=False,
            gate_reason="fallback",
            guardrail_flag="fallback",
            t_total=0.0,
            used_fallback=True,
            error=error,
        )

    def clean(self, text: str, timeout: float = 8.0) -> CleanupOutcome:
        """Clean `text` via the worker. On ANY failure returns `text` unchanged
        with used_fallback=True (never loses/corrupts the transcript)."""
        with self._lock:
            try:
                if not self._ensure_spawned():
                    return self._fallback(text, "cleanup worker could not be spawned")
                rid = self._next_id()
                self._drain_queue()
                self._send({"id": rid, "cmd": "clean", "text": text})
                reply = self._read_reply(rid, timeout)
            except (BrokenPipeError, OSError) as exc:
                self._kill()
                return self._fallback(text, f"worker pipe error: {exc}")
            except Exception as exc:  # last-resort guardrail
                self._kill()
                return self._fallback(text, f"{type(exc).__name__}: {exc}")

            if reply is None:
                # Timeout or EOF: worker is in an unknown state -> respawn later.
                self._kill()
                return self._fallback(text, f"cleanup timed out / worker died (>{timeout:g}s)")
            if not reply.get("ok"):
                return self._fallback(text, str(reply.get("error", "worker returned ok:false")))

            return CleanupOutcome(
                text=reply.get("text", text),
                llm_ran=bool(reply.get("llm_ran", False)),
                gate_reason=str(reply.get("gate_reason", "")),
                guardrail_flag=str(reply.get("guardrail_flag", "")),
                t_total=float(reply.get("t_total", 0.0)),
                used_fallback=False,
                error=None,
                dict_hits=int(reply.get("dict_hits", 0)),
                t_llm=float(reply.get("t_llm", 0.0)),
            )

    def warm_up(self, timeout: float = 60.0) -> Optional[float]:
        """Load the Gemma-4 model in the worker (+ one priming generation).
        Returns the worker-reported load_time in seconds, or None on failure
        (non-fatal: cleanup just runs cold / falls back later)."""
        with self._lock:
            try:
                if not self._ensure_spawned():
                    logger.warning("cleanup warm_up: worker could not be spawned")
                    return None
                rid = self._next_id()
                self._drain_queue()
                self._send({"id": rid, "cmd": "warm"})
                reply = self._read_reply(rid, timeout)
            except Exception:
                logger.exception("cleanup warm_up failed")
                self._kill()
                return None
            if reply is None:
                logger.warning("cleanup warm_up timed out (>%gs)", timeout)
                self._kill()
                return None
            if not reply.get("ok"):
                logger.warning("cleanup warm_up error: %s", reply.get("error"))
                return None
            return reply.get("load_time")

    def close(self) -> None:
        """Shut the worker down cleanly (shutdown request, bounded wait, then
        kill). Idempotent; leaves no zombie subprocess."""
        with self._lock:
            proc = self._proc
            if proc is None:
                return
            try:
                if proc.poll() is None and proc.stdin is not None:
                    proc.stdin.write(json.dumps({"cmd": "shutdown"}) + "\n")
                    proc.stdin.flush()
            except Exception:
                pass
            try:
                proc.wait(timeout=5.0)
                # Graceful exit: still close pipes / stderr file, clear handle.
                for stream in (proc.stdin, proc.stdout):
                    try:
                        if stream is not None:
                            stream.close()
                    except Exception:
                        pass
                try:
                    if self._stderr_file is not None:
                        self._stderr_file.close()
                except Exception:
                    pass
                self._stderr_file = None
                self._proc = None
            except Exception:
                self._kill()

    # Context manager sugar.
    def __enter__(self) -> "CleanupClient":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


__all__ = ["CleanupClient", "CleanupOutcome"]
