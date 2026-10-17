#!/usr/bin/env bash
# Download Thai ContextASR Bench (wayu-ai/thai-contextasr-bench) at the pinned
# revision into a directory OUTSIDE the checkout. Data and audio are CC-BY-NC-4.0;
# never commit or redistribute them. Usage: fetch_contextasr.sh [dest]
set -euo pipefail
REV=84e309935208cca72ce4a19b073dc450515febad
LISTS_SHA256=dad80ee6a82f32f97ffea3e230192fcda26baa61e22b4dd1e218be71a09edd42
DEST="${1:-${OLIV_CONTEXTASR_DIR:-$HOME/.cache/oliv-bench/thai-contextasr-bench}}"
BASE="https://huggingface.co/datasets/wayu-ai/thai-contextasr-bench/resolve/$REV"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Resolve the complete destination, including symlinks and new parent directories,
# before fetching any data. Parent-only checks can miss a nested new directory.
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"
case "$DEST/" in
  "$ROOT/"*) echo "Choose a destination outside the repository" >&2; exit 1 ;;
esac
mkdir -p "$DEST/data" "$DEST/audio" "$DEST/scorer"
fetch() { [ -s "$DEST/$1" ] || curl -sfL --retry 3 -o "$DEST/$1" "$BASE/$1"; }
for f in README.md data/utterances.jsonl data/bias_lists.jsonl.gz \
  scorer/score.py scorer/metrics.py scorer/norm.py scorer/tok.py; do
  fetch "$f"
done
echo "$LISTS_SHA256  $DEST/data/bias_lists.jsonl.gz" | shasum -a 256 -c -
grep -o '"utt_id": "[^"]*"' "$DEST/data/utterances.jsonl" | cut -d'"' -f4 |
  xargs -P 16 -I{} sh -c '[ -s "$0/audio/{}.wav" ] || curl -sfL --retry 3 -o "$0/audio/{}.wav" "$1/audio/{}.wav"' "$DEST" "$BASE"
printf '%s audio files in %s\n' "$(find "$DEST/audio" -name '*.wav' -size +0 | wc -l | tr -d ' ')" "$DEST"
