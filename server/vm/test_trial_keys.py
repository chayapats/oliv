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
from unittest.mock import patch

import test_dashboard_keys
import trial_keys
from dashboard_keys import KeyAdminError, KeyManager
from trial_keys import DEFAULTS, Closed, Ledger, TrialIssuer, load_settings


class FakeManager:
    def __init__(self):
        self.created = []
        self.pruned = []
        self.existing = []
        self.revoked = []

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

    def revoke(self, posted):
        self.revoked.append(posted["id"])


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
        self.assertEqual(self.manager.pruned, [("prune-trials", "1")])

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

    def test_failure_across_midnight_refunds_nothing_from_the_new_day(self):
        def fail(*_, **__):
            self.now += 86_400
            raise KeyAdminError(503, "x", "x")
        self.issuer.issue("192.0.2.1")
        self.manager.create = fail
        with self.assertRaises(KeyAdminError):
            self.issuer.issue("192.0.2.2")
        self.assertEqual(self.issuer.ledger.state["total"], 0)
        self.assertEqual(self.issuer.ledger.state["clients"], {})

    def test_uncertain_creation_keeps_its_count(self):
        def fail(*_, **__):
            raise KeyAdminError(503, "key_creation_incomplete", "x")
        self.manager.create = fail
        with self.assertRaises(KeyAdminError):
            self.issuer.issue("192.0.2.1")
        self.assertEqual(self.issuer.ledger.state["total"], 1)

    def test_refund_that_cannot_be_saved_keeps_the_original_error(self):
        def fail(*_, **__):
            self.issuer.ledger._write = refuse
            raise KeyAdminError(503, "x", "x")

        def refuse(_):
            raise OSError("disk full")
        self.manager.create = fail
        with self.assertRaises(KeyAdminError):
            self.issuer.issue("192.0.2.1")
        self.assertEqual(self.issuer.ledger.state["total"], 1)

    def test_request_past_its_deadline_gets_no_key(self):
        with self.assertRaises(Closed) as closed:
            self.issuer.issue("192.0.2.1", expires=time.monotonic() - 1)
        self.assertEqual(closed.exception.code, "expired")
        self.assertEqual(self.manager.created, [])
        self.assertEqual(self.issuer.ledger.state["total"], 0)

    def test_time_running_out_before_creation_charges_nothing(self):
        listed = self.manager.keys
        def slow():
            time.sleep(0.02)
            return listed()
        self.manager.keys = slow
        with self.assertRaises(Closed) as closed:
            self.issuer.issue("192.0.2.1", expires=time.monotonic() + 0.01)
        self.assertEqual(closed.exception.code, "expired")
        self.assertEqual(self.manager.created, [])
        self.assertEqual(self.issuer.ledger.state["total"], 0)

    def _create_outlasting_the_deadline(self):
        create = self.manager.create
        def slow(options, trial=False):
            time.sleep(0.02)
            return create(options, trial)
        self.manager.create = slow

    def test_key_finished_after_the_client_left_is_revoked_and_refunded(self):
        self._create_outlasting_the_deadline()
        with self.assertRaises(Closed) as closed:
            self.issuer.issue("192.0.2.1", expires=time.monotonic() + 0.01)
        self.assertEqual(closed.exception.code, "expired")
        self.assertEqual(self.manager.revoked, [self.manager.existing[0]["id"]])
        self.assertEqual(self.issuer.ledger.state["total"], 0)

    def test_failed_revoke_keeps_the_count(self):
        self._create_outlasting_the_deadline()
        def fail(_):
            raise KeyAdminError(503, "x", "x")
        self.manager.revoke = fail
        with self.assertRaises(KeyAdminError):
            self.issuer.issue("192.0.2.1", expires=time.monotonic() + 0.01)
        self.assertEqual(self.issuer.ledger.state["total"], 1)

    def test_ended_trials_cannot_fill_the_store_at_the_default_limits(self):
        days_kept = trial_keys.PRUNE_AFTER_DAYS + trial_keys.PRUNE_INTERVAL / 86_400
        ended = trial_keys.DEFAULTS["keys_per_day"] * days_kept
        self.assertLess(trial_keys.DEFAULTS["max_active"] + ended, trial_keys.STORE_CEILING)

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

    def test_a_damaged_ledger_refuses_today_instead_of_resetting_it(self):
        path = self.root / "trial-ledger.json"
        day = int(self.now // 86_400)
        salt = "a" * 64
        states = ["{"] + [json.dumps({"day": day, "salt": salt, "total": total, "clients": clients})
                          for total, clients in ((-7, {}), (1, {"b" * 32: "x"}), (1, {"not-a-hash": 1}),
                                                 (0, {"b" * 32: 1}), (True, {}))]
        for state in states:
            path.write_text(state, encoding="utf-8")
            os.utime(path, (self.now, self.now))
            ledger = Ledger(path, lambda: self.now)
            with self.assertRaises(OSError):
                ledger.check("192.0.2.1", DEFAULTS)
            with self.assertRaises(OSError):
                ledger.charge("192.0.2.1")
            self.assertEqual(path.read_text(encoding="utf-8"), state, "kept for the operator")

    def test_a_damaged_ledger_heals_once_its_day_is_over(self):
        path = self.root / "trial-ledger.json"
        path.write_text("{", encoding="utf-8")
        os.utime(path, (self.now - 86_400, self.now - 86_400))
        ledger = Ledger(path, lambda: self.now)
        ledger.check("192.0.2.1", DEFAULTS)
        ledger.charge("192.0.2.1")
        self.assertEqual(Ledger(path, lambda: self.now).state["total"], 1)

    def test_repairing_a_damaged_ledger_needs_no_restart(self):
        path = self.root / "trial-ledger.json"
        path.write_text("{", encoding="utf-8")
        os.utime(path, (self.now, self.now))
        ledger = Ledger(path, lambda: self.now)
        path.unlink()
        ledger.check("192.0.2.1", DEFAULTS)


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
            manager.cli("prune-trials", str(trial_keys.PRUNE_AFTER_DAYS))
            self.assertEqual(len(manager.keys()), 1)
            manager.cli("revoke", key["id"])
            manager.cli("prune-trials", str(trial_keys.PRUNE_AFTER_DAYS))
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


class OverloadRecoveryTests(Fixture):
    def _server(self):
        class Bound(trial_keys.Handler):
            issuer = self.issuer
        server = trial_keys.BoundedServer(("127.0.0.1", 0), Bound)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def test_client_trickling_headers_loses_its_worker_at_the_deadline(self):
        server = self._server()
        with patch.object(trial_keys, "REQUEST_DEADLINE", 0.3), patch.object(trial_keys.Handler, "timeout", 5):
            connection = socket.create_connection(("127.0.0.1", server.server_port), timeout=3)
            self.addCleanup(connection.close)
            connection.sendall(b"GET /try/health HTTP/1.0\r\n")
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    connection.sendall(b"X-Slow: 1\r\n")
                except OSError:
                    break
                if server.workers._value == trial_keys.MAX_WORKERS:
                    break
                time.sleep(0.05)
        self.assertEqual(server.workers._value, trial_keys.MAX_WORKERS)

    def test_truncated_post_past_its_deadline_issues_nothing(self):
        server = self._server()
        with patch.object(trial_keys, "REQUEST_DEADLINE", 1.2):
            connection = socket.create_connection(("127.0.0.1", server.server_port), timeout=3)
            self.addCleanup(connection.close)
            connection.sendall(b"POST /try/key HTTP/1.0\r\nX-Partial: 1\r\n")
            deadline = time.monotonic() + 3
            # First until the server takes it, or this would end before it began.
            while server.workers._value == trial_keys.MAX_WORKERS and time.monotonic() < deadline:
                time.sleep(0.01)
            while server.workers._value != trial_keys.MAX_WORKERS and time.monotonic() < deadline:
                time.sleep(0.05)
        self.assertEqual(self.manager.created, [])

    def test_timer_failure_returns_the_worker(self):
        server = self._server()
        server.workers.acquire()
        first, second = socket.socketpair()
        self.addCleanup(second.close)
        with patch.object(trial_keys.threading, "Timer", side_effect=RuntimeError):
            server.process_request_thread(first, ("127.0.0.1", 1))
        self.assertEqual(server.workers._value, trial_keys.MAX_WORKERS)

    def test_thread_start_failure_returns_the_worker(self):
        server = self._server()
        with patch.object(trial_keys.ThreadingHTTPServer, "process_request", side_effect=RuntimeError):
            with self.assertRaises(RuntimeError):
                server.process_request(*socket.socketpair()[:1], ("127.0.0.1", 1))
        self.assertEqual(server.workers._value, trial_keys.MAX_WORKERS)


class HTTPTests(Fixture):
    def setUp(self):
        super().setUp()
        (self.root / "trial.html").write_text(
            '<p>__TRIAL_DAYS__</p><a href="__TESTFLIGHT_URL__">x</a>', encoding="utf-8")
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
        self.assertIn(b"<p>7</p>", body, "the offer the server is really configured with")
        self.assertIn("default-src 'none'", headers["Content-Security-Policy"])
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_desktop_steps_name_this_server_without_it_being_in_the_source(self):
        page = (Path(trial_keys.__file__).parent / "trial.html").read_text(encoding="utf-8")
        self.assertIn("location.origin", page)
        self.assertIn("config.toml", page)

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
