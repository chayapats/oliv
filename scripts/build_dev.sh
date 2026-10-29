#!/usr/bin/env bash
# Native developer tools are kept outside the distributable app runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DERIVED="${OLIV_DERIVED_DATA:-$BUILD/DerivedData}"
CARGO="${OLIV_CARGO:-$HOME/.cargo/bin/cargo}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$BUILD/rust-target}"
"$CARGO" build --locked --manifest-path "$ROOT/rust/Cargo.toml" --release -p oliv-dev
mkdir -p "$BUILD/native-tools"
cp "$CARGO_TARGET_DIR/release/oliv-dev" "$CARGO_TARGET_DIR/release/oliv-test-worker" "$BUILD/native-tools/"
if [ "${1:-}" = --tests-only ]; then exit 0; fi
bash "$ROOT/scripts/build_native.sh"
xcodebuild -project "$ROOT/macos/OLIV.xcodeproj" -scheme OLIVSemantic \
  -configuration Release -derivedDataPath "$DERIVED" build
cp "$DERIVED/Build/Products/Release/oliv-semantic" "$BUILD/native-tools/"
for bundle in "$BUILD/native-runtime"/*.bundle; do
  [ -d "$bundle" ] || continue
  ditto "$bundle" "$BUILD/native-tools/$(basename "$bundle")"
done
swift build --package-path "$ROOT/tools/dmg" --configuration release
cp "$ROOT/tools/dmg/.build/release/oliv-dmg" "$BUILD/native-tools/"
