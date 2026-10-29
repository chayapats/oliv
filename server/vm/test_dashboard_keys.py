"""Real offline CLI and loopback admin HTTP; never production keys or services."""

import contextlib
import hashlib
import http.client
import io
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import dashboard
from dashboard_keys import KeyAdminError, KeyManager, safe_info, unavailable, validate_options


def key_binary():
    override = os.environ.get("OLIV_KEYS_TEST_BIN")
    target = Path(__file__).parents[1] / "oliv-api/target"
    paths = [Path(override)] if override else [target / "debug/oliv-keys",
                                               target / "release/oliv-keys",
                                               target / "x86_64-unknown-linux-musl/release/oliv-keys"]
    return next((path for path in paths if path.is_file() and os.access(path, os.X_OK)), None)


class KeyFixture(unittest.TestCase):
    def setUp(self):
        binary = key_binary()
        if binary is None:
            if os.environ.get("CI") or os.environ.get("OLIV_KEYS_TEST_BIN"):
                self.fail("Build oliv-keys before the dashboard CLI lifecycle tests")
            self.skipTest("build oliv-api oliv-keys first (required in CI)")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "bin").mkdir(mode=0o700)
        destination = self.root / "bin/oliv-keys"
        try:
            os.link(binary, destination)
        except OSError:
            shutil.copy2(binary, destination)
        subprocess.run([str(destination), "--root", str(self.root), "init"],
                       capture_output=True, check=True, timeout=10)
        self.manager = KeyManager(self.root)

    def assert_no_export(self):
        self.assertEqual(list(self.root.glob(".dashboard-key-*")), [])


class KeyLifecycleTests(KeyFixture):
    def test_create_lists_only_safe_metadata_and_revoke_is_immediate(self):
        result = self.manager.create({"name": "เครื่องผู้ใช้ ' ; $(do-not-run)"})
        self.assertEqual(result["key"]["status"], "active")
        self.assertEqual(result["key"]["scopes"], ["dictate"])
        self.assertEqual(result["key"]["expires_at"] - result["key"]["created_at"], 90 * 86400)
        stored = json.loads((self.root / "api-keys.json").read_text())
        self.assertEqual(stored["keys"][0]["sha256"], hashlib.sha256(result["token"].encode()).hexdigest())
        listed = self.manager.listing()
        self.assertNotIn(result["token"], json.dumps(listed))
        self.assertNotIn("sha256", json.dumps(listed))
        self.assertFalse(listed["usage_available"])
        self.assertEqual(listed["summary"], {"total": 1, "active": 1, "expired": 0, "revoked": 0})
        revoked = self.manager.revoke({"id": result["key"]["id"]})
        self.assertEqual(revoked["key"]["status"], "revoked")
        self.assertEqual(self.manager.revoke({"id": result["key"]["id"]}), revoked)
        self.assertEqual(self.manager.listing()["summary"]["revoked"], 1)
        self.assert_no_export()

    def test_expiry_and_revocation_counts_are_disjoint(self):
        for name in ("active", "expired", "revoked"):
            self.manager.create({"name": name, "scopes": ["clean", "status"],
                                 "expires_in_days": 1, "requests_per_minute": 3, "daily_requests": 7})
        path = self.root / "api-keys.json"
        stored = json.loads(path.read_text())
        for record in stored["keys"][1:]:
            record["info"].update(created_at=int(time.time()) - 100, expires_at=int(time.time()) - 1)
        stored["keys"][2]["info"]["revoked"] = True
        path.write_text(json.dumps(stored))
        result = self.manager.listing()
        self.assertEqual(result["summary"], {"total": 3, "active": 1, "expired": 1, "revoked": 1})
        self.assertEqual([key["status"] for key in result["keys"]], ["active", "expired", "revoked"])
        self.assert_no_export()

    def test_metadata_failure_after_creation_revokes_and_removes_export(self):
        with patch.object(self.manager, "keys", side_effect=[[], unavailable()]):
            with self.assertRaises(KeyAdminError):
                self.manager.create({"name": "undelivered"})
        self.assertEqual([key["status"] for key in self.manager.keys()], ["revoked"])
        self.assert_no_export()

    def test_uncertain_cli_result_recovers_only_its_export_id_and_revokes(self):
        actual_cli = self.manager.cli

        def interrupted(*args):
            result = actual_cli(*args)
            if args[0] == "create":
                raise unavailable()  # Commit succeeded but caller did not receive stdout.
            return result

        with patch.object(self.manager, "cli", side_effect=interrupted):
            with self.assertRaises(KeyAdminError):
                self.manager.create({"name": "interrupted"})
        self.assertEqual([key["status"] for key in self.manager.keys()], ["revoked"])
        self.assert_no_export()

    def test_corrupt_store_and_cli_errors_are_redacted(self):
        (self.root / "api-keys.json").write_text("synthetic-private-value-not-json")
        with self.assertRaises(KeyAdminError) as caught:
            self.manager.listing()
        self.assertEqual(caught.exception.status, 503)
        self.assertNotIn("synthetic-private", str(caught.exception))
        with patch("dashboard_keys.subprocess.run", return_value=subprocess.CompletedProcess(
                [], 1, stdout=b"synthetic-secret", stderr=b"synthetic-secret")):
            with self.assertRaises(KeyAdminError) as caught:
                self.manager.cli("list")
        self.assertNotIn("synthetic-secret", str(caught.exception))


