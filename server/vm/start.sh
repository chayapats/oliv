#!/bin/bash
# Start OLIV inference from config.toml. Touches nothing else on the host.
# Usage: start.sh [gemma|whisper|api|api-tunnel|all] (all excludes api-tunnel)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/run" "$ROOT/logs"
target="${1:-all}"
case "$target" in
  gemma|whisper|api|api-tunnel|all) ;;
  *)
    echo "usage: $0 [gemma|whisper|api|api-tunnel|all]" >&2
    exit 2
    ;;
esac

# The dashboard holds this lock across stop+start and sets OLIV_HAVE_LOCK
# so a second flock here cannot deadlock against the parent.
# Every service below is launched with 9>&- so it does not inherit this fd:
# a long-lived child holding it would keep the lock forever.
if [[ -z "${OLIV_HAVE_LOCK:-}" ]]; then
  exec 9>"$ROOT/run/action.lock"
  flock 9
fi

# An explicit action only: never publish an ingress as a side effect of "all".
# Use the service manager once installed; its launch path bypasses this router.
if [[ "${OLIV_SYSTEMD_LAUNCH:-}" != 1 && -f "$ROOT/systemd/oliv-api.service" ]] && systemctl --user cat oliv-api.service >/dev/null 2>&1; then
  if [[ "$target" == all ]]; then
    systemctl --user start oliv-gemma.service oliv-whisper.service oliv-api.service
  else
    systemctl --user start "oliv-${target}.service"
  fi
  exit
fi

if [[ "$target" == api-tunnel ]]; then
  OLIV_HAVE_LOCK=1 python3 "$ROOT/consumer_tunnel.py" start
  exit
fi

config_env="$(python3 "$ROOT/oliv_config.py" export)"
eval "$config_env"

start_gemma() {
  if curl -sf --max-time 2 "http://${GEMMA_HOST}:${GEMMA_PORT}/health" >/dev/null; then
    echo "gemma already up on :${GEMMA_PORT}"
    return 0
  fi
  if [[ ! -x "$ROOT/bin/llama-b11223/llama-server" ]]; then
    echo "missing llama-server binary" >&2
    return 1
  fi
  setsid "$ROOT/bin/llama-b11223/llama-server" \
    -m "$GEMMA_MODEL" \
    -ngl "$GEMMA_NGL" \
    -c "$GEMMA_CTX" \
    -b "$GEMMA_BATCH" \
    -ub "$GEMMA_UBATCH" \
    -ctk "$GEMMA_CTK" \
    -ctv "$GEMMA_CTV" \
    -fa "$GEMMA_FA" \
    -np "$GEMMA_NP" \
    --reasoning "$GEMMA_REASONING" \
    --host "$GEMMA_HOST" \
    --port "$GEMMA_PORT" \
    9>&- >> "$ROOT/logs/llama-server.log" 2>&1 &
  echo $! > "$ROOT/run/llama.pid"
  echo "gemma starting, pid $(cat "$ROOT/run/llama.pid")"
}

start_whisper() {
  if curl -sf --max-time 2 "http://${WHISPER_HOST}:${WHISPER_PORT}/health" >/dev/null; then
    echo "whisper already up on :${WHISPER_PORT}"
    return 0
  fi
  export LD_LIBRARY_PATH="$ROOT/.venv/lib/python3.12/site-packages/nvidia/cublas/lib:$ROOT/.venv/lib/python3.12/site-packages/nvidia/cuda_runtime/lib:$ROOT/.venv/lib/python3.12/site-packages/nvidia/cuda_nvrtc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  setsid "$ROOT/.venv/bin/python" "$ROOT/whisper_server.py" \
    9>&- >> "$ROOT/logs/whisper-server.log" 2>&1 &
  echo $! > "$ROOT/run/whisper.pid"
  echo "whisper starting, pid $(cat "$ROOT/run/whisper.pid")"
}

# The config and binary validate the allowed bind/auth combinations. Credentials
# are provisioned explicitly: starting a service never creates or migrates them.
start_api() {
  if curl -sf --max-time 2 "http://${API_HOST}:${API_PORT}/health" >/dev/null; then
    echo "api already up on ${API_HOST}:${API_PORT}"
    return 0
  fi
  if [[ ! -x "$ROOT/bin/oliv-api" ]]; then
    echo "missing bin/oliv-api (run deploy/deploy.sh from the repo)" >&2
    return 1
  fi
  case "$API_AUTH_MODE" in
    keys)
      if [[ ! -x "$ROOT/bin/oliv-keys" ]]; then
        echo "missing bin/oliv-keys; provision the key CLI and private key store first" >&2
        return 1
      fi
      "$ROOT/bin/oliv-keys" --root "$ROOT" list >/dev/null || {
        echo "API key-store validation failed; no API process started" >&2
        return 1
      }
      ;;
    legacy)
      if [[ ! -f "$ROOT/api.token" ]] || [[ -L "$ROOT/api.token" ]] || \
         [[ "$(stat -c %a "$ROOT/api.token")" != 600 ]]; then
        echo "api.token missing, symlinked or not mode 600" >&2
        return 1
      fi
      ;;
    *) echo "invalid API_AUTH_MODE" >&2; return 1 ;;
  esac
  setsid "$ROOT/bin/oliv-api" --root "$ROOT" \
    9>&- >> "$ROOT/logs/oliv-api.log" 2>&1 &
  echo $! > "$ROOT/run/api.pid"
  echo "api starting, pid $(cat "$ROOT/run/api.pid")"
}

case "$target" in
  gemma) start_gemma ;;
  whisper) start_whisper ;;
  api) start_api ;;
  all) start_gemma; start_whisper; start_api ;;
esac
