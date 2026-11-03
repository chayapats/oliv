"""Tests for uptime_check.py against local servers. No network beyond loopback."""
import importlib.util
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("uptime_check.py")
spec = importlib.util.spec_from_file_location("uptime_check", SCRIPT)
uptime_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uptime_check)


class _Server:
    """Answers each GET with the next scripted reply; the last one repeats."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.requests = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append((self.path, self.headers.get("User-Agent")))
                status, body, headers, delay = owner.replies[min(len(owner.requests), len(owner.replies)) - 1]
                time.sleep(delay)
                try:
                    self.send_response(status)
                    for name, value in headers.items():
                        self.send_header(name, value)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # The client gave up first (the timeout test).

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self, path="/health", host="localhost"):
        return f"http://{host}:{self.port}{path}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def reply(status=200, body=b'{"ok":true}', headers=None, delay=0):
    return status, body, headers or {"Content-Type": "application/json"}, delay


HEALTHY = reply()


def closed_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class UptimeCheckTests(unittest.TestCase):
    def serve(self, *replies):
        server = _Server(*replies)
        self.addCleanup(server.close)
        return server

    def run_check(self, url, actions=False):
        with tempfile.TemporaryDirectory() as folder:
            outputs = Path(folder, "outputs")
            outputs.touch()
            env = {"PATH": os.environ.get("PATH", ""), "OLIV_HEALTH_RETRY_DELAY": "0",
                   "NO_PROXY": "*", "no_proxy": "*"}
            if url is not None:
                env["OLIV_HEALTH_URL"] = url
            if actions:
                env.update(GITHUB_ACTIONS="true", GITHUB_OUTPUT=str(outputs))
            done = subprocess.run([sys.executable, "-I", str(SCRIPT)], env=env, capture_output=True,
                                  text=True, timeout=60)
            values = dict(line.split("=", 1) for line in outputs.read_text().splitlines())
        return done.returncode, done.stdout + done.stderr, values

    def test_healthy_server_is_up(self):
        server = self.serve(HEALTHY)
        code, output, values = self.run_check(server.url(), actions=True)
        self.assertEqual(code, 0, output)
        self.assertEqual(values, {"state": "up", "reason": "HTTP 200, ok"})
        self.assertEqual(len(server.requests), 1)

    def test_failing_server_is_down_after_one_retry(self):
        server = self.serve(reply(503, b"busy"))
        code, output, values = self.run_check(server.url(), actions=True)
        self.assertEqual(code, 1, output)
        self.assertEqual(values, {"state": "down", "reason": "HTTP 503"})
        self.assertEqual(len(server.requests), 2)
        self.assertIn("::error title=OLIV server is down::", output)

    def test_one_failure_then_success_is_up(self):
        server = self.serve(reply(502, b"bad gateway"), HEALTHY)
        code, output, values = self.run_check(server.url(), actions=True)
        self.assertEqual(code, 0, output)
        self.assertEqual(values["state"], "up")
        self.assertEqual(len(server.requests), 2)

    def test_closed_port_is_down(self):
        code, output, values = self.run_check(f"http://localhost:{closed_port()}/health", actions=True)
        self.assertEqual(code, 1, output)
        self.assertEqual(values, {"state": "down", "reason": "connection refused"})

    def test_answer_without_ok_true_is_down(self):
        for body in (b'{"ok":false}', b"<html>challenge</html>", b'["ok"]'):
            with self.subTest(body=body):
                server = self.serve(reply(body=body))
                self.assertEqual(self.run_check(server.url())[0], 1)

    def test_cloudflare_refusal_is_named(self):
        server = self.serve(reply(403, b"error code: 1010", {"Content-Type": "text/plain"}))
        ok, reason = uptime_check.probe(server.url())
        self.assertFalse(ok)
        self.assertIn("1010", reason)

    def test_redirect_is_not_followed(self):
        target = self.serve(HEALTHY)
        server = self.serve(reply(302, b"", {"Location": target.url()}))
        ok, reason = uptime_check.probe(server.url())
        self.assertFalse(ok)
        self.assertIn("302", reason)
        self.assertEqual(target.requests, [])

    def test_slow_server_times_out(self):
        server = self.serve(reply(delay=1.5))
        self.assertEqual(uptime_check.probe(server.url(), timeout=0.3), (False, "timed out"))

    def test_sends_its_own_user_agent(self):
        server = self.serve(HEALTHY)
        self.assertEqual(self.run_check(server.url())[0], 0)
        agent = server.requests[0][1]
        self.assertEqual(agent, uptime_check.USER_AGENT)
        self.assertNotIn("Python-urllib", agent)

    def test_base_url_checks_health(self):
        server = self.serve(HEALTHY)
        for url in (server.url(path=""), server.url(path="/")):
            with self.subTest(url=url):
                self.assertEqual(self.run_check(url)[0], 0)
        self.assertEqual([path for path, _ in server.requests], ["/health", "/health"])

    def test_missing_url_skips_with_a_notice(self):
        for url in (None, "", "  "):
            with self.subTest(url=url):
                code, output, values = self.run_check(url, actions=True)
                self.assertEqual(code, 0, output)
                self.assertEqual(values["state"], "skipped")
                self.assertIn("::notice", output)

    def test_unusable_url_is_an_error_not_an_outage(self):
        for url in ("ftp://localhost/health", "localhost/health", "https://user:pw@localhost/health"):
            with self.subTest(url=url):
                code, _, values = self.run_check(url, actions=True)
                self.assertEqual(code, 2)
                self.assertEqual(values["state"], "error")

    def test_url_and_host_are_never_printed(self):
        server = self.serve(reply(503, b"busy"))
        host = "localhost"
        url = server.url(path="/secret-health-path", host=host)
        code, output, _ = self.run_check(url)
        self.assertEqual(code, 1)
        self.assertNotIn(host, output)
        self.assertNotIn("secret-health-path", output)
        # In Actions the host appears once, in the command that masks it.
        code, output, values = self.run_check(url, actions=True)
        lines_with_host = [line for line in output.splitlines() if host in line]
        self.assertEqual(lines_with_host, [f"::add-mask::{host}"])
        self.assertNotIn(host, json.dumps(values))


if __name__ == "__main__":
    unittest.main()
