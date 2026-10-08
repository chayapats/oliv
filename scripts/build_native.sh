#!/usr/bin/env bash
# Build the Python-free workers. Xcode supplies MLX's compiled Metal resources.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DERIVED="${OLIV_DERIVED_DATA:-$BUILD/DerivedData}"
CARGO="${OLIV_CARGO:-$HOME/.cargo/bin/cargo}"
[ "$(uname -m)" = arm64 ] || { echo "OLIV requires Apple Silicon" >&2; exit 1; }
[ -x "$CARGO" ] || { echo "Install the stable Rust toolchain: https://rustup.rs" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "Install xcodegen first" >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$BUILD/rust-target}"
"$CARGO" build --locked --manifest-path "$ROOT/rust/Cargo.toml" --release -p oliv-sidecar -p oliv-tokenizer
mkdir -p "$BUILD/native-libs"
cp "$CARGO_TARGET_DIR/release/liboliv_tokenizer.a" "$BUILD/native-libs/"
xcrun metal -v >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain
(cd "$ROOT/macos" && xcodegen generate)
if [ -f "$ROOT/macos/Package.resolved" ]; then
  RESOLVED="$ROOT/macos/OLIV.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  mkdir -p "$RESOLVED"
  cp "$ROOT/macos/Package.resolved" "$RESOLVED/Package.resolved"
fi
xcodebuild -project "$ROOT/macos/OLIV.xcodeproj" -scheme OLIVInference \
  -configuration Release -derivedDataPath "$DERIVED" build
RUNTIME="$BUILD/native-runtime"
mkdir -p "$RUNTIME"
cp "$CARGO_TARGET_DIR/release/oliv-sidecar" "$RUNTIME/oliv-sidecar"
cp "$DERIVED/Build/Products/Release/oliv-inference" "$RUNTIME/oliv-inference"
# Bundle.module resolves from the helper's directory after relocation.
for bundle in "$DERIVED"/Build/Products/Release/*.bundle; do
  [ -d "$bundle" ] || continue
  rm -rf "$RUNTIME/$(basename "$bundle")"
  cp -R "$bundle" "$RUNTIME/"
done
rm -rf "$RUNTIME/whisper-tokenizer"
cp -R "$ROOT/macos/OLIVInference/Resources/whisper-tokenizer" "$RUNTIME/"
printf '{"id":1,"cmd":"ping"}\n' | "$RUNTIME/oliv-sidecar"
