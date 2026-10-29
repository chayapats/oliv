#!/usr/bin/env bash
# Reject owned interpreter sources in the Mac app; exclude generated builds,
# dependencies, and server/ (the self-hosted server's VM scripts are Python).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
command -v rg >/dev/null || { echo 'Install ripgrep to validate native sources' >&2; exit 1; }
if rg --files --hidden --no-ignore -g '*.py' -g '*.pyc' \
  -g '!build/**' -g '!rust/target/**' -g '!macos/DerivedData/**' \
  -g '!tools/dmg/.build/**' -g '!**/node_modules/**' -g '!.git/**' -g '!server/**' | rg .; then
  echo 'Legacy interpreter source or bytecode is present in the maintained checkout' >&2
  exit 1
fi
printf 'Native source check passed\n'
