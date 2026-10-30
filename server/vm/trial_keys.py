#!/usr/bin/env python3
"""Public free-trial sign-up, reached through the consumer tunnel at /try.

A separate process from oliv-api, which has no key-management routes, and from
the dashboard, which stays private. It issues short, low-limit keys through the
same oliv-keys authority. Nothing runs until the operator creates trial.json,
and "enabled": false there closes sign-ups at once.

Issuance is bounded per client and for the whole server, so a script can't turn
the page into unlimited GPU time. Client addresses are never stored: the daily
counters hold keyed hashes that can't be linked across days.
"""

import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import stat
import tempfile
import threading
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from dashboard_keys import KeyAdminError, KeyManager

HOST = "127.0.0.1"
PORT = 8091
NAME_PREFIX = "trial-"
SCOPES = ["dictate", "clean"]
PRUNE_AFTER_DAYS = 30
PRUNE_INTERVAL = 6 * 3600
# oliv-keys refuses a 257th key. Stop early so the operator can always add one.
STORE_CEILING = 200
MAX_BODY_BYTES = 1024
MAX_CLIENTS_PER_DAY = 50_000
MAX_WORKERS = 8
SOCKET_TIMEOUT = 5
REQUEST_DEADLINE = 20
CLIENT_HASH = re.compile(r"[0-9a-f]{32}\Z")
DEFAULTS = {"enabled": True, "expires_in_days": 7, "requests_per_minute": 6,
            "daily_requests": 60, "keys_per_client_per_day": 2, "keys_per_day": 30,
            "max_active": 100, "testflight_url": ""}
RANGES = {"expires_in_days": (1, 90), "requests_per_minute": (1, 60),
          "daily_requests": (1, 1000), "keys_per_client_per_day": (1, 20),
          "keys_per_day": (1, 150), "max_active": (1, STORE_CEILING)}
HTTPS_URL = re.compile(r"https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?\Z")


