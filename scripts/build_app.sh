#!/usr/bin/env bash
# Assemble a self-contained Rust + native MLX app. Python is developer tooling only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DERIVED="${OLIV_DERIVED_DATA:-$BUILD/DerivedData}"
APP="$BUILD/OLIV.app"
bash "$ROOT/scripts/build_native.sh"
xcodebuild -project "$ROOT/macos/OLIV.xcodeproj" -scheme OLIV -configuration Release \
  -derivedDataPath "$DERIVED" build
rm -rf "$APP"
cp -R "$DERIVED/Build/Products/Release/OLIV.app" "$APP"
RT="$APP/Contents/Resources/oliv-runtime"
mkdir -p "$RT/bin" "$RT/licenses"
cp -R "$BUILD/native-runtime/." "$RT/bin/"
cp "$ROOT/macos/OLIVInference/LICENSE-mlx-audio-swift" "$RT/licenses/"
cp "$ROOT/macos/OLIVInference/LICENSE-mlx-whisper" "$RT/licenses/"
cp "$ROOT/macos/OLIVInference/UPSTREAM.md" "$RT/licenses/native-inference.md"
cp "$ROOT/rust/crates/oliv-text/LICENSE-APACHE" "$RT/licenses/LICENSE-oliv-linux"
cp "$ROOT/rust/crates/oliv-text/data/LICENSE-pythainlp" "$RT/licenses/"
cp "$ROOT/rust/crates/oliv-text/UPSTREAM.md" "$RT/licenses/rust-core.md"
"${OLIV_CARGO:-$HOME/.cargo/bin/cargo}" metadata --locked --manifest-path "$ROOT/rust/Cargo.toml" \
  --format-version 1 --filter-platform aarch64-apple-darwin > "$BUILD/rust-metadata.json"
swift "$ROOT/scripts/collect_rust_licenses.swift" "$BUILD/rust-metadata.json" "$RT/licenses/rust"
# Ship the licenses for statically linked package dependencies too.
for package in "$DERIVED"/SourcePackages/checkouts/*; do
  [ -d "$package" ] || continue
  for license in "$package"/LICENSE* "$package"/COPYING*; do
    [ -f "$license" ] || continue
    cp "$license" "$RT/licenses/$(basename "$package")-$(basename "$license")"
  done
done
# Include Swift's compatibility dylibs for the macOS 14 deployment target.
xcrun swift-stdlib-tool --copy --scan-executable "$RT/bin/oliv-inference" \
  --destination "$APP/Contents/Frameworks" --platform macosx
IDENTITY="${OLIV_SIGN_IDENTITY:-Apple Development}"
if [ "$IDENTITY" != - ] && ! security find-identity -p codesigning -v | /usr/bin/grep -q "$IDENTITY"; then
  echo "Signing identity unavailable; using ad-hoc" >&2
  IDENTITY=-
fi
while IFS= read -r -d '' library; do
  codesign --force --options runtime -s "$IDENTITY" "$library"
done < <(find "$APP/Contents/Frameworks" -type f -name '*.dylib' -print0)
# Native helpers need no JIT, executable-memory or library-validation exception.
for helper in oliv-sidecar oliv-inference; do
  codesign --force --options runtime -s "$IDENTITY" "$RT/bin/$helper"
done
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  FWV="$FW/Versions/Current"
  for xpc in "$FWV"/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    codesign --force --options runtime --preserve-metadata=entitlements -s "$IDENTITY" "$xpc"
  done
  codesign --force --options runtime -s "$IDENTITY" "$FWV/Autoupdate"
  codesign --force --options runtime -s "$IDENTITY" "$FWV/Updater.app"
  codesign --force --options runtime -s "$IDENTITY" "$FW"
fi
codesign --force --options runtime --entitlements "$ROOT/macos/OLIV.entitlements" -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
# Tripwire: the distributable cannot accidentally contain the old runtime.
if find "$RT" \( -iname '*python*' -o -name '*.py' -o -name '*.pyc' \) -print -quit | /usr/bin/grep -q .; then
  echo "Python unexpectedly present in the app runtime" >&2; exit 1
fi
printf '{"id":1,"cmd":"ping"}\n' | "$RT/bin/oliv-sidecar"
printf '{"id":1,"cmd":"ping"}\n' | "$RT/bin/oliv-inference"
codesign --verify --deep --strict "$APP"
du -sh "$APP" "$RT"
