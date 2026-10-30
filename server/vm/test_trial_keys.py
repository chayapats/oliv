"""Trial limits and HTTP behaviour with a fake key authority; no real keys."""

import http.client
import json
import os
import shutil
import socket
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

import test_dashboard_keys
import trial_keys
from dashboard_keys import KeyAdminError, KeyManager
from trial_keys import Closed, Ledger, TrialIssuer, load_settings


class FakeManager:
    def __init__(self):
        self.created = []
        self.pruned = []
        self.existing = []

    def cli(self, *args):
        self.pruned.append(args)
        return b""

    def keys(self):
        return list(self.existing)

    def create(self, options, trial=False):
        self.created.append(options)
        key = {"id": f"{len(self.created):016x}", "name": options["name"], "status": "active",
               "expires_at": 1_000_000, "trial": trial}
        self.existing.append(key)
        return {"ok": True, "key": key, "token": f"token-{len(self.created)}"}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.now = 100 * 86_400 + 5.0
        self.manager = FakeManager()
        self.settings({"keys_per_client_per_day": 2, "keys_per_day": 3, "max_active": 5})
        self.issuer = TrialIssuer(self.root, clock=lambda: self.now, manager=self.manager)

    def settings(self, value):
        (self.root / "trial.json").write_text(json.dumps(value), encoding="utf-8")


class SettingsTests(Fixture):
    def test_missing_or_invalid_settings_close_sign_ups(self):
        for bad in ({"unknown": 1}, {"enabled": "yes"}, {"daily_requests": 0},
                    {"keys_per_day": 151}, {"daily_requests": True},
                    {"testflight_url": "http://example.com"}):
            self.settings(bad)
            self.assertIsNone(load_settings(self.root / "trial.json"), bad)
        (self.root / "trial.json").unlink()
        self.assertIsNone(load_settings(self.root / "trial.json"))
        with self.assertRaises(Closed) as closed:
            self.issuer.issue("192.0.2.1")
        self.assertEqual(closed.exception.code, "closed")

    def test_kill_switch_applies_without_a_restart(self):
        self.issuer.issue("192.0.2.1")
        self.settings({"enabled": False})
        with self.assertRaises(Closed):
            self.issuer.issue("192.0.2.1")


class IssueTests(Fixture):
    def test_key_is_short_lived_low_limit_and_marked_as_trial(self):
        reply = self.issuer.issue("192.0.2.1")
        options = self.manager.created[0]
        self.assertTrue(options["name"].startswith("trial-"))
        self.assertEqual(options["expires_in_days"], 7)
        self.assertEqual(options["scopes"], ["dictate", "clean"])
        self.assertEqual(options["requests_per_minute"], 6)
        self.assertEqual(reply["daily_requests"], 60)
        self.assertEqual(self.manager.pruned, [("prune-trials", "30")])

    def test_client_and_daily_limits_then_next_day_reopens(self):
        self.issuer.issue("192.0.2.1")
        self.issuer.issue("192.0.2.1")
        with self.assertRaises(Closed) as closed:
            self.issuer.issue("192.0.2.1")
        self.assertEqual(closed.exception.code, "client_limit")
        self.issuer.issue("192.0.2.2")
        with self.assertRaises(Closed) as closed:
            self.issuer.issue("192.0.2.3")
        self.assertEqual(closed.exception.code, "daily_limit")
        self.now += 86_400
        self.issuer.issue("192.0.2.3")

    def test_limits_survive_a_restart(self):
        self.issuer.issue("192.0.2.1")
        self.issuer.issue("192.0.2.1")
        restarted = TrialIssuer(self.root, clock=lambda: self.now, manager=self.manager)
        with self.assertRaises(Closed):
            restarted.issue("192.0.2.1")

    def test_active_trials_and_store_ceiling_stop_issuing(self):
        self.manager.existing = [{"name": f"guest-{n}", "status": "active", "trial": True} for n in range(5)]
        with self.assertRaises(Closed) as closed:
            self.issuer.issue("192.0.2.1")
        self.assertEqual(closed.exception.code, "full")
        self.manager.existing = [{"name": "operator", "status": "revoked", "trial": False}] * trial_keys.STORE_CEILING
        with self.assertRaises(Closed):
            self.issuer.issue("192.0.2.1")
        self.assertEqual(self.manager.created, [])

    def test_failed_creation_charges_nothing(self):
        def fail(*_, **__):
            raise KeyAdminError(503, "x", "x")
        self.manager.create = fail
        with self.assertRaises(KeyAdminError):
            self.issuer.issue("192.0.2.1")
        self.assertEqual(self.issuer.ledger.state["total"], 0)

    def test_operator_keys_named_like_trials_do_not_count(self):
        self.manager.existing = [{"name": f"trial-{n}", "status": "active", "trial": False} for n in range(5)]
        self.issuer.issue("192.0.2.1")
        self.assertEqual(len(self.manager.created), 1)

    def test_unsaved_ledger_issues_no_key(self):
        def fail(_):
            raise OSError("disk full")
        self.issuer.ledger._write = fail
        with self.assertRaises(OSError):
            self.issuer.issue("192.0.2.1")
        self.assertEqual(self.manager.created, [])
        self.assertEqual(self.issuer.ledger.state["total"], 0)

    def test_queued_request_sees_a_kill_switch_set_while_it_waited(self):
        results = []

        def request():
            try:
                results.append(self.issuer.issue("192.0.2.1"))
            except Closed as closed:
                results.append(closed.code)

        with self.issuer.lock:
            waiting = threading.Thread(target=request)
            waiting.start()
            self.settings({"enabled": False})
        waiting.join(5)
        self.assertEqual(results, ["closed"])
        self.assertEqual(self.manager.created, [])

    def test_ledger_stores_no_addresses_and_is_private(self):
        self.issuer.issue("192.0.2.1")
        path = self.root / "trial-ledger.json"
        self.assertNotIn("192.0.2.1", path.read_text(encoding="utf-8"))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_corrupt_ledger_starts_a_new_day_of_counts(self):
        path = self.root / "trial-ledger.json"
        path.write_text("{", encoding="utf-8")
        self.assertEqual(Ledger(path, lambda: self.now).state["total"], 0)
        day = int(self.now // 86_400)
        salt = "a" * 64
        for total, clients in ((-7, {}), (1, {"b" * 32: "x"}), (1, {"not-a-hash": 1}),
                               (0, {"b" * 32: 1}), (True, {})):
            path.write_text(json.dumps({"day": day, "salt": salt, "total": total, "clients": clients}),
                            encoding="utf-8")
            self.assertEqual(Ledger(path, lambda: self.now).state["clients"], {}, (total, clients))


class RealCLITests(unittest.TestCase):
    """The trial path through the real oliv-keys, on a throwaway store."""

    def test_issued_key_is_listed_and_pruned_only_after_it_finishes(self):
        binary = test_dashboard_keys.key_binary()
        if binary is None:
            self.skipTest("build oliv-api oliv-keys first (required in CI)")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "bin").mkdir(mode=0o700)
            shutil.copy2(binary, root / "bin/oliv-keys")
            os.chmod(root, 0o700)
            manager = KeyManager(root)
            manager.cli("init")
            (root / "trial.json").write_text("{}", encoding="utf-8")
            reply = TrialIssuer(root).issue("192.0.2.1")
            self.assertTrue(reply["token"].startswith("oliv_"))
            key = manager.keys()[0]
            self.assertTrue(key["trial"])
            self.assertEqual(key["scopes"], ["dictate", "clean"])
            self.assertEqual(key["daily_requests"], 60)
            manager.cli("prune-trials", "30")
            self.assertEqual(len(manager.keys()), 1)
            manager.cli("revoke", key["id"])
            manager.cli("prune-trials", "30")
            self.assertEqual(manager.keys(), [])


