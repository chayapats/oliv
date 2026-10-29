#!/bin/bash
# Build oliv-api and oliv-keys (static musl), push them plus vm/, then
# restart the API to apply its auth/config, then changed services, and check health.
#
# Usage: OLIV_VM=<ssh destination> deploy/deploy.sh [--dry-run]
#
# OLIV_VM is required: an ssh destination (user@host or an ~/.ssh/config alias)
# whose ~/oliv holds the vm/ layout. See server/README.md.
#
# - Never touches other services on the host, never restarts Gemma, never
#   deletes anything remote.
# - Backs up every file it will overwrite to ~/oliv/backups/deploy-<ts>.tgz first.
# - Never changes config.toml, auth mode, API keys, legacy token or tunnel config.
# - Old configs without explicit auth_mode fail preflight before remote writes.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VM="${OLIV_VM:?set OLIV_VM to the ssh destination of your OLIV server (user@host or an ssh config alias)}"
BIN="$REPO/oliv-api/target/release/oliv-api"
KEY_BIN="$REPO/oliv-api/target/release/oliv-keys"
DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

say() { printf '\n== %s\n' "$*"; }
# An IPv4 literal in 100.64.0.0/10, the private overlay range (Tailscale,
# Headscale...) oliv-api may bind besides loopback. Mirrors oliv_config.py.
overlay_ip() {
  local o='(0|[1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
  [[ $1 =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.$o\.$o$ ]]
}
remote() { ssh -o ConnectTimeout=10 "$VM" "$@"; }

if [[ -n "$(git -C "$REPO" status --porcelain -- vm oliv-api)" ]]; then
  echo "warning: deploying uncommitted changes in vm or oliv-api" >&2
fi

say "read-only deployment preflight"
preflight="$(remote "python3 - ~/oliv" < "$REPO/vm/deploy_preflight.py")" || exit 1
read -r API_HOST AUTH_MODE CONFIG_DIGEST extra <<< "$preflight"
# Allowed: 127.0.0.1 with keys, or a private overlay IP with keys or legacy.
if ! { [[ $API_HOST == 127.0.0.1 && $AUTH_MODE == keys ]] ||
       { overlay_ip "$API_HOST" && [[ $AUTH_MODE == keys || $AUTH_MODE == legacy ]]; }; }; then
  echo "invalid deployment preflight response" >&2; exit 1
fi
[[ $CONFIG_DIGEST =~ ^[0-9a-f]{64}$ && -z $extra ]] || { echo "invalid config digest from preflight" >&2; exit 1; }
API_URL="http://$API_HOST:8083"

check_config_unchanged() {
  local fresh host mode digest extra
  fresh="$(remote "python3 - ~/oliv" < "$REPO/vm/deploy_preflight.py")" || return 1
  read -r host mode digest extra <<< "$fresh"
  if [[ "$host/$mode/$digest" != "$API_HOST/$AUTH_MODE/$CONFIG_DIGEST" || -n $extra ]]; then
    echo "config changed during deployment; active binaries were not replaced. Review and rerun deployment." >&2
    return 1
  fi
  # Use the just-validated mode for credential validation below.
  AUTH_MODE="$mode"
}

say "build oliv-api and oliv-keys (reproducible, scripts/build-release.sh)"
"$REPO/scripts/build-release.sh"
file "$BIN" | grep -q "static" || { echo "oliv-api is not statically linked" >&2; exit 1; }
file "$KEY_BIN" | grep -q "static" || { echo "oliv-keys is not statically linked" >&2; exit 1; }

# Runtime config, auth state and tunnel configuration are operator-owned.
mapfile -t FILES < <(git -C "$REPO" ls-files vm | sed 's|^vm/||' |
  grep -vx -e 'config.toml' -e 'api-keys.json' -e 'api.token')

say "compare with the VM"
declare -A LOCAL THERE
while read -r sum name; do LOCAL["$name"]="$sum"; done < <(cd "$REPO/vm" && sha256sum "${FILES[@]}")
LOCAL["bin/oliv-api"]="$(sha256sum < "$BIN" | cut -d' ' -f1)"
LOCAL["bin/oliv-keys"]="$(sha256sum < "$KEY_BIN" | cut -d' ' -f1)"
while read -r sum name; do THERE["$name"]="$sum"; done < <(
  remote "cd ~/oliv && for f in $(printf '%q ' "${FILES[@]}") bin/oliv-api bin/oliv-keys; do [[ -f \$f ]] && sha256sum \"\$f\"; done; true")
