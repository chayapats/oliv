#!/usr/bin/env bash
# Reproducible release build of oliv-api + oliv-keys (static-pie musl, x86_64).
#
# Uses a pinned toolchain image, so a clean checkout of a given commit rebuilds
# the same bytes and the binary on a server can be traced back to its commit.
# Prints the sha256 of each binary.
#
# The docker build context is the whole monorepo, mounted at /work: oliv-api
# depends on ../../rust/crates/oliv-text-core (path dependency). The mount
# point is part of the reproducible output (paths are embedded in panic
# messages), so keep it at /work.
#
# Usage: server/scripts/build-release.sh [--test]
#   --test   first run the full test suite in the same toolchain image, on the
#            host's native architecture (fast; logic tests are arch-independent)
#
# Output: server/oliv-api/target/release/{oliv-api,oliv-keys} (what deploy/deploy.sh
# ships). The image's host target is x86_64-unknown-linux-musl; do NOT pass
# --target: it changes the output bytes and breaks reproducibility.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # server/
MONOREPO="$(cd "$ROOT/.." && pwd)"
[[ -f "$MONOREPO/rust/crates/oliv-text-core/Cargo.toml" ]] || {
  echo "expected the OLIV monorepo layout: $MONOREPO/rust/crates/oliv-text-core is missing" >&2
  exit 1
}
# rust:1.99.0-alpine, pinned by digest. The registry cache must stay mounted at
# /usr/local/cargo/registry: dependency paths are embedded in panic messages.
IMAGE="rust:1.99.0-alpine@sha256:0cce0a5e0e8ba67b455257a3a02a1d99005f382748789d6464460028810f1627"
RUN_TESTS=0
case "${1:-}" in
  "") ;;
  --test) RUN_TESTS=1 ;;
  *) echo "usage: $0 [--test]" >&2; exit 2 ;;
esac

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

run() {
  docker run --rm "$@" \
    -v "$MONOREPO:/work" \
    -v oliv-cargo-registry:/usr/local/cargo/registry \
    -w /work/server/oliv-api \
    "$IMAGE" sh -euc "apk add --no-cache -q musl-dev >/dev/null; $CMD"
}

if [[ $RUN_TESTS -eq 1 ]]; then
  # Test artifacts live in a volume: cargo's pipelined .rmeta reads race on
  # macOS bind mounts (spurious E0463 "can't find crate").
  CMD='CARGO_TARGET_DIR=/target cargo test --locked --all-targets' \
    run -v oliv-monorepo-server-test-target:/target
fi
CMD='cargo build --locked --release --bins' run --platform linux/amd64

cd "$ROOT/oliv-api/target/release"
sha256sum oliv-api oliv-keys 2>/dev/null || shasum -a 256 oliv-api oliv-keys
