"""Exercise the real Whisper HTTP handler using synthetic, lazy model output."""

import http.client
import importlib.util
import socket
import sys
import threading
import types
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch


def load_handler_module():
    """Import without loading numpy, model files, configuration or a GPU."""
    whisper = types.ModuleType("faster_whisper")
    whisper.__version__ = "1.2.1"
    whisper.WhisperModel = type("WhisperModel", (), {"__init__": lambda self, *a, **k: None})
    audio = types.ModuleType("faster_whisper.audio")
    audio.pad_or_trim = lambda value: value
    config = types.ModuleType("oliv_config")
    config.ConfigError = ValueError
    config.load = lambda: {"whisper": {
        "model": "synthetic", "host": "127.0.0.1", "port": 0,
        "device": "cpu", "compute_type": "int8", "beam_size": 1,
    }}
    config.resolve_model = lambda *_: Path("synthetic-model-not-loaded")
    modules = {"faster_whisper": whisper, "faster_whisper.audio": audio,
               "numpy": types.ModuleType("numpy"), "oliv_config": config}
    path = Path(__file__).with_name("whisper_server.py")
    spec = importlib.util.spec_from_file_location("whisper_limits_test_backend", path)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, modules), patch.object(sys, "path", list(sys.path)):
        spec.loader.exec_module(module)
    return module


class ControlledModel:
    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls = 0
        self.active = 0
        self.max_active = 0
        self.fail = False
        self.lock = threading.Lock()

    def transcribe(self, path, **_kwargs):
        # Match faster-whisper: inference continues while consuming the iterator.
        def segments():
            with self.lock:
                self.calls += 1
                self.active += 1
                self.max_active = max(self.active, self.max_active)
            self.started.set()
            try:
                if not self.release.wait(3):
                    raise AssertionError("test did not release the synthetic inference")
                if self.fail:
                    raise RuntimeError("synthetic model failure")
                yield types.SimpleNamespace(text="synthetic text", avg_logprob=-0.1)
            finally:
                with self.lock:
                    self.active -= 1

        return segments(), types.SimpleNamespace(language="en")


class QuietServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # The exception-recovery case intentionally closes without a response.
        self.handler_errors += 1


class WhisperAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.module = load_handler_module()
        self.model = ControlledModel()
        self.module.model = self.model

        class QuietHandler(self.module.Handler):
            def log_message(self, *_args):
                pass

        self.server = QuietServer(("127.0.0.1", 0), QuietHandler)
        self.server.handler_errors = 0
        self.server_thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        self.server_thread.start()
        self.addr = self.server.server_address
        self.connections = []

    def tearDown(self):
        self.model.release.set()
        for connection in self.connections:
            connection.close()
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(2)
        self.assertFalse(self.server_thread.is_alive())
        self.wait_for_idle()

    def connection(self, timeout=1):
        connection = http.client.HTTPConnection(*self.addr, timeout=timeout)
        self.connections.append(connection)
        return connection

    def wait_for_idle(self):
        self.assertTrue(self.module._inference_lock.acquire(timeout=2),
                        "inference lock was not released")
        self.module._inference_lock.release()

    def assert_busy_before_reading_body(self):
        connection = self.connection()
        connection.putrequest("POST", "/transcribe")
        connection.putheader("Content-Length", "1024")
        connection.endheaders()  # Intentionally never send the declared body.
        response = connection.getresponse()
        self.assertEqual(response.status, 503)
        self.assertEqual(response.getheader("Connection"), "close")
        self.assertIn(b"busy", response.read())
        connection.close()
        self.assertEqual(self.model.calls, 1)

    def assert_recovers(self):
        self.model.release.set()
        self.wait_for_idle()
        connection = self.connection()
        connection.request("POST", "/transcribe", b"synthetic-audio")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertIn(b"synthetic text", response.read())
        connection.close()
        self.assertEqual(self.model.calls, 2)
        self.assertEqual(self.model.max_active, 1)

    def test_disconnect_keeps_inference_busy_without_queuing_another_request(self):
        connection = self.connection()
        connection.request("POST", "/transcribe", b"synthetic-audio")
        self.assertTrue(self.model.started.wait(1))
        connection.sock.shutdown(socket.SHUT_RDWR)
        connection.close()
        for _ in range(3):
            self.assert_busy_before_reading_body()
        self.assert_recovers()

    def test_upstream_timeout_cannot_start_second_inference(self):
        connection = self.connection(timeout=0.1)
        connection.request("POST", "/transcribe", b"synthetic-audio")
        self.assertTrue(self.model.started.wait(1))
        with self.assertRaises(TimeoutError):
            connection.getresponse()
        connection.close()
        self.assert_busy_before_reading_body()
        self.assert_recovers()

    def test_model_exception_releases_inference_slot(self):
        self.model.fail = True
        self.model.release.set()
        connection = self.connection()
        connection.request("POST", "/transcribe", b"synthetic-audio")
        with self.assertRaises(http.client.RemoteDisconnected):
            connection.getresponse()
        self.wait_for_idle()
        self.assertEqual(self.server.handler_errors, 1)
        self.model.fail = False
        self.assert_recovers()


if __name__ == "__main__":
    unittest.main()