CHANGED=()
for name in "${!LOCAL[@]}"; do
  [[ "${THERE[$name]:-}" == "${LOCAL[$name]}" ]] || CHANGED+=("$name")
done
changed() { local n; for n in "${CHANGED[@]}"; do [[ "$n" == "$1" ]] && return 0; done; return 1; }

restart_whisper=0; restart_api=1; restart_dashboard=0
# Restarts an interrupted deploy synced files for but never ran.
pending="$(remote "cat ~/oliv/run/deploy-pending 2>/dev/null; true")"
[[ " $pending " == *" whisper "* ]] && restart_whisper=1
[[ " $pending " == *" api "* ]] && restart_api=1
[[ " $pending " == *" dashboard "* ]] && restart_dashboard=1
changed whisper_server.py && restart_whisper=1
# Always apply the operator-owned API config, including config-only auth changes.
if changed dashboard_usage.py || changed dashboard.py || changed dashboard_keys.py || changed dashboard.html || changed oliv_config.py; then restart_dashboard=1; fi

# The consumer tunnel refuses to (re)start unless the VM's hand-provisioned
# cloudflared/consumer-config.json ingress equals consumer_tunnel.ingress() for
# its hostname. Never ship an ingress rule the VM config does not match yet:
# the public API would go down at the next tunnel restart or reboot.
if changed consumer_tunnel.py; then
  have="$(remote "cd ~/oliv && if [[ -f cloudflared/consumer-config.json ]]; then python3 -c 'import json; print(json.dumps(json.load(open(\"cloudflared/consumer-config.json\"))[\"ingress\"], sort_keys=True))'; else echo absent; fi")"
  if [[ "$have" != absent ]] && ! (cd "$REPO/vm" && python3 -c 'import json, sys, consumer_tunnel as c; c.ingress_hostname(json.loads(sys.argv[1]))' "$have") >/dev/null 2>&1; then
    echo "consumer tunnel ingress on the VM differs from vm/consumer_tunnel.py; update ~/oliv/cloudflared/consumer-config.json first (README.md, "Reaching the API from your devices"). Nothing was changed." >&2
    exit 1
  fi
fi