class ValidationTests(unittest.TestCase):
    def test_invalid_fields_bounds_scopes_and_names_fail_before_cli(self):
        cases = [None, [], {}, {"name": "x", "unknown": 1}, {"name": " "},
                 {"name": "a\nb"}, {"name": "ก" * 41}, {"name": "\ud800"},
                 {"name": "x", "scopes": []}, {"name": "x", "scopes": ["dictate", "dictate"]},
                 {"name": "x", "scopes": ["admin"]}, {"name": "x", "scopes": [1]},
                 {"name": "x", "expires_in_days": True}, {"name": "x", "expires_in_days": 3651},
                 {"name": "x", "requests_per_minute": 0}, {"name": "x", "daily_requests": 1000001}]
        with patch("dashboard_keys.subprocess.run") as run:
            for posted in cases:
                with self.subTest(posted=posted), self.assertRaises(KeyAdminError) as caught:
                    validate_options(posted)
                self.assertEqual(caught.exception.status, 400)
            run.assert_not_called()
        self.assertEqual(validate_options({"name": "ก" * 40})["expires_in_days"], 90)

    def test_metadata_projection_never_returns_unexpected_secret_fields(self):
        info = {"id": "0" * 16, "name": "test", "created_at": 1, "expires_at": 100,
                "revoked": False, "scopes": ["dictate"], "requests_per_minute": 10,
                "daily_requests": 500, "sha256": "synthetic-hash", "token": "synthetic-secret"}
        clean = safe_info(info, 100)
        self.assertEqual(clean["status"], "expired")
        self.assertNotIn("sha256", clean)
        self.assertNotIn("token", clean)


