"""Benchmark alternative STT models against Pathumma on the SAME pipeline.

Runs a candidate STT model (HF-transformers Whisper fine-tune or an MLX Whisper
repo) through the REAL sidecar path (STT -> re-decode-if-supported -> cleanup with
per-bucket vocab/format), over the main set and/or holdout, and writes a results
JSON that semantic_score.py picks up. So each candidate is scored identically to
OLIV's champion — the only variable is the acoustic model.

  sidecar/.venv/bin/python benchmark/eval_models.py \
      --name typhoon_turbo --kind hf --repo typhoon-ai/typhoon-whisper-turbo \
      --manifest data/manifest_all.jsonl --out eval_results/typhoon_turbo.json
"""
from __future__ import annotations
import argparse, os, time
os.environ["OLIV_SIDECAR_IMPORT_ONLY"] = "1"
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "sidecar")); sys.path.insert(0, str(ROOT / "benchmark"))
import eval_cleanup as ec           # noqa: E402  (helpers: load_manifest, build_request, _norm_lines, bucket_of)
import metrics, pipeline            # noqa: E402
import sidecar_server as ss         # noqa: E402


def make_backend(kind: str, repo: str):
    if kind == "hf":
        from app.stt.pathumma import PathummaBackend
        return PathummaBackend(repo)
    from app.stt.mlx_whisper import MLXWhisperBackend
    return MLXWhisperBackend(repo)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--kind", choices=["hf", "mlx"], required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--manifest", default="data/manifest_all.jsonl")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    from app.stt.mlx_whisper import MLXWhisperBackend
    backend = make_backend(args.kind, args.repo)
    print(f"warming {args.name} ({args.kind}:{args.repo}) ...")
    backend.warm_up()

    man = Path(args.manifest)
    if not man.is_absolute():
        man = ROOT / "benchmark" / man
    rows = ec.load_manifest(man, ROOT / "benchmark" / "data")

    results = []
    for r in rows:
        if not Path(r["_abspath"]).exists():
            continue
        b = ec.bucket_of(r["id"])
        req = ec.build_request(r, engine="x", use_vocab=True, cleanup=True)
        ip = ss._build_initial_prompt(req)
        audio = MLXWhisperBackend._load_wav_as_array(r["_abspath"])  # soundfile, no librosa
        t0 = time.perf_counter()
        raw = backend.transcribe(audio, language=None, initial_prompt=ip)
        # same cleanup path _handle uses (format-command split for fm, vocab for vb)
        if b == "fm":
            segs, seps = ss._split_format_commands(raw)
        else:
            segs, seps = [raw], []
        info = ss._clean_and_replace_segments(segs, seps, cleanup_on=True,
                                              replacements=None, vocab=req.get("vocabulary"),
                                              pipeline=pipeline)
        dt = time.perf_counter() - t0
        final = info["final"]; ref = r["reference"]
        sc = metrics.score(ref, final, r.get("keywords") or None)
        results.append({
            "id": r["id"], "bucket": b, "reference": ref, "raw": raw, "final": final,
            "exact": ec._norm_lines(final) == ec._norm_lines(ref),
            "wer": round(sc.wer_newmm, 4), "llm_ran": info["llm_ran"],
            "guardrail": info["guardrail_flag"], "latency_s": round(dt, 3),
        })
        print(f"  {r['id']} wer={results[-1]['wer']:.2f} {dt:4.1f}s  {final[:48]!r}")

    n = len(results)
    overall = {"n": n, "mean_wer": round(sum(x["wer"] for x in results) / n, 4),
               "mean_latency_s": round(sum(x["latency_s"] for x in results) / n, 3),
               "exact_pct": round(100 * sum(x["exact"] for x in results) / n, 1)}
    out = Path(args.out)
    if not out.is_absolute():
        out = ROOT / "benchmark" / out
    import json
    out.write_text(json.dumps({"label": args.name, "engine": args.name, "repo": args.repo,
                               "cleanup_model": pipeline.MODEL, "overall": overall,
                               "aggregate": {}, "clips": results, "missing": []},
                              ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n{args.name}: n={n} WER {overall['mean_wer']} lat {overall['mean_latency_s']}s -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
