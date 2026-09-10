"""Cleanup subprocess worker (W1-T6) -- runs under benchmark/.venv-gemma4.

The Gemma-4 cleanup pipeline (benchmark/pipeline.py) can ONLY run in the
`.venv-gemma4` environment (mlx-lm 0.31.3 + transformers==5.0.0); importing it
inside the app's `.venv-app` (transformers 5.13) breaks. So the app talks to
this worker over stdio: the app (`app/cleanup.py`'s CleanupClient) spawns

    benchmark/.venv-gemma4/bin/python benchmark/cleanup_worker.py

and exchanges one JSON object per line.

Protocol (line-oriented JSON, one request per line in, one reply per line out)
-----------------------------------------------------------------------------
  request  {"id": N, "cmd": "warm"}
  reply    {"id": N, "ok": true, "load_time": <seconds>}
      Force the Gemma-4 model load (pipeline._ensure_model) + one priming
      generation so the first real clean is warm. load_time is the wall time
      of that warm-up (model load + prime).

  request  {"id": N, "cmd": "clean", "text": "..."}
  reply    {"id": N, "ok": true, "text": "...", "llm_ran": bool,
            "gate_reason": "...", "guardrail_flag": "...", "dict_hits": int,
            "t_total": float, "t_llm": float}
      Run pipeline.clean_ex(text) and return its result.

  request  {"cmd": "shutdown"}      -> exit 0 cleanly.
  EOF on stdin                      -> exit 0 cleanly.

  any exception on a request        -> reply {"id": N, "ok": false,
                                              "error": "..."} and keep serving
                                       (one bad request never crashes the loop).

stdout discipline (CRITICAL)
----------------------------
The client parses stdout line-by-line as JSON, so NOTHING but protocol JSON may
reach stdout. mlx / transformers / huggingface print progress + warnings, and
some libraries write straight to fd 1. To be bulletproof we, before importing
pipeline, dup the real stdout to a private fd (the protocol channel) and then
point fd 1 at fd 2 (stderr) -- so every stray stdout write (Python-level OR
C-level) lands on stderr, while protocol JSON goes out the private fd. The
client reads only that clean channel.

Robustness: `import pipeline` needs benchmark/ on sys.path (pipeline imports
dictionary/prompts/metrics as top-level modules). We insert this file's own
directory (benchmark/) at sys.path[0], so the worker imports correctly even if
launched with cwd=<project root> instead of cwd=benchmark.
"""

from __future__ import annotations

import json
import os
import sys
import time

# --------------------------------------------------------------------------- #
# 1. Make `import pipeline` work regardless of cwd: benchmark/ (this file's
#    directory) must be importable.
# --------------------------------------------------------------------------- #
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# --------------------------------------------------------------------------- #
# 2. Split the protocol channel off fd 1 BEFORE importing anything heavy.
#    _PROTO is the *real* original stdout (a pipe back to the client); fd 1 is
#    then redirected to stderr so any library that prints to stdout can't
#    corrupt the protocol stream.
# --------------------------------------------------------------------------- #
_proto_fd = os.dup(1)          # private copy of the original stdout (pipe to client)
os.dup2(2, 1)                  # fd 1 now mirrors fd 2 (stderr): stray stdout -> stderr
sys.stdout = sys.stderr        # python-level prints also go to stderr
_PROTO = os.fdopen(_proto_fd, "w", encoding="utf-8", buffering=1)


def _reply(obj: dict) -> None:
    """Write one protocol JSON object + newline to the clean channel, flushed."""
    _PROTO.write(json.dumps(obj, ensure_ascii=False))
    _PROTO.write("\n")
    _PROTO.flush()


# Priming utterance for warm-up: a dict-hit Thai string that forces the LLM
# path, so the (slower) first generation happens during warm, not the first
# real clean.
_PRIME_TEXT = "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา"


def _handle(req: dict, pipeline) -> "dict | None":
    """Process one request dict. Returns a reply dict, or None to signal a
    clean shutdown."""
    cmd = req.get("cmd")
    rid = req.get("id")

    if cmd == "shutdown":
        return None

    if cmd == "warm":
        t0 = time.time()
        pipeline._ensure_model()  # loads Gemma-4 once; sets pipeline.LOAD_TIME
        try:
            pipeline.clean_ex(_PRIME_TEXT)  # prime the generate graph
        except Exception:
            pass  # priming is best-effort; the model is loaded either way
        return {"id": rid, "ok": True, "load_time": time.time() - t0}

    if cmd == "clean":
        text = req.get("text", "")
        r = pipeline.clean_ex(text)
        return {
            "id": rid,
            "ok": True,
            "text": r.text,
            "llm_ran": r.llm_ran,
            "gate_reason": r.gate_reason,
            "guardrail_flag": r.guardrail_flag,
            "dict_hits": r.dict_hits,
            "t_total": r.t_total,
            "t_llm": r.t_llm,
        }

    return {"id": rid, "ok": False, "error": f"unknown cmd {cmd!r}"}


def main() -> int:
    # Import pipeline AFTER the fd redirect so its import-time chatter (and the
    # heavy transformers/mlx imports) can't touch the protocol channel.
    try:
        import pipeline  # noqa: E402  (deliberately after fd setup + sys.path)
    except Exception as exc:  # pragma: no cover - env misconfig
        # Can't serve at all; tell the client once, then exit non-zero.
        _reply({"id": None, "ok": False, "error": f"failed to import pipeline: {exc!r}"})
        return 1

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
        except Exception as exc:
            _reply({"id": None, "ok": False, "error": f"bad request JSON: {exc}"})
            continue
        try:
            reply = _handle(req, pipeline)
        except Exception as exc:
            # One bad request must never crash the worker: report + keep serving.
            _reply({"id": rid, "ok": False, "error": f"{type(exc).__name__}: {exc}"})
            continue
        if reply is None:  # shutdown
            break
        _reply(reply)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
