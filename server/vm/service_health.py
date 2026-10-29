#!/usr/bin/env python3
"""Bounded readiness checks and recovery of active OLIV systemd services."""
import http.client
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PORTS = {"gemma": 8081, "whisper": 8082, "api": 8083, "api-tunnel": 20247,
         "dashboard": 8090}


def healthy(name):
    path = "/ready" if name.endswith("tunnel") else "/health"
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORTS[name]}{path}", timeout=3) as response:
            return response.status == 200
    except (OSError, ValueError, http.client.HTTPException):
        return False


def recover():
    state_path = ROOT / "run/service-health.json"
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        state = {}
    for name in PORTS:
        unit = f"oliv-{name}.service"
        result = subprocess.run(
            ["systemctl", "--user", "show", unit, "-p", "ActiveState", "-p", "MainPID"],
            capture_output=True, text=True, check=True, timeout=10)
        props = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        pid = props.get("MainPID", "0")
        # An intentional stop stays stopped. Restart=always handles process exits.
        if props.get("ActiveState") != "active" or pid == "0":
            state.pop(name, None)
            continue
        previous = state.get(name, {})
        failures = previous.get("failures", 0) if previous.get("pid") == pid else 0
        failures = 0 if healthy(name) else failures + 1
        state[name] = {"pid": pid, "failures": failures}
        if failures >= 3:
            print(f"{unit}: three consecutive failed health checks; restarting", flush=True)
            # try-restart also preserves stops racing with the probe.
            subprocess.run(["systemctl", "--user", "--no-block", "try-restart", unit],
                           check=True, timeout=10)
            state.pop(name, None)
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state))
    temporary.replace(state_path)


if __name__ == "__main__":
    if sys.argv[1] == "recover":
        recover()
    else:
        deadline = time.monotonic() + 120
        while not healthy(sys.argv[1]):
            if time.monotonic() >= deadline:
                raise SystemExit("OLIV readiness deadline exceeded")
            time.sleep(1)
