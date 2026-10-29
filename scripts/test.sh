#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DERIVED="${OLIV_DERIVED_DATA:-$BUILD/DerivedData}"
CARGO="${OLIV_CARGO:-$HOME/.cargo/bin/cargo}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$BUILD/rust-target}"
bash "$ROOT/scripts/check_native_sources.sh"
bash "$ROOT/scripts/build_native.sh"
bash "$ROOT/scripts/build_dev.sh" --tests-only
"$CARGO" test --locked --manifest-path "$ROOT/rust/Cargo.toml" --workspace
swift "$ROOT/scripts/test_native_runtime.swift" "$BUILD/native-runtime"
xcodebuild -project "$ROOT/macos/OLIV.xcodeproj" -scheme OLIV -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -parallel-testing-enabled NO test
