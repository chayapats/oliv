#!/bin/bash
# Run deploy/deploy.sh from a machine without bash 4 / GNU rsync (macOS).
#
# Usage: OLIV_VM=<ssh destination> deploy/deploy-in-container.sh [--dry-run]
#
# A throwaway Debian container provides bash 5, GNU rsync, ssh and the docker
# CLI. The repo is mounted at its host path and the host's docker socket is
# shared, so scripts/build-release.sh keeps building in the pinned image with
# host-resolvable volume paths. SSH uses a copy of ~/.ssh (config, the key it
# names, known_hosts) inside the container; nothing is written back.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=oliv-deployer
: "${OLIV_VM:?set OLIV_VM to the ssh destination of your OLIV server (user@host or an ssh config alias)}"

docker build -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      bash rsync openssh-client python3 file curl git ca-certificates docker.io >/dev/null \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

docker run --rm -i \
  -v "$REPO:$REPO" -w "$REPO" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.ssh:/ssh-src:ro" \
  -e HOME=/root -e OLIV_VM="$OLIV_VM" \
  "$IMAGE" bash -euc '
    git config --global --add safe.directory "$PWD"
    install -d -m 700 /root/.ssh
    cp -L /ssh-src/config /ssh-src/known_hosts /root/.ssh/ 2>/dev/null || true
    for key in /ssh-src/id_*; do case "$key" in *.pub) ;; *) cp -L "$key" /root/.ssh/ ;; esac; done
    chmod 600 /root/.ssh/*
    sed -i "/ForwardAgent/d; /UseKeychain/d" /root/.ssh/config 2>/dev/null || true
    exec deploy/deploy.sh "$@"' deploy "$@"
