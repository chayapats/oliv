#!/bin/bash
# Start or stop the OLIV operator panel. Does not start or stop the models.
# Usage: dashboard.sh [start|stop]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/run" "$ROOT/logs"
cmd="${1:-start}"

# Use the service manager once installed (the unit runs dashboard.py directly).
# Otherwise stopping the unit's process would let Restart=always race a
# detached replacement for the port.
if [[ "$cmd" == start || "$cmd" == stop ]] && [[ -f "$ROOT/systemd/oliv-dashboard.service" ]] &&
   systemctl --user cat oliv-dashboard.service >/dev/null 2>&1; then
  systemctl --user "$cmd" oliv-dashboard.service
  echo "dashboard ${cmd} via oliv-dashboard.service"
  exit
fi

is_dashboard_pid() {
  local pid="$1" executable
  local -a args=()
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || return 1
  # Inspect NUL-delimited arguments, not a substring of a shell command. Only
  # the two Python invocations used for this exact OLIV dashboard are accepted.
  if [[ ${#args[@]} -eq 2 ]]; then
    [[ "${args[1]}" == "$ROOT/dashboard.py" ]] || return 1
  elif [[ ${#args[@]} -eq 3 ]]; then
    [[ "${args[1]}" == -u && "${args[2]}" == "$ROOT/dashboard.py" ]] || return 1
  else
    return 1
  fi
  [[ "${args[0]##*/}" =~ ^python([0-9]+(\.[0-9]+)*)?$ ]] || return 1
  executable="$(readlink "/proc/$pid/exe" 2>/dev/null)" || return 1
  [[ "${executable##*/}" =~ ^python([0-9]+(\.[0-9]+)*)?$ ]]
}

stop_dashboard_pid() {
  local pid="$1" i
  is_dashboard_pid "$pid" || return 0
  if ! kill "$pid" 2>/dev/null && is_dashboard_pid "$pid"; then
    echo "could not stop dashboard pid $pid" >&2
    return 1
  fi
  # Wait before start probes health, otherwise a dying old process can make
  # start report success without launching its replacement. Never kill a group.
  for i in $(seq 1 50); do
    if ! is_dashboard_pid "$pid"; then
      echo "stopped dashboard pid $pid"
      return 0
    fi
    sleep 0.1
  done
  echo "dashboard pid $pid did not exit; no replacement was started" >&2
  return 1
}

stop_dashboard() {
  local pidfile="$ROOT/run/dashboard.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile")"
    stop_dashboard_pid "$pid"
    rm -f "$pidfile"
  fi
  for entry in /proc/[0-9]*; do
    local pid="${entry##*/}"
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    stop_dashboard_pid "$pid"
  done
}

case "$cmd" in
  start)
    if curl -sf --max-time 2 http://127.0.0.1:8090/health >/dev/null; then
      echo "dashboard already up on :8090"
      exit 0
    fi
    setsid python3 -u "$ROOT/dashboard.py" >> "$ROOT/logs/dashboard.log" 2>&1 &
    echo $! > "$ROOT/run/dashboard.pid"
    for _ in $(seq 1 25); do
      if curl -sf --max-time 1 http://127.0.0.1:8090/health >/dev/null; then
        echo "dashboard up on http://127.0.0.1:8090"
        exit 0
      fi
      sleep 0.2
    done
    echo "dashboard failed to come up, see logs/dashboard.log" >&2
    exit 1
    ;;
  stop)
    stop_dashboard
    echo "dashboard stopped"
    ;;
  *)
    echo "usage: $0 [start|stop]" >&2
    exit 2
    ;;
esac
