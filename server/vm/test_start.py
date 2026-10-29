"""Run the real start script with temporary config and inert executable stubs."""

import os
import shutil
import subprocess
import tempfile
import time
import tomllib
import unittest
from pathlib import Path


@unittest.skipIf(os.name == "nt", "Linux VM launch scripts require Bash/flock")
class ApiStartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = Path(__file__).parent
        for name in ("start.sh", "oliv_config.py", "config.toml"):
            shutil.copy2(source / name, self.root / name)
        config = tomllib.loads((self.root / "config.toml").read_text())
        for name in (config["gemma"]["model"], config["whisper"]["model"] + "/model.bin"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        (self.root / "bin").mkdir()
        self.stub = self.root / "stub"
        self.stub.mkdir()
        self.executable(self.stub / "curl", "exit 1")  # Never opens a socket.
        self.executable(self.stub / "setsid", 'exec "$@"')
        self.executable(self.root / "bin/oliv-api", 'printf "%s\\n" "$@" > "$API_TEST_MARKER"')
        self.executable(self.root / "bin/oliv-keys",
                        'printf "%s\\n" "$@" > "$KEY_TEST_MARKER"; exit "${KEY_TEST_RESULT:-0}"')
        self.env = dict(os.environ, PATH=str(self.stub) + os.pathsep + os.environ["PATH"],
                        API_TEST_MARKER=str(self.root / "api-called"),
                        KEY_TEST_MARKER=str(self.root / "keys-called"))
        self.env.pop("OLIV_HAVE_LOCK", None)

    @staticmethod
    def executable(path, body):
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_start(self):
        return subprocess.run(["bash", str(self.root / "start.sh"), "api"],
                              env=self.env, text=True, capture_output=True, timeout=5)

    def wait_for_api(self):
        marker = self.root / "api-called"
        deadline = time.monotonic() + 2
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(marker.exists(), "inert API executable was not invoked")
        self.assertEqual(marker.read_text().splitlines(), ["--root", str(self.root)])

    def test_keys_start_uses_validator_without_legacy_token(self):
        result = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.wait_for_api()
        self.assertFalse((self.root / "api.token").exists())
        self.assertEqual((self.root / "keys-called").read_text().splitlines(),
                         ["--root", str(self.root), "list"])

    def test_bad_key_store_does_not_launch_or_create_credentials(self):
        self.env["KEY_TEST_RESULT"] = "1"
        result = self.run_start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("key-store validation failed", result.stderr)
        self.assertFalse((self.root / "api-called").exists())
        self.assertFalse((self.root / "api-keys.json").exists())

    def test_missing_key_cli_does_not_launch(self):
        (self.root / "bin/oliv-keys").unlink()
        result = self.run_start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing bin/oliv-keys", result.stderr)
        self.assertFalse((self.root / "api-called").exists())

    def test_legacy_still_requires_private_token_and_not_key_cli(self):
        path = self.root / "config.toml"
        before, api = path.read_text().split('[api]', 1)
        text = before + '[api]' + api.replace('host = "127.0.0.1"', 'host = "100.64.0.10"', 1)
        path.write_text(text.replace('auth_mode = "keys"', 'auth_mode = "legacy"'))
        (self.root / "bin/oliv-keys").unlink()
        result = self.run_start()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "api-called").exists())
        token = self.root / "api.token"
        token.write_text("synthetic-test-token-" * 3)
        token.chmod(0o600)
        result = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.wait_for_api()
        self.assertFalse((self.root / "keys-called").exists())

    def test_invalid_config_fails_before_any_probe_or_launch(self):
        (self.root / "config.toml").write_text("invalid = [")
        result = self.run_start()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "keys-called").exists())
        self.assertFalse((self.root / "api-called").exists())


if __name__ == "__main__":
    unittest.main()