class Closed(Exception):
    """Sign-ups are off or a limit was reached; `code` is stable for clients."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def load_settings(path):
    """Missing or invalid settings close sign-ups instead of using guesses."""
    try:
        posted = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(posted, dict) or set(posted) - set(DEFAULTS):
        return None
    settings = {**DEFAULTS, **posted}
    if type(settings["enabled"]) is not bool or not isinstance(settings["testflight_url"], str):
        return None
    if settings["testflight_url"] and not HTTPS_URL.match(settings["testflight_url"]):
        return None
    for field, (low, high) in RANGES.items():
        if type(settings[field]) is not int or not low <= settings[field] <= high:
            return None
    return settings


class Ledger:
    """Today's issuance counts, kept across restarts in a private file."""

    def __init__(self, path, clock=time.time):
        self.path = Path(path)
        self.clock = clock
        self.state = self._read()

    def _day(self):
        return int(self.clock() // 86_400)

    def _read(self):
        try:
            state = json.loads(self.path.read_text(encoding="utf-8"))
            if self._valid(state):
                return state
        except (OSError, ValueError):
            pass
        # A lost ledger only restarts today's counts; max_active still applies.
        return self._fresh()

    @staticmethod
    def _valid(state):
        def count(value):
            return type(value) is int and value >= 0
        return (isinstance(state, dict) and set(state) == {"day", "salt", "total", "clients"}
                and count(state["day"]) and isinstance(state["salt"], str)
                and re.fullmatch(r"[0-9a-f]{64}", state["salt"]) is not None
                and count(state["total"]) and isinstance(state["clients"], dict)
                and all(CLIENT_HASH.match(client) and count(used)
                        for client, used in state["clients"].items())
                and sum(state["clients"].values()) <= state["total"])

    def _fresh(self):
        return {"day": self._day(), "salt": secrets.token_hex(32), "total": 0, "clients": {}}

    def _roll(self):
        if self.state["day"] != self._day():
            self.state = self._fresh()

    def _client(self, address):
        return hmac.new(bytes.fromhex(self.state["salt"]), address.encode("utf-8"),
                        hashlib.sha256).hexdigest()[:32]

    def check(self, address, settings):
        self._roll()
        if self.state["total"] >= settings["keys_per_day"]:
            raise Closed("daily_limit")
        if (self.state["clients"].get(self._client(address), 0)
                >= settings["keys_per_client_per_day"]):
            raise Closed("client_limit")
        if len(self.state["clients"]) >= MAX_CLIENTS_PER_DAY:
            raise Closed("daily_limit")

    def charge(self, address):
        """Saved before the key exists: a crash afterwards over-counts by one,
        which is safe, while the reverse order could issue uncounted keys.
        Returns the receipt `refund` needs."""
        self._roll()
        client = self._client(address)
        self._adjust(client, 1)
        return self.state["day"], client

    def refund(self, receipt):
        """A count from an earlier day is already gone, and refunding it would
        hand today an extra key."""
        day, client = receipt
        self._roll()
        if self.state["day"] == day:
            self._adjust(client, -1)

    def _adjust(self, client, change):
        state = {**self.state, "total": self.state["total"] + change,
                 "clients": dict(self.state["clients"])}
        state["clients"][client] = state["clients"].get(client, 0) + change
        if state["clients"][client] <= 0:
            del state["clients"][client]
        self._write(state)
        self.state = state

    def _write(self, state):
        fd, name = tempfile.mkstemp(prefix=".trial-ledger-", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as target:
                json.dump(state, target)
            os.replace(name, self.path)
        except BaseException:
            Path(name).unlink(missing_ok=True)
            raise


class TrialIssuer:
    def __init__(self, root, clock=time.time, manager=None):
        self.root = Path(root)
        self.clock = clock
        self.manager = manager or KeyManager(self.root)
        self.settings_path = self.root / "trial.json"
        self.ledger = Ledger(self.root / "trial-ledger.json", clock)
        self.lock = threading.Lock()
        self.last_prune = 0

    def settings(self):
        settings = load_settings(self.settings_path)
        return settings if settings and settings["enabled"] else None

    def _prune(self):
        if self.clock() - self.last_prune < PRUNE_INTERVAL:
            return
        self.manager.cli("prune-trials", str(PRUNE_AFTER_DAYS))
        self.last_prune = self.clock()

    def issue(self, address, expires=float("inf")):
        with self.lock:
            # A client dropped at its deadline must not get a key it never sees.
            if time.monotonic() >= expires:
                raise Closed("expired")
            # Read under the lock: a request that queued behind another must
            # see a kill switch or lowered limit set while it waited.
            settings = self.settings()
            if settings is None:
                raise Closed("closed")
            self.ledger.check(address, settings)
            self._prune()
            keys = self.manager.keys()
            active = sum(key["status"] == "active" and key["trial"] for key in keys)
            if active >= settings["max_active"] or len(keys) >= STORE_CEILING:
                raise Closed("full")
            receipt = self.ledger.charge(address)
            try:
                created = self.manager.create({
                    "name": NAME_PREFIX + secrets.token_hex(6),
                    "expires_in_days": settings["expires_in_days"], "scopes": SCOPES,
                    "requests_per_minute": settings["requests_per_minute"],
                    "daily_requests": settings["daily_requests"]}, trial=True)
            except KeyAdminError as error:
                # "incomplete" means a key may exist, so its count must stand.
                if error.code != "key_creation_incomplete":
                    try:
                        self.ledger.refund(receipt)
                    except OSError:
                        pass  # Over-counting by one is the safe direction.
                raise
        return {"ok": True, "token": created["token"], "expires_at": created["key"]["expires_at"],
                "requests_per_minute": settings["requests_per_minute"],
                "daily_requests": settings["daily_requests"]}


def page_bytes(root):
    return (Path(root) / "trial.html").read_bytes()


def client_address(handler):
    # Only cloudflared reaches this loopback port, and the edge replaces any
    # client-supplied copy of this header.
    value = handler.headers.get("CF-Connecting-IP", "")
    if (0 < len(value) <= 64 and not any(unicodedata.category(c) == "Cc" for c in value)):
        return value
    return handler.client_address[0]


class Handler(BaseHTTPRequestHandler):
    server_version = "oliv-trial"
    sys_version = ""
    timeout = SOCKET_TIMEOUT
    issuer = None

    def log_message(self, *_):
        pass  # Addresses and request details stay out of the log.

    def _send(self, status, body, content_type, csp=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if csp:
            self.send_header("Content-Security-Policy", csp)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, value):
        self._send(status, json.dumps(value).encode("utf-8"), "application/json")

    def do_GET(self):
        if self.path == "/try/health":
            self._json(200, {"ok": True})
        elif self.path in ("/try", "/try/"):
            settings = load_settings(self.issuer.settings_path) or {}
            body = page_bytes(self.issuer.root).replace(
                b"__TESTFLIGHT_URL__", settings.get("testflight_url", "").encode("ascii"))
            # Inline style and script are the page's own, fixed and unparameterised.
            self._send(200, body, "text/html; charset=utf-8",
                       "default-src 'none'; style-src 'unsafe-inline'; "
                       "script-src 'unsafe-inline'; connect-src 'self'; "
                       "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        else:
            self._json(404, {"ok": False, "error": "not_found"})

    def setup(self):
        # Ahead of the server's shutdown, which reads as a normal end of headers.
        self.expires = time.monotonic() + REQUEST_DEADLINE - 1
        super().setup()

    def do_POST(self):
        if time.monotonic() >= self.expires:
            self.close_connection = True
            return
        if self.path != "/try/key":
            self._json(404, {"ok": False, "error": "not_found"})
            return
        # The body is never used, so it's never read: a slow sender can't hold a
        # worker. The connection closes after this one response.
        length = self.headers.get("Content-Length", "0")
        if not length.isdecimal() or len(length) > 6 or int(length) > MAX_BODY_BYTES:
            self._json(413, {"ok": False, "error": "too_large"})
            return
        try:
            self._json(200, self.issuer.issue(client_address(self), self.expires))
        except Closed as closed:
            status = 503 if closed.code in ("closed", "expired") else 429
            self._json(status, {"ok": False, "error": closed.code})
        except (KeyAdminError, OSError):
            self._json(503, {"ok": False, "error": "unavailable"})


class BoundedServer(ThreadingHTTPServer):
    """Refuses at once beyond MAX_WORKERS, rather than queueing without limit."""

    daemon_threads = True

    def __init__(self, *args, **kwargs):
        self.workers = threading.BoundedSemaphore(MAX_WORKERS)
        super().__init__(*args, **kwargs)

    def handle_error(self, request, client_address):
        pass  # The default prints the client's address; a dropped client isn't news.

    def process_request(self, request, client_address):
        if not self.workers.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.workers.release()
            raise

    def process_request_thread(self, request, client_address):
        # SOCKET_TIMEOUT applies per read, so a client trickling headers would
        # otherwise hold a worker for as long as it likes.
        deadline = None
        try:
            deadline = threading.Timer(REQUEST_DEADLINE, self._drop, (request,))
            deadline.daemon = True
            deadline.start()
            super().process_request_thread(request, client_address)
        except RuntimeError:  # No thread available for the timer.
            self.shutdown_request(request)
        finally:
            if deadline:
                deadline.cancel()
            self.workers.release()

    @staticmethod
    def _drop(request):
        try:
            request.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def main():
    root = Path(os.environ.get("OLIV_ROOT", Path.home() / "oliv"))
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise SystemExit("OLIV root must be a directory owned by this user")
    Handler.issuer = TrialIssuer(root)
    BoundedServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