class KeyHttpFixture(KeyFixture):
    def setUp(self):
        super().setUp()
        self.root_patch = patch.object(dashboard, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.output = io.StringIO()
        self.capture = contextlib.redirect_stdout(self.output)
        self.capture.__enter__()
        self.addCleanup(self.capture.__exit__, None, None, None)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), dashboard.Handler)
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)

    def request(self, method, path, data=None, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        try:
            connection.request(method, path, body=json.dumps(data) if data is not None else None,
                               headers=headers or {})
            response = connection.getresponse()
            return response.status, json.loads(response.read()), dict(response.getheaders())
        finally:
            connection.close()


class KeyHttpTests(KeyHttpFixture):
    def test_real_http_lifecycle_marker_and_no_store_without_secret_logs(self):
        headers = {"X-OLIV-Admin": "1", "Content-Type": "application/json"}
        status, created, response_headers = self.request("POST", "/api/keys/create", {"name": "HTTP alice"}, headers)
        self.assertEqual(status, 201)
        self.assertEqual(response_headers["Cache-Control"], "no-store")
        self.assertEqual(response_headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(response_headers["Referrer-Policy"], "no-referrer")
        self.assertEqual(response_headers["X-Frame-Options"], "DENY")
        token = created["token"]
        status, listed, _ = self.request("GET", "/api/keys")
        self.assertEqual(status, 200)
        self.assertNotIn(token, json.dumps(listed))
        status, rejected, _ = self.request("GET", "/api/keys?token=" + token)
        self.assertEqual(status, 400)
        self.assertNotIn(token, json.dumps(rejected))
        status, revoked, _ = self.request("POST", "/api/keys/revoke", {"id": created["key"]["id"]}, headers)
        self.assertEqual(status, 200)
        self.assertEqual(revoked["key"]["status"], "revoked")
        self.assertNotIn(token, self.output.getvalue())
        self.assertNotIn("HTTP alice", self.output.getvalue())
        self.assert_no_export()

    def test_bad_headers_reject_before_waiting_for_body_or_running_cli(self):
        cases = [("", 403), ("X-OLIV-Admin: 1\r\nX-OLIV-Admin: 1\r\n", 403),
                 ("X-OLIV-Admin: 1\r\nContent-Type: text/plain\r\n", 415),
                 ("X-OLIV-Admin: 1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n", 400)]
        with patch("dashboard_keys.subprocess.run") as run:
            for headers, expected in cases:
                with socket.create_connection(self.server.server_address, timeout=1) as stream:
                    stream.sendall(("POST /api/keys/create HTTP/1.1\r\nHost: local\r\n" + headers +
                                    "Content-Length: 100\r\n\r\n").encode())
                    response = http.client.HTTPResponse(stream)
                    response.begin()
                    self.assertEqual(response.status, expected)
                    response.read()
            run.assert_not_called()

    def test_json_unknown_fields_busy_and_lock_open_failure_do_not_mutate_keys(self):
        headers = {"X-OLIV-Admin": "1", "Content-Type": "application/json"}
        for posted in ({"name": "x", "token": "do-not-accept"}, [], {"name": "\ud800"}):
            self.assertEqual(self.request("POST", "/api/keys/create", posted, headers)[0], 400)
        dashboard.ACTION.acquire()
        try:
            self.assertEqual(self.request("POST", "/api/keys/create", {"name": "busy"}, headers)[0], 409)
        finally:
            dashboard.ACTION.release()
        with patch.object(dashboard.os, "open", side_effect=PermissionError):
            self.assertEqual(self.request("POST", "/api/keys/create", {"name": "blocked"}, headers)[0], 503)
        self.assertTrue(dashboard.ACTION.acquire(blocking=False))
        dashboard.ACTION.release()
        self.assertEqual(self.manager.keys(), [])

    def test_duplicate_deep_json_oversized_length_and_stalled_body_fail_safely(self):
        prefix = ("POST /api/keys/create HTTP/1.1\r\nHost: local\r\n"
                  "X-OLIV-Admin: 1\r\nContent-Type: application/json\r\n")
        bodies = [b'{"name":"first","name":"second"}', b"[" * 1400 + b"]" * 1400]
        requests = [(prefix + f"Content-Length: {len(body)}\r\n\r\n", body, 400)
                    for body in bodies]
        requests += [(prefix + "Content-Length: " + "9" * 5000 + "\r\n\r\n", b"", 413),
                     (prefix + "Content-Length: 100\r\n\r\n", b"{", 408)]
        with patch.object(dashboard, "KEY_BODY_TIMEOUT", 0.05), \
             patch("dashboard_keys.subprocess.run") as run:
            for headers, body, expected in requests:
                with socket.create_connection(self.server.server_address, timeout=1) as stream:
                    stream.sendall(headers.encode() + body)
                    response = http.client.HTTPResponse(stream)
                    response.begin()
                    self.assertEqual(response.status, expected)
                    self.assertEqual(json.loads(response.read())["ok"], False)
            run.assert_not_called()
        self.assertEqual(self.manager.keys(), [])

    def failed_create_response(self, rollback_fails=False):
        codes, tokens, lock_states = [], [], []
        original_send = dashboard.Handler.send_json
        original_revoke = KeyManager.revoke

        def broken_send(handler, code, payload):
            codes.append(code)
            if code == 201:
                lock_states.append(dashboard.ACTION.locked())
                tokens.append(payload["token"])
                handler.wfile.write(b"HTTP/1.1 201 Created\r\n")
                raise BrokenPipeError("synthetic-private-write-diagnostic")
            return original_send(handler, code, payload)

        def revoke(manager, posted):
            lock_states.append(dashboard.ACTION.locked())
            if rollback_fails:
                raise KeyAdminError(503, "synthetic", "synthetic-private-revoke-diagnostic")
            return original_revoke(manager, posted)

        body = b'{"name":"undelivered HTTP key"}'
        with patch.object(dashboard.Handler, "send_json", broken_send), \
             patch.object(KeyManager, "revoke", revoke):
            with socket.create_connection(self.server.server_address, timeout=2) as stream:
                stream.sendall(("POST /api/keys/create HTTP/1.1\r\nHost: local\r\n"
                                "X-OLIV-Admin: 1\r\nContent-Type: application/json\r\n"
                                f"Content-Length: {len(body)}\r\n\r\n").encode() + body)
                response = b""
                while chunk := stream.recv(4096):
                    response += chunk
        self.assertEqual(codes, [201], "must not append a503 after a partial201")
        self.assertEqual(lock_states, [True, True])
        self.assertEqual(response, b"HTTP/1.1 201 Created\r\n")
        self.assertNotIn(tokens[0], self.output.getvalue())
        self.assertNotIn("synthetic-private", self.output.getvalue())
        self.assertNotIn("undelivered HTTP key", self.output.getvalue())
        self.assert_no_export()
        self.assertTrue(dashboard.ACTION.acquire(blocking=False))
        dashboard.ACTION.release()

    def test_broken_creation_response_revokes_only_new_key_without_second_response(self):
        kept = self.manager.create({"name": "keep existing key"})["key"]["id"]
        self.failed_create_response()
        states = {key["id"]: key["status"] for key in self.manager.keys()}
        self.assertEqual(states.pop(kept), "active")
        self.assertEqual(list(states.values()), ["revoked"])
        self.assertIn("new key revoked", self.output.getvalue())

    def test_failed_delivery_and_failed_rollback_log_only_manual_revocation_guidance(self):
        self.failed_create_response(rollback_fails=True)
        self.assertEqual([key["status"] for key in self.manager.keys()], ["active"])
        self.assertIn("inspect recent keys and revoke before retrying", self.output.getvalue())


if __name__ == "__main__":
    unittest.main()
