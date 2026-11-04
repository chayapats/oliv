#!/usr/bin/env bash
# Build the experimental MLState adapter against the exact WhisperKit pin.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${OLIV_ANE_STATEFUL_BUILD:-$ROOT/build/ane-whisper-stateful}"
swift package --package-path "$ROOT/tools/ane-whisper" --scratch-path "$SCRATCH" resolve
CHECKOUT="$SCRATCH/checkouts/argmax-oss-swift"
[ "$(git -C "$CHECKOUT" rev-parse HEAD)" = 9f99b5cb6a907730543823ad271b82532782a899 ] || {
  echo 'Stateful extension patch requires the pinned WhisperKit revision' >&2; exit 2;
}
PATCH="$ROOT/tools/ane-whisper/stateful-decoder.patch"
if git -C "$CHECKOUT" apply --unidiff-zero --reverse --check "$PATCH" 2>/dev/null; then
  : # Already applied to this scratch checkout.
else
  git -C "$CHECKOUT" apply --unidiff-zero --check "$PATCH"
  git -C "$CHECKOUT" apply --unidiff-zero "$PATCH"
fi
swift build -c release --package-path "$ROOT/tools/ane-whisper" \
  --scratch-path "$SCRATCH" -Xswiftc -DOLIV_STATEFUL
