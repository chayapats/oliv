#!/bin/bash
# Build the oliv Linux client and install it for this user: binary, systemd
# user service (starts with the graphical session) and the Right Shift binds.
#
# Usage (from anywhere): desktop/deploy/install-client.sh
#
# - Safe to re-run: the binds are added once (marked block), the unit is rewritten,
#   the daemon is restarted so it runs the new binary.
# - ~/.config/hypr/bindings.lua is backed up (bindings.lua.oliv-bak-<ts>) before any edit.
# - Config (~/.config/oliv/config.toml, has the token) is never touched.
set -euo pipefail

# The client crate (desktop/) is this script's parent directory.
CRATE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/.local/bin/oliv"
UNIT="$HOME/.config/systemd/user/oliv.service"
BINDINGS="$HOME/.config/hypr/bindings.lua"
MARK="-- oliv: push-to-talk"
CANCEL_MARK="-- oliv: cancel"

say() { printf '\n== %s\n' "$*"; }

say "build"
cargo build --locked --release --manifest-path "$CRATE/Cargo.toml"

say "install $BIN"
mkdir -p "$(dirname "$BIN")"
# Write next to the target, then rename: works while the old binary is running.
install -m 755 "$CRATE/target/release/oliv" "$BIN.new"
mv -f "$BIN.new" "$BIN"

say "systemd unit"
mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=OLIV push-to-talk dictation daemon
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=$BIN daemon
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
UNIT_EOF
systemctl --user daemon-reload
systemctl --user enable oliv.service
systemctl --user restart oliv.service

say "hyprland binds"
if [[ ! -f "$BINDINGS" ]]; then
  echo "no $BINDINGS: add the binds yourself (see desktop/README.md)" >&2
elif grep -qF -- "$MARK" "$BINDINGS"; then
  echo "already present"
  if ! grep -qF -- "$CANCEL_MARK" "$BINDINGS"; then
    cat >> "$BINDINGS" <<BIND_EOF

$CANCEL_MARK (Shift+Esc while Right Shift is held = drop the recording)
hl.bind('SHIFT + Escape', hl.dsp.exec_cmd('$BIN cancel'))
BIND_EOF
    echo "added cancel bind"
  fi
else
  cp -p "$BINDINGS" "$BINDINGS.oliv-bak-$(date +%Y%m%d-%H%M%S)"
  cat >> "$BINDINGS" <<BIND_EOF

$MARK (Right Shift held = record; installed by desktop/deploy/install-client.sh)
hl.bind('Shift_R', hl.dsp.exec_cmd('$BIN start'))
hl.bind('SHIFT + Shift_R', hl.dsp.exec_cmd('$BIN stop'), { release = true })

$CANCEL_MARK (Shift+Esc while Right Shift is held = drop the recording)
hl.bind('SHIFT + Escape', hl.dsp.exec_cmd('$BIN cancel'))
BIND_EOF
  echo "added (Hyprland reloads its config on save)"
fi

say "status"
sleep 1
systemctl --user --no-pager --lines=3 status oliv.service | sed -n 1,8p
"$BIN" status
