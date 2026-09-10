"""Hermetic check for the opt-in Groq cloud STT backend (W3-T4).

The whole point of this tier is that it is STRICTLY OPT-IN: a privacy-first,
local-only setup must never accidentally route audio to the cloud. So the load-
bearing invariant is availability gating -- build_backend("groq-large-v3") must
raise Unavailable when GROQ_API_KEY is absent, and only flip available once a
key is present.

Plain asserts, no pytest (matches benchmark/test_dictionary.py). Run:
    sidecar/.venv/bin/python sidecar/test_groq_backend.py

NEVER touches the network: available() and construction only check the SDK +
env var; the "with a key" leg uses a DUMMY key and does NOT call transcribe().
"""

from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from app.stt import BACKENDS, Unavailable, build_backend  # noqa: E402
from app.stt.groq_cloud import GroqCloudBackend  # noqa: E402

PASSED: list[str] = []
FAILED: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    (PASSED if cond else FAILED).append(name)
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {name}" + (f"  -- {detail}" if detail else ""))


def main() -> int:
    # Registered under the expected id, mapped to the right class.
    check("registered as 'groq-large-v3'",
          BACKENDS.get("groq-large-v3") is GroqCloudBackend)

    # ------ no key: must be Unavailable (the privacy-critical gate) ------
    os.environ.pop("GROQ_API_KEY", None)
    ok, hint = GroqCloudBackend().available()
    check("available() False without GROQ_API_KEY",
          ok is False and "GROQ_API_KEY" in hint, hint)
    try:
        build_backend("groq-large-v3")
        check("build_backend raises Unavailable without key", False,
              "did NOT raise")
    except Unavailable as exc:
        check("build_backend raises Unavailable without key",
              "GROQ_API_KEY" in str(exc), str(exc))

    # ------ dummy key: flips available (construction only, NO network) ------
    os.environ["GROQ_API_KEY"] = "dummy-key-not-real-do-not-transcribe"
    try:
        ok, hint = GroqCloudBackend().available()
        check("available() True with a key set", ok is True, hint)
        backend = build_backend("groq-large-v3")
        check("build_backend constructs with a key",
              backend.id == "groq-large-v3" and backend.model == "whisper-large-v3")
    finally:
        os.environ.pop("GROQ_API_KEY", None)

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed of "
          f"{len(PASSED) + len(FAILED)}")
    print("ALL PASS" if not FAILED else f"FAILED: {FAILED}")
    return 0 if not FAILED else 1


if __name__ == "__main__":
    raise SystemExit(main())
