#!/usr/bin/env bash
# Full OLIV eval sweep (W6-EVAL). Runs every LOCAL config over the merged
# ~194-clip set and drops one JSON per config under benchmark/eval_results/,
# which benchmark/build_report_data.py aggregates into report_data.json.
#
# Each config runs as its OWN python process so the cleanup model (E4B vs E2B,
# via OLIV_CLEANUP_MODEL) and the STT engine are cleanly isolated — no model
# stays half-loaded between configs. A config that fails (e.g. a model download
# error) is logged and skipped; the sweep continues.
#
# Groq is intentionally NOT here: it needs GROQ_API_KEY (cloud, opt-in). Run it
# separately once the key is set — see the commented block at the end.
#
#   bash benchmark/run_eval_full.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/sidecar/.venv/bin/python"
RUN="$ROOT/benchmark/eval_cleanup.py"
MF="data/manifest_all.jsonl"
OUT="$ROOT/benchmark/eval_results"
E4B="mlx-community/gemma-4-e4b-it-4bit"
E2B="mlx-community/gemma-4-e2b-it-4bit"
mkdir -p "$OUT"
export HF_HUB_DISABLE_XET=1
cd "$ROOT/benchmark"

run() {  # name  env-assignments  extra-args...
  local name="$1"; shift
  local env="$1"; shift
  echo "======================================================================"
  echo "CONFIG: $name    ($(date +%H:%M:%S))"
  echo "======================================================================"
  if env $env "$PY" "$RUN" --manifest "$MF" --out "$OUT/$name.json" "$@"; then
    echo ">>> $name DONE"
  else
    echo ">>> $name FAILED (skipped) — see output above" >&2
  fi
}

# 1) Pathumma, STT only (pure) — the raw-recognition baseline.
run "pathumma_pure"  ""  --engine pathumma-mlx --no-cleanup --label "Pathumma (STT only)"

# 2) Pathumma + Gemma E4B cleanup — the SHIPPING config.
run "pathumma_e4b"   "OLIV_CLEANUP_MODEL=$E4B"  --engine pathumma-mlx --label "Pathumma + Cleanup E4B"

# 3) Pathumma + Gemma E2B cleanup — the low-RAM candidate.
run "pathumma_e2b"   "OLIV_CLEANUP_MODEL=$E2B"  --engine pathumma-mlx --label "Pathumma + Cleanup E2B"

# 4) Whisper large-v3, STT only — the English-heavy fallback model.
run "largev3_pure"   ""  --engine mlx-large-v3 --no-cleanup --label "Whisper large-v3 (STT only)"

# 5) Whisper large-v3 + E4B cleanup — does cleanup help the fallback too.
run "largev3_e4b"    "OLIV_CLEANUP_MODEL=$E4B"  --engine mlx-large-v3 --label "large-v3 + Cleanup E4B"

# 6) vb bucket with vocabulary OFF — the B3 baseline (compare vs pathumma_e4b's
#    vb, which has vocab ON) to isolate the custom-vocabulary lift.
run "vb_novocab_e4b" "OLIV_CLEANUP_MODEL=$E4B"  --engine pathumma-mlx --buckets vb --no-vocab --label "vb: vocabulary OFF (E4B)"

echo "======================================================================"
echo "SWEEP COMPLETE ($(date +%H:%M:%S)). Results in $OUT/"
ls -la "$OUT"

# --- Groq (deferred; needs the key) ------------------------------------------
# export GROQ_API_KEY=...    # or: security find-generic-password -s com.oliv.app -a groq-api-key -w
# env GROQ_API_KEY="$GROQ_API_KEY" "$PY" "$RUN" --manifest "$MF" --engine groq-large-v3 \
#   --no-cleanup --label "Groq large-v3 (STT only)" --out "$OUT/groq_pure.json"
# env GROQ_API_KEY="$GROQ_API_KEY" OLIV_CLEANUP_MODEL="$E4B" "$PY" "$RUN" --manifest "$MF" \
#   --engine groq-large-v3 --label "Groq + Cleanup E4B" --out "$OUT/groq_e4b.json"
