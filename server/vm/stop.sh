#!/bin/bash
# Stop OLIV inference only. Does not touch other services or the dashboard.
# Usage: stop.sh [gemma|whisper|api|api-tunnel|all] (all excludes api-tunnel)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/run"
target="${1:-all}"
case "$target" in
  gemma|whisper|api|api-tunnel|all) ;;
  *)
    echo "usage: $0 [gemma|whisper|api|api-tunnel|all]" >&2
    exit 2
    ;;
esac

if [[ -z "${OLIV_HAVE_LOCK:-}" ]]; then
  exec 9>"$ROOT/run/action.lock"
  flock 9
fi

# Use the service manager once installed; its launch path bypasses this router.
if [[ "${OLIV_SYSTEMD_LAUNCH:-}" != 1 && -f "$ROOT/systemd/oliv-api.service" ]] && systemctl --user cat oliv-api.service >/dev/null 2>&1; then
  if [[ "$target" == all ]]; then
    systemctl --user stop oliv-gemma.service oliv-whisper.service oliv-api.service
  else
    systemctl --user stop "oliv-${target}.service"
  fi
  exit
fi

if [[ "$target" == api-tunnel ]]; then
  OLIV_HAVE_LOCK=1 python3 "$ROOT/consumer_tunnel.py" stop
  exit
fi

stop_pid() {
  local pid="$1"
  local pgid
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pid" -gt 1 ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -n "$pgid" && "$pgid" == "$pid" ]]; then
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  else
    kill "$pid" 2>/dev/null || true
  fi
  local i
  for i in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  if [[ -n "$pgid" && "$pgid" == "$pid" ]]; then
    kill -9 -- "-$pid" 2>/dev/null || true
  fi
  kill -9 "$pid" 2>/dev/null || true
}

stop_named() {
  local name="$1"
  local pidfile="$ROOT/run/${name}.pid"
  local pid
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      stop_pid "$pid"
      echo "stopped $name pid $pid"
    fi
    rm -f "$pidfile"
  fi
}

want_llama=0
want_whisper=0
want_api=0
case "$target" in
  gemma|all) want_llama=1 ;;
esac
case "$target" in
  whisper|all) want_whisper=1 ;;
esac
case "$target" in
  api|all) want_api=1 ;;
esac

if [[ "$want_api" == 1 ]]; then
  stop_named api
fi
if [[ "$want_llama" == 1 ]]; then
  stop_named llama
fi
if [[ "$want_whisper" == 1 ]]; then
  stop_named whisper
fi

# Fallback: match the real process command, not a shell that merely mentions the path.
for entry in /proc/[0-9]*; do
  pid="${entry#/proc/}"
  [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmd" in
    "$ROOT/bin/llama-b11223/llama-server "*)
      # Qwen ASR also uses llama-server. Only the Gemma port belongs here.
      if [[ "$want_llama" == 1 && " $cmd " == *" --port 8081 "* ]]; then
        stop_pid "$pid"
        echo "stopped pid $pid"
      fi
      ;;
    "$ROOT/.venv/bin/python $ROOT/whisper_server.py"*)
      if [[ "$want_whisper" == 1 ]]; then
        stop_pid "$pid"
        echo "stopped pid $pid"
      fi
      ;;
    "$ROOT/bin/oliv-api "*|"$ROOT/bin/oliv-api")
      if [[ "$want_api" == 1 ]]; then
        stop_pid "$pid"
        echo "stopped pid $pid"
      fi
      ;;
  esac
done
echo "oliv $target stopped"
