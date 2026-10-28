#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TOOL="$ROOT/build/native-tools/oliv-dev"
[ -x "$TOOL" ] || { echo "Run bash scripts/build_dev.sh first" >&2; exit 1; }
OUT="$ROOT/benchmark/eval_results"
mkdir -p "$OUT"
export HF_HUB_OFFLINE=1
for engine in typhoon-turbo-mlx pathumma-mlx mlx-large-v3; do
  "$TOOL" eval --manifest data/manifest_all.jsonl --engine "$engine" \
    --no-cleanup --label "$engine (pure STT)" --out "$OUT/full_${engine}_pure.json"
  "$TOOL" eval --manifest data/manifest_all.jsonl --engine "$engine" \
    --label "$engine + Gemma E2B" --out "$OUT/full_${engine}_e2b.json"
done
"$TOOL" eval --manifest data/manifest_all.jsonl --buckets vb --no-vocab \
  --label "Typhoon + E2B, vocabulary off" --out "$OUT/full_typhoon_novocab.json"