if [[ ${#CHANGED[@]} -eq 0 ]]; then echo "  no file changes"; else printf '  changed: %s\n' "${CHANGED[@]}"; fi
echo "  existing API bind: $API_HOST:8083 · explicit auth mode: $AUTH_MODE (unchanged)"
echo "  restart: whisper=$restart_whisper api=$restart_api dashboard=$restart_dashboard (gemma never)"
[[ $DRY -eq 1 ]] && { echo "dry run, nothing sent"; exit 0; }

if [[ ${#CHANGED[@]} -gt 0 ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  say "backup to ~/oliv/backups/deploy-$ts.tgz"
  remote "cd ~/oliv && mkdir -p backups && existing=(); for f in $(printf '%q ' "${CHANGED[@]}") config.toml; do [[ -e \$f ]] && existing+=(\"\$f\"); done;
          if [[ \${#existing[@]} -gt 0 ]]; then (umask 077; tar czf backups/deploy-$ts.tgz \"\${existing[@]}\"); echo \"  \${#existing[@]} files\"; else echo '  nothing to back up'; fi"
fi

todo=""
[[ $restart_whisper -eq 1 ]] && todo+=" whisper"
[[ $restart_api -eq 1 ]] && todo+=" api"
[[ $restart_dashboard -eq 1 ]] && todo+=" dashboard"
remote "mkdir -p ~/oliv/run && echo '$todo' > ~/oliv/run/deploy-pending"

if [[ ${#CHANGED[@]} -gt 0 ]]; then
  say "sync"
  vm_changed=()
  for n in "${CHANGED[@]}"; do
    [[ "$n" != bin/oliv-api && "$n" != bin/oliv-keys ]] && vm_changed+=("$n")
  done
  if [[ ${#vm_changed[@]} -gt 0 ]]; then
    printf '%s\n' "${vm_changed[@]}" | rsync -a --files-from=- "$REPO/vm/" "$VM:oliv/"
  fi
  if changed bin/oliv-api; then
    rsync -a "$BIN" "$VM:oliv/bin/oliv-api.new"
  fi
  if changed bin/oliv-keys; then
    rsync -a "$KEY_BIN" "$VM:oliv/bin/oliv-keys.new"
  fi
fi

# Validate staged configuration/key schema before replacing the active binaries.
remote "cd ~/oliv && python3 oliv_config.py check" >/dev/null || { echo "config.toml check failed on the VM" >&2; exit 1; }
check_config_unchanged
if [[ $AUTH_MODE == keys ]]; then
  keys_check=oliv-keys
  changed bin/oliv-keys && keys_check=oliv-keys.new
  remote "~/oliv/bin/$keys_check --root ~/oliv list >/dev/null" || {
    echo "key-store validation failed; active binaries and running API were not replaced" >&2
    exit 1
  }
fi
check_config_unchanged
changed bin/oliv-keys && remote "mv -f ~/oliv/bin/oliv-keys.new ~/oliv/bin/oliv-keys"
changed bin/oliv-api && remote "mv -f ~/oliv/bin/oliv-api.new ~/oliv/bin/oliv-api"
echo "note: operator-owned config is preserved; API restart applies its validated auth/config."

wait_health() {  # url, up|down, seconds (checked from the VM)
  remote "for i in \$(seq 1 $3); do if curl -sf --max-time 2 '$1' >/dev/null; then [[ $2 == up ]] && exit 0; else [[ $2 == down ]] && exit 0; fi; sleep 1; done; exit 1"
}

if [[ $restart_whisper -eq 1 ]]; then
  say "restart whisper"
  remote "~/oliv/stop.sh whisper"
  wait_health http://127.0.0.1:8082/health down 20
  remote "~/oliv/start.sh whisper"
  wait_health http://127.0.0.1:8082/health up 180 || { echo "whisper did not come up, see ~/oliv/logs/whisper-server.log" >&2; exit 1; }
fi
# oliv-api has no graceful drain: stopping it cuts off a dictation in flight.
# Restart only between requests (no open connections on :8083 for two checks
# in a row); if it stays busy, leave the old process serving and let a rerun
# finish (deploy-pending keeps the restart queued).
IDLE_TRIES="${OLIV_DEPLOY_IDLE_TRIES:-240}"  # × 0.5 s
wait_api_idle() {
  remote "idle=0; for i in \$(seq 1 $IDLE_TRIES); do
            if [[ -z \$(ss -Htn state established '( sport = :8083 )') ]]; then
              idle=\$((idle + 1)); [[ \$idle -ge 2 ]] && exit 0
            else idle=0; fi
            sleep 0.5
          done; exit 1"
}
if [[ $restart_api -eq 1 ]] || ! remote "curl -sf --max-time 2 $API_URL/health >/dev/null"; then
  say "restart oliv-api"
  if remote "curl -sf --max-time 2 $API_URL/health >/dev/null"; then
    wait_api_idle || { echo "oliv-api stayed busy for 120 s; not restarted. Rerun deploy to finish." >&2; exit 1; }
  fi
  remote "~/oliv/stop.sh api && ~/oliv/start.sh api"
  wait_health "$API_URL/health" up 20 || { remote "tail -5 ~/oliv/logs/oliv-api.log" >&2; exit 1; }
fi
if [[ $restart_dashboard -eq 1 ]]; then
  say "restart dashboard"
  remote "~/oliv/dashboard.sh stop && ~/oliv/dashboard.sh start"
fi

remote "rm -f ~/oliv/run/deploy-pending"

say "health"
fail=0
check() {  # name, vm|laptop, url
  local out
  if [[ $2 == vm ]]; then out="$(remote "curl -sf --max-time 3 '$3'" 2>/dev/null)" || out=""
  else out="$(curl -sf --max-time 3 "$3" 2>/dev/null)" || out=""; fi
  if [[ -n "$out" ]]; then printf '  ok    %-9s %s\n' "$1" "${out:0:140}"; else printf '  FAIL  %s\n' "$1"; fail=1; fi
}
check gemma vm http://127.0.0.1:8081/health
check whisper vm http://127.0.0.1:8082/health
check dashboard vm http://127.0.0.1:8090/health
check oliv-api vm "$API_URL/health"
if [[ $API_HOST != 127.0.0.1 ]]; then check private-api laptop "$API_URL/health"; fi
exit $fail