class OverloadTests(Fixture):
    def test_requests_beyond_the_worker_limit_are_refused_immediately(self):
        release = threading.Event()

        class Slow(trial_keys.Handler):
            issuer = self.issuer

            def do_GET(self):
                release.wait(5)
                super().do_GET()

        server = trial_keys.BoundedServer(("127.0.0.1", 0), Slow)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.addCleanup(release.set)
        held = []
        for _ in range(trial_keys.MAX_WORKERS):
            connection = socket.create_connection(("127.0.0.1", server.server_port), timeout=5)
            connection.sendall(b"GET /try/health HTTP/1.0\r\n\r\n")
            held.append(connection)
            self.addCleanup(connection.close)
        deadline = time.monotonic() + 3
        while server.workers._value and time.monotonic() < deadline:
            time.sleep(0.01)
        refused = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
        self.addCleanup(refused.close)
        refused.request("GET", "/try/health")
        self.assertEqual(refused.getresponse().status, 503)


class HTTPTests(Fixture):
    def setUp(self):
        super().setUp()
        (self.root / "trial.html").write_text(
            '<a href="__TESTFLIGHT_URL__">x</a>', encoding="utf-8")
        self.settings({"testflight_url": "https://testflight.apple.com/join/example"})

        class Bound(trial_keys.Handler):
            issuer = self.issuer

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Bound)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        self.addCleanup(connection.close)
        connection.request(method, path, body, headers or {})
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()

    def test_page_fills_the_install_link_and_is_locked_down(self):
        status, headers, body = self.request("GET", "/try")
        self.assertEqual(status, 200)
        self.assertIn(b"https://testflight.apple.com/join/example", body)
        self.assertIn("default-src 'none'", headers["Content-Security-Policy"])
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_key_route_uses_the_edge_address_for_limits(self):
        for _ in range(2):
            status, headers, body = self.request("POST", "/try/key", headers={"CF-Connecting-IP": "192.0.2.9"})
            self.assertEqual(status, 200)
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertIn("token", json.loads(body))
        status, _, body = self.request("POST", "/try/key", headers={"CF-Connecting-IP": "192.0.2.9"})
        self.assertEqual((status, json.loads(body)["error"]), (429, "client_limit"))
        self.assertEqual(self.request("POST", "/try/key", headers={"CF-Connecting-IP": "192.0.2.10"})[0], 200)

    def test_closed_oversized_and_unknown_routes_never_issue(self):
        self.assertEqual(self.request("POST", "/try/key", headers={"Content-Length": "2000"}, body=b"x" * 2000)[0], 413)
        for length in ("9" * 5000, "abc", "-1"):
            self.assertEqual(self.request("POST", "/try/key", headers={"Content-Length": length})[0], 413)
        self.assertEqual(self.request("POST", "/try/other")[0], 404)
        self.assertEqual(self.request("GET", "/try/key")[0], 404)
        self.settings({"enabled": False})
        self.assertEqual(self.request("POST", "/try/key")[0], 503)
        self.assertEqual(self.manager.created, [])


if __name__ == "__main__":
    unittest.main()
