#!/usr/bin/env bash
# Download the Thai test split of FLEURS (google/fleurs, th_th) at a pinned
# revision into a directory OUTSIDE the checkout, for the multi-speaker accuracy
# proxy (`oliv-dev speakers fleurs`). FLEURS is CC-BY-4.0: you may use it with
# attribution, but its audio and transcripts still stay out of this repository.
# About 0.6 GB. Usage: fetch_fleurs_th.sh [dest]
set -euo pipefail
REV=70bb2e84b976b7e960aa89f1c648e09c59f894dd
TSV_SHA256=8db09d12ac384654f6677e141f6e55bf5bc42028160cbc0d2d9f7fac4fe25271
TAR_SHA256=a3c8bbfab5a124fb6b6475c238a9ec09957be5727aeacefe00eddbcf4bc0a82e
DEST="${1:-${OLIV_FLEURS_DIR:-$HOME/.cache/oliv-bench/fleurs-th}}"
BASE="https://huggingface.co/datasets/google/fleurs/resolve/$REV/data/th_th"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"
case "$DEST/" in
  "$ROOT/"*) echo "Choose a destination outside the repository" >&2; exit 1 ;;
esac
fetch() {
  if [ ! -s "$DEST/$2" ]; then
    curl -sfL --retry 3 -o "$DEST/$2.part" "$BASE/$1"
    mv "$DEST/$2.part" "$DEST/$2"
  fi
}
fetch test.tsv test.tsv
fetch audio/test.tar.gz test.tar.gz
echo "$TSV_SHA256  $DEST/test.tsv" | shasum -a 256 -c -
echo "$TAR_SHA256  $DEST/test.tar.gz" | shasum -a 256 -c -
if [ ! -d "$DEST/test" ]; then
  mkdir -p "$DEST/.extract"
  tar -xzf "$DEST/test.tar.gz" -C "$DEST/.extract"
  mv "$DEST/.extract/test" "$DEST/test"
  rmdir "$DEST/.extract"
fi
printf '%s audio files in %s\n' "$(find "$DEST/test" -name '*.wav' ! -name '._*' -size +0 | wc -l | tr -d ' ')" "$DEST"
