"""Sidecar protocol test (W3-T3) -- spawns the real server and drives it the
way the Swift SidecarClient will: line-JSON over pipes, models included.

NOT hermetic (loads pathumma-mlx + Gemma-4; ~30s warm on this machine): this
is the sidecar's equivalent of `--e2e-file` -- the proof that the protocol,
the unified env, and the never-lose-the-transcript contract hold end-to-end.
Run from anywhere:

    sidecar/.venv/bin/python sidecar/test_sidecar.py

Checks:
  [1] ping round-trips before any model load (fast liveness)
  [2] warm loads STT + cleanup and reports both times
  [3] dictate(th01, pure Thai)  -> gate skips LLM, final == manifest reference,
      and the new W4-T1 count fields default to 0 (backward-compatible)
  [4] dictate(mx03, code-switch, via pcm_b64 like the real client) ->
      cleanup restores fine-tune/accuracy/evaluate
  [4a] W4-T1 Feature A server-level: dictate(th01) with a `replacements` table ->
      the snippet fires in `final`, `raw` stays the TRUE raw (protocol proof;
      the pure/adversarial cases live in test_text_passes.py)
  [4b] W4-T1 Feature B server-level: dictate(th01) with remove_fillers=True on a
      filler-free clip -> no-op-safe (fillers_removed==0, final == reference)
  [5] bad request JSON  -> ok:false reply, server keeps serving
  [6] unknown cmd       -> ok:false reply, server keeps serving
  [7] stdout stayed pure protocol JSON throughout (the fd-discipline check)
  [8] shutdown -> exit 0
  [9] download of ALREADY-CACHED repos replies ok fast (offline, no network) --
      the W3-T4 onboarding/Settings model-fetch driver
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = ROOT / "sidecar" / ".venv" / "bin" / "python"
SERVER = ROOT / "sidecar" / "sidecar_server.py"
CLIPS = ROOT / "benchmark" / "data" / "clips"

PASSED, FAILED = [], []


def check(name: str, cond: bool, detail: str = "") -> None:
    (PASSED if cond else FAILED).append(name)
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {name}" + (f"  -- {detail}" if detail else ""))


def manifest_ref(clip_id: str) -> str:
    for line in (ROOT / "benchmark" / "data" / "manifest.jsonl").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        o = json.loads(line)
        if o["id"] == clip_id:
            return o["reference"]
    raise KeyError(clip_id)


def wav_as_pcm_b64(path: Path) -> str:
    """Decode a clip to 16 kHz mono float32 -- the exact payload shape the
    Swift AudioCapture hands the client."""
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly

    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    mono = data.mean(axis=1)
    if sr != 16000:
        from math import gcd

        g = gcd(sr, 16000)
        mono = resample_poly(mono, 16000 // g, sr // g).astype("float32")
    return base64.b64encode(mono.tobytes()).decode("ascii")


# Repos the app requires on first run (STT primary + cleanup). Cached on any
# machine that has run the sidecar once -- see the download check below.
REQUIRED_REPOS = [
    "kinoppy555/Pathumma-whisper-th-large-v3-mlx",
    "mlx-community/gemma-4-e4b-it-4bit",
]


def run_download_check() -> None:
    """[9] download of an ALREADY-CACHED repo replies ok fast, with NO network.

    Spawns a DEDICATED offline (HF_HUB_OFFLINE=1) server so the check is
    hermetic re: the network and can't disturb the main session's warm/dictate.
    Drains any interim {"event": "progress"} lines (same id) before the final
    reply, exactly as the Swift SidecarClient does.

    Uses the STT repo alone: it is fully materialized by the warm above, whereas
    HF_HUB_OFFLINE is strict about snapshot completeness (a model whose weights
    are cached but whose README/.gitattributes were never fetched trips
    IncompleteSnapshotError offline -- a cache-shape artifact, not a real
    failure: the app only needs the weights). One cached repo is all this check
    needs -- it proves the download command, the progress drain, and the ok
    reply end-to-end without hitting the network."""
    import os

    repo = REQUIRED_REPOS[0]
    env = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    proc = subprocess.Popen(
        [str(PY), str(SERVER)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, encoding="utf-8", env=env,
    )
    try:
        t0 = time.perf_counter()
        proc.stdin.write(json.dumps({"id": 9, "cmd": "download", "repos": [repo]}) + "\n")
        proc.stdin.flush()
        reply = None
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            o = json.loads(line)
            if o.get("event") == "progress":
                continue  # interim, keep draining
            reply = o
            break
        dt = time.perf_counter() - t0
        ok = (reply is not None and reply.get("ok") is True
              and repo in reply.get("downloaded", []))
        check("download cached repo ok (offline, no network)", ok,
              f"{dt * 1000:.0f}ms downloaded={reply.get('downloaded') if reply else None}")
        proc.stdin.write(json.dumps({"cmd": "shutdown"}) + "\n")
        proc.stdin.flush()
        proc.wait(timeout=10)
    finally:
        if proc.poll() is None:
            proc.kill()


def main() -> int:
    proc = subprocess.Popen(
        [str(PY), str(SERVER)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, encoding="utf-8",
    )
    raw_lines: list[str] = []

    def rpc(obj: dict, timeout_hint: str = "") -> dict:
        proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        raw_lines.append(line)
        return json.loads(line)

    try:
        # [1] ping before any load
        t0 = time.perf_counter()
        r = rpc({"id": 1, "cmd": "ping"})
        check("ping pre-warm", r.get("ok") is True and "pid" in r,
              f"{(time.perf_counter()-t0)*1000:.0f}ms")

        # [2] warm both stages
        t0 = time.perf_counter()
        r = rpc({"id": 2, "cmd": "warm", "engine": "pathumma-mlx", "cleanup": True})
        check("warm ok", r.get("ok") is True and r.get("t_stt_load", -1) >= 0
              and r.get("t_cleanup_load", -1) >= 0,
              f"stt {r.get('t_stt_load', 0):.1f}s cleanup {r.get('t_cleanup_load', 0):.1f}s "
              f"wall {time.perf_counter()-t0:.1f}s")

        # [3] pure-Thai clip via wav_path: gate must skip the LLM, final == ref
        r = rpc({"id": 3, "cmd": "dictate", "wav_path": str(CLIPS / "th01.wav"),
                 "engine": "pathumma-mlx", "cleanup": True})
        ref = manifest_ref("th01")
        check("th01 final == reference", r.get("ok") is True and r.get("final") == ref,
              f"t_stt {r.get('t_stt', 0):.2f}s")
        check("th01 gate skipped LLM", r.get("llm_ran") is False
              and r.get("t_cleanup", 1) < 0.2, f"gate={r.get('gate_reason')!r}")
        # Backward-compat: a plain dictate reports every optional-pass count as 0.
        check("th01 optional-pass counts default 0",
              r.get("fillers_removed") == 0 and r.get("replacements_fired") == 0
              and r.get("format_commands_fired") == 0,
              f"fillers={r.get('fillers_removed')} repl={r.get('replacements_fired')} "
              f"fmt={r.get('format_commands_fired')}")

        # [4] code-switch clip via pcm_b64 (the real client payload shape)
        r = rpc({"id": 4, "cmd": "dictate", "pcm_b64": wav_as_pcm_b64(CLIPS / "mx03.wav"),
                 "engine": "pathumma-mlx", "cleanup": True})
        final = r.get("final", "")
        check("mx03 cleanup restored code-switch",
              r.get("ok") is True and r.get("llm_ran") is True
              and all(w in final for w in ("fine-tune", "accuracy", "evaluate")),
              f"t_stt {r.get('t_stt', 0):.2f}s t_cleanup {r.get('t_cleanup', 0):.2f}s")
        check("mx03 raw preserved alongside final",
              "ไฟล์จูน" in r.get("raw", ""), r.get("raw", "")[:40])

        # [4a] W4-T1 Feature A -- user replacements through the real protocol.
        # Map a real word in th01's transcript to a snippet; it must fire in
        # `final` (post-cleanup pass) while `raw` stays the true Thai raw. Reuses
        # the already-warmed STT model (cheap path). The adversarial mid-word
        # refusal / longest-first cases are covered hermetically in
        # test_text_passes.py -- here we only prove the wire.
        r = rpc({"id": 41, "cmd": "dictate", "wav_path": str(CLIPS / "th01.wav"),
                 "engine": "pathumma-mlx", "cleanup": True,
                 "replacements": {"การประชุม": "the meeting"}})
        final = r.get("final", "")
        check("th01 replacement fired in final",
              r.get("ok") is True and r.get("replacements_fired", 0) >= 1
              and "the meeting" in final and "การประชุม" not in final,
              f"fired={r.get('replacements_fired')} final={final[:40]!r}")
        check("th01 raw untouched by replacements",
              "การประชุม" in r.get("raw", "") and "the meeting" not in r.get("raw", ""),
              r.get("raw", "")[:40])

        # [4b] W4-T1 Feature B -- filler removal through the real protocol. th01
        # has no fillers, so remove_fillers must be a no-op: count 0 and `final`
        # byte-identical to the reference (proving the pre-cleanup pass never
        # perturbs a filler-free transcript). Functional filler cases are
        # hermetic in test_text_passes.py.
        r = rpc({"id": 42, "cmd": "dictate", "wav_path": str(CLIPS / "th01.wav"),
                 "engine": "pathumma-mlx", "cleanup": True, "remove_fillers": True})
        check("th01 remove_fillers no-op on filler-free clip",
              r.get("ok") is True and r.get("fillers_removed") == 0
              and r.get("final") == ref,
              f"fillers={r.get('fillers_removed')} final==ref={r.get('final') == ref}")

        # [4c] B4 -- format_commands on a command-free clip inserts NO breaks.
        # th01 has no spoken formatting command, so the user-visible contract is:
        # 0 fired and no newline in `final` (no spurious line breaks). NOTE: we no
        # longer assert byte-equality to the reference here -- with the feature on
        # the STT prompt is SEEDED with the command phrases (so real commands are
        # heard reliably), which can perturb the decode of unrelated words; the
        # contract that matters is "no phantom formatting". Split/clean/join
        # correctness is covered hermetically in test_text_passes.py.
        r = rpc({"id": 43, "cmd": "dictate", "wav_path": str(CLIPS / "th01.wav"),
                 "engine": "pathumma-mlx", "cleanup": True, "format_commands": True})
        final = r.get("final", "")
        check("th01 format_commands inserts no breaks on a command-free clip",
              r.get("ok") is True and r.get("format_commands_fired") == 0
              and "\n" not in final and bool(final.strip()),
              f"fired={r.get('format_commands_fired')} has_nl={chr(10) in final} final={final[:30]!r}")

        # [4d] B3 -- custom vocabulary accepted through the real protocol (an
        # initial_prompt is built from the term list and passed to the MLX
        # backend). We prove the WIRE + no-crash here: a Thai clip with English
        # tech terms in the vocabulary must still decode ok and keep its true
        # raw. (Whether a prompt *changes* a decode is model behaviour, not a
        # protocol contract, so we don't pin exact text.)
        r = rpc({"id": 44, "cmd": "dictate", "wav_path": str(CLIPS / "th01.wav"),
                 "engine": "pathumma-mlx", "cleanup": True,
                 "vocabulary": ["Grafana", "Kubernetes", "OLIV"]})
        check("th01 vocabulary accepted (initial_prompt wired)",
              r.get("ok") is True and bool(r.get("raw", "").strip())
              and r.get("format_commands_fired") == 0,
              f"raw={r.get('raw','')[:30]!r}")

        # [5] bad JSON never kills the loop
        proc.stdin.write("this is not json\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        raw_lines.append(line)
        r = json.loads(line)
        check("bad JSON -> ok:false, server alive", r.get("ok") is False)

        # [6] unknown cmd
        r = rpc({"id": 6, "cmd": "explode"})
        check("unknown cmd -> ok:false, server alive",
              r.get("ok") is False and "unknown" in r.get("error", ""))

        # liveness after both error paths
        r = rpc({"id": 7, "cmd": "ping"})
        check("ping post-errors", r.get("ok") is True)

        # [7] stdout purity: every line we read parsed as JSON already, but
        # assert none was empty/partial garbage
        check("stdout pure protocol JSON", all(l.strip().startswith("{") for l in raw_lines))

        # [8] clean shutdown
        proc.stdin.write(json.dumps({"cmd": "shutdown"}) + "\n")
        proc.stdin.flush()
        rc = proc.wait(timeout=10)
        check("shutdown exit 0", rc == 0, f"rc={rc}")
    finally:
        if proc.poll() is None:
            proc.kill()

    # [9] runs in its own offline subprocess (independent of the session above).
    run_download_check()

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed of {len(PASSED) + len(FAILED)}")
    print("ALL PASS" if not FAILED else f"FAILED: {FAILED}")
    return 0 if not FAILED else 1


if __name__ == "__main__":
    raise SystemExit(main())
