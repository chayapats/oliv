#!/usr/bin/env python3
"""Is the OLIV server's public /health answering? For the scheduled uptime check.

Reads the URL from OLIV_HEALTH_URL and never prints it, its host or its path.
A URL without a path checks /health. One failed attempt is retried once after
OLIV_HEALTH_RETRY_DELAY seconds (default 30) before the server counts as down.

Exit 0: up, or skipped because OLIV_HEALTH_URL is empty (forks).
Exit 1: down. Exit 2: OLIV_HEALTH_URL is not a usable http(s) URL.
In GitHub Actions it also masks the host and writes state=up|down|skipped|error
and a URL-free reason to $GITHUB_OUTPUT.
"""
import http.client
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Cloudflare in front of the server rejects default script agents such as
# Python-urllib with "error code: 1010" (server/docs/PUBLIC-API.md).
USER_AGENT = "oliv-uptime-check/1.0 (+https://github.com/chayapats/oliv)"
TIMEOUT_SECONDS = 20
MAX_BODY_BYTES = 64 * 1024


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def health_url(raw):
    """The URL to check, or None if it isn't a plain http(s) URL with a host."""
    parts = urllib.parse.urlsplit(raw.strip())
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    if parts.username or parts.password or parts.fragment:
        return None
    if parts.path in ("", "/"):
        parts = parts._replace(path="/health")
    return urllib.parse.urlunsplit(parts)


def probe(url, timeout=TIMEOUT_SECONDS):
    """One attempt. Returns (ok, reason); the reason never contains the URL."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=timeout) as response:
            status = response.status
            body = response.read(MAX_BODY_BYTES + 1)
    except urllib.error.HTTPError as error:
        status = error.code
        try:
            body = error.read(MAX_BODY_BYTES + 1)
        except (OSError, http.client.HTTPException):
            body = b""
        finally:
            error.close()
        if 300 <= status < 400:
            return False, f"HTTP {status} redirect; /health should answer directly"
        if status == 403 and b"error code: 1010" in body:
            return False, "HTTP 403 Cloudflare error 1010: the edge refused this client"
        return False, f"HTTP {status}"
    except urllib.error.URLError as error:
        return False, _network_reason(error.reason)
    except (OSError, http.client.HTTPException) as error:
        return False, _network_reason(error)
    if status != 200:
        return False, f"HTTP {status}"
    if len(body) > MAX_BODY_BYTES:
        return False, "HTTP 200 but the body is too large for /health"
    try:
        reply = json.loads(body)
    except ValueError:
        return False, "HTTP 200 but the body is not JSON"
    if not isinstance(reply, dict) or reply.get("ok") is not True:
        return False, 'HTTP 200 but the body lacks "ok": true'
    return True, "HTTP 200, ok"


def _network_reason(error):
    # Fixed phrases only: library messages can name the host (TLS mismatches do).
    if isinstance(error, (socket.timeout, TimeoutError)):
        return "timed out"
    if isinstance(error, socket.gaierror):
        return "the name did not resolve"
    if isinstance(error, ConnectionRefusedError):
        return "connection refused"
    if isinstance(error, ConnectionResetError):
        return "connection reset"
    if isinstance(error, ssl.SSLCertVerificationError):
        return "TLS certificate not trusted"
    if isinstance(error, ssl.SSLError):
        return "TLS handshake failed"
    if isinstance(error, http.client.HTTPException):
        return "malformed HTTP reply"
    if isinstance(error, OSError):
        return "network error"
    return "request failed"


def check(url, retry_delay, timeout=TIMEOUT_SECONDS, log=print, sleep=time.sleep):
    """Two attempts at most. Returns (up, reason of the last attempt)."""
    for attempt in (1, 2):
        started = time.monotonic()
        ok, reason = probe(url, timeout=timeout)
        log(f"Attempt {attempt}: {'up' if ok else 'down'} ({reason}) in {time.monotonic() - started:.2f} s")
        if ok:
            return True, reason
        if attempt == 1:
            log(f"Retrying once in {retry_delay:g} s")
            sleep(retry_delay)
    return False, reason


def _write_outputs(**values):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as outputs:
        for key, value in values.items():
            outputs.write(f"{key}={value}\n")


def main():
    # One stream, in order: the mask must reach the runner before anything else.
    sys.stdout.reconfigure(line_buffering=True)
    in_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    raw = os.environ.get("OLIV_HEALTH_URL", "")
    if not raw.strip():
        message = "OLIV_HEALTH_URL is not set, so there is nothing to check (a fork, or the secret isn't set yet)."
        print(f"::notice title=Uptime check skipped::{message}" if in_actions else message)
        _write_outputs(state="skipped", reason="no OLIV_HEALTH_URL")
        return 0
    url = health_url(raw)
    if in_actions:
        # Secrets are masked whole; the host on its own is not.
        host = urllib.parse.urlsplit(raw.strip()).hostname
        if host:
            print(f"::add-mask::{host}")
    if url is None:
        message = "OLIV_HEALTH_URL must be an http(s) URL with a host and no credentials."
        print(f"::error title=Uptime check misconfigured::{message}" if in_actions else message)
        _write_outputs(state="error", reason="OLIV_HEALTH_URL is not a usable URL")
        return 2
    try:
        retry_delay = float(os.environ.get("OLIV_HEALTH_RETRY_DELAY", "30"))
    except ValueError:
        retry_delay = 30.0
    up, reason = check(url, retry_delay)
    _write_outputs(state="up" if up else "down", reason=reason)
    if up:
        print("The OLIV server is up.")
        return 0
    message = f"/health failed twice, {retry_delay:g} s apart. Last: {reason}."
    print(f"::error title=OLIV server is down::{message}" if in_actions else f"The OLIV server is down: {message}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
