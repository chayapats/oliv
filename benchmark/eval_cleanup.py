"""Score the full STT → features → cleanup path against a local manifest.

The default drives the shipped Rust + native MLX workers. --runtime reference
runs the previous Python implementation for comparisons. Python is only used
by this developer harness; it is absent from the app and its build process.
Both runtimes receive identical Float32 mono/16 kHz PCM from ffmpeg.

    python benchmark/eval_cleanup.py --manifest data/manifest_all.jsonl
    python benchmark/eval_cleanup.py --runtime reference --manifest data/manifest_all.jsonl

Per-bucket flags mirror normal use: fl enables filler removal, fm formatting
commands, vb vocabulary. Reports include per-clip outputs and should stay in
ignored benchmark/eval_results/ when using private recordings.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from contextlib import ExitStack
from collections import defaultdict
from pathlib import Path

# Import the sidecar's real handler WITHOUT its stdout fd-hijack (import-only).
os.environ["OLIV_SIDECAR_IMPORT_ONLY"] = "1"

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "sidecar"))
sys.path.insert(0, str(ROOT / "benchmark"))

import metrics  # noqa: E402
from native_runtime import NativeRuntime, DEFAULT_ENGINE, CLEANUP_MODEL, capture_request  # noqa: E402


def bucket_of(cid: str) -> str:
    m = re.match(r"[a-z]+", cid)
    return m.group() if m else cid


def load_manifest(path: Path, audio_root: Path) -> list[dict]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        r = json.loads(line)
        r["_abspath"] = str((audio_root / r["path"]).resolve())
        rows.append(r)
    return rows


def _norm_lines(s: str) -> str:
    """Normalise for exact-match: trim each line, drop blank edges, lower — but
    KEEP newlines (fm clips are judged on their line breaks)."""
    lines = [ln.strip() for ln in s.replace("​", "").split("\n")]
    return "\n".join(lines).strip().lower()


def build_request(row: dict, *, engine: str, use_vocab: bool, cleanup: bool) -> dict:
    """Build a dictate request. `cleanup=False` is the PURE STT baseline: no
    cleanup AND no Wave-4/6 features, so `final == raw` (the honest raw-vs-ref
    comparison). With cleanup on, the per-bucket feature flags mirror a real user
    (fl→filler removal, fm→formatting commands, vb→vocabulary biasing)."""
    req = {"cmd": "dictate", "wav_path": row["_abspath"], "engine": engine,
           "cleanup": cleanup}
    if not cleanup:
        return req
    b = bucket_of(row["id"])
    if b == "fl":
        req["remove_fillers"] = True
    elif b == "fm":
        req["format_commands"] = True
    elif b == "vb" and use_vocab and row.get("vocab"):
        req["vocabulary"] = row["vocab"]
    return req


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="data/manifest_v2.jsonl")
    ap.add_argument("--audio-root", default="data")
    ap.add_argument("--runtime", choices=["native", "reference"], default="native")
    ap.add_argument("--runtime-dir", default="", help="override native worker directory")
    ap.add_argument("--engine", default=DEFAULT_ENGINE,
                    help="STT engine id (pathumma-mlx | mlx-large-v3 | groq-large-v3)")
    ap.add_argument("--no-cleanup", action="store_true",
                    help="PURE STT baseline: cleanup + features off, final == raw")
    ap.add_argument("--buckets", default="", help="comma list to restrict (default: all present)")
    ap.add_argument("--no-vocab", action="store_true", help="vb: run WITHOUT the vocab term (B3 baseline)")
    ap.add_argument("--limit", type=int, default=0, help="cap clips per bucket (0=all)")
    ap.add_argument("--label", default="", help="human label for this config (report legend)")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    cleanup_on = not args.no_cleanup
    with ExitStack() as stack:
        if args.runtime == "native":
            runtime = stack.enter_context(NativeRuntime(Path(args.runtime_dir).resolve() if args.runtime_dir else None))
            invoke = runtime.request
            cleanup_model = CLEANUP_MODEL
        else:
            import pipeline
            import sidecar_server as ss
            invoke = lambda body: ss._handle(capture_request(body))
            cleanup_model = pipeline.MODEL
        invoke({"cmd": "warm", "engine": args.engine, "cleanup": cleanup_on})
        return evaluate(args, invoke, cleanup_model)


def evaluate(args, invoke, cleanup_model) -> int:
    cleanup_on = not args.no_cleanup

    manifest = Path(args.manifest)
    if not manifest.is_absolute():
        manifest = ROOT / "benchmark" / manifest
    audio_root = Path(args.audio_root)
    if not audio_root.is_absolute():
        audio_root = ROOT / "benchmark" / audio_root

    rows = load_manifest(manifest, audio_root)
    want = {b for b in args.buckets.split(",") if b} or None
    label = args.label or f"{args.engine}{'' if cleanup_on else ' (pure)'}"

    print(f"label         : {label}")
    print(f"runtime       : {args.runtime}")
    print(f"STT engine    : {args.engine}")
    print(f"cleanup       : {'OFF (pure STT)' if not cleanup_on else cleanup_model}")
    print(f"manifest      : {manifest}  ({len(rows)} clips)")
    print(f"vb vocabulary : {'OFF (B3 baseline)' if args.no_vocab else 'ON'}\n")

    per_bucket_seen: dict[str, int] = defaultdict(int)
    results: list[dict] = []
    missing: list[str] = []

    for r in rows:
        b = bucket_of(r["id"])
        if want and b not in want:
            continue
        if args.limit and per_bucket_seen[b] >= args.limit:
            continue
        if not Path(r["_abspath"]).exists():
            missing.append(r["id"])
            continue
        per_bucket_seen[b] += 1

        t0 = time.perf_counter()
        rep = invoke(build_request(r, engine=args.engine,
                                       use_vocab=not args.no_vocab, cleanup=cleanup_on))
        dt = time.perf_counter() - t0
        if not rep.get("ok"):
            raise RuntimeError(f"Dictation failed for clip {r['id']}")

        final = rep.get("final", "")
        ref = r["reference"]
        exact = _norm_lines(final) == _norm_lines(ref)
        sc = metrics.score(ref, final, r.get("keywords") or None)
        row = {
            "id": r["id"], "bucket": b, "difficulty": r.get("difficulty"),
            "reference": ref, "raw": rep.get("raw", ""), "final": final,
            "exact": exact, "wer": round(sc.wer_newmm, 4),
            "cer": round(sc.cer, 4),
            "kw_recall": None if sc.keyword_recall is None else round(sc.keyword_recall, 3),
            "llm_ran": rep.get("llm_ran"), "guardrail": rep.get("guardrail_flag"),
            "fillers_removed": rep.get("fillers_removed"),
            "format_commands_fired": rep.get("format_commands_fired"),
            "replacements_fired": rep.get("replacements_fired"),
            "latency_s": round(dt, 3),
            "t_stt": rep.get("t_stt"), "t_cleanup": rep.get("t_cleanup"),
            "cleanup_error": rep.get("cleanup_error"),
        }
        results.append(row)
        mark = "OK " if exact else "…  "
        print(f"  [{mark}] {r['id']} wer={row['wer']:.3f} {dt:4.1f}s  {final[:52]!r}")

    # Aggregate.
    print("\n=== per-bucket ===")
    by = defaultdict(list)
    for row in results:
        by[row["bucket"]].append(row)
    print(f"{'bucket':8} {'n':>3} {'exact%':>7} {'meanWER':>8} {'meanLat':>8}")
    agg = {}
    for b in sorted(by):
        rs = by[b]
        ex = 100.0 * sum(x["exact"] for x in rs) / len(rs)
        wer = sum(x["wer"] for x in rs) / len(rs)
        lat = sum(x["latency_s"] for x in rs) / len(rs)
        agg[b] = {"n": len(rs), "exact_pct": round(ex, 1), "mean_wer": round(wer, 4),
                  "mean_latency_s": round(lat, 3)}
        print(f"{b:8} {len(rs):>3} {ex:>6.1f}% {wer:>8.3f} {lat:>7.2f}s")
    if results:
        ex = 100.0 * sum(x["exact"] for x in results) / len(results)
        wer = sum(x["wer"] for x in results) / len(results)
        lat = sum(x["latency_s"] for x in results) / len(results)
        print(f"{'ALL':8} {len(results):>3} {ex:>6.1f}% {wer:>8.3f} {lat:>7.2f}s")
    if missing:
        print(f"\nMISSING (not recorded yet, skipped): {len(missing)} — "
              + ", ".join(missing[:12]) + (" …" if len(missing) > 12 else ""))

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        overall = None
        if results:
            overall = {
                "n": len(results),
                "exact_pct": round(100.0 * sum(x["exact"] for x in results) / len(results), 1),
                "mean_wer": round(sum(x["wer"] for x in results) / len(results), 4),
                "mean_latency_s": round(sum(x["latency_s"] for x in results) / len(results), 3),
            }
        out.write_text(json.dumps(
            {"label": label, "engine": args.engine,
             "cleanup_model": None if not cleanup_on else cleanup_model,
             "runtime": args.runtime,
             "manifest": str(manifest), "no_vocab": args.no_vocab,
             "overall": overall, "aggregate": agg, "clips": results, "missing": missing},
            ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
