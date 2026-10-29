"""Read-only migration guard tests, without SSH or deployment."""

import hashlib
import os
import tempfile
import unittest
from pathlib import Path

from deploy_preflight import preflight


@unittest.skipIf(os.name == "nt", "VM preflight checks Unix permission bits")
class DeployPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def config(self, host="127.0.0.1", mode="keys"):
        self.root.joinpath("config.toml").write_text(
            f'[api]\nhost = "{host}"\nport = 8083\nauth_mode = "{mode}"\n'
        )

    def credential(self, name, content="{}", mode=0o600):
        path = self.root / name
        path.write_text(content)
        path.chmod(mode)
        return path

    def test_old_config_stops_with_migration_message_and_no_changes(self):
        original = '[api]\nhost = "100.64.0.10"\nport = 8083\n'
        path = self.root / "config.toml"
        path.write_text(original)
        with self.assertRaisesRegex(ValueError, "migration required"):
            preflight(self.root)
        self.assertEqual(path.read_text(), original)
        self.assertEqual([p.name for p in self.root.iterdir()], ["config.toml"])

    def test_explicit_private_legacy_requires_existing_private_token(self):
        self.config("100.64.0.10", "legacy")
        token = self.credential("api.token", "synthetic-test-token-" * 3)
        before = token.read_bytes()
        self.assertEqual(preflight(self.root)[:2], ("100.64.0.10", "legacy"))
        self.assertEqual(token.read_bytes(), before)
        token.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "mode 600"):
            preflight(self.root)

    def test_keys_require_regular_private_file_and_never_initialize_it(self):
        self.config()
        with self.assertRaises(FileNotFoundError):
            preflight(self.root)
        keyfile = self.credential("api-keys.json")
        self.assertEqual(preflight(self.root)[:2], ("127.0.0.1", "keys"))
        keyfile.unlink()
        target = self.credential("target.json")
        keyfile.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "regular file"):
            preflight(self.root)

    def test_no_public_bind_or_loopback_legacy(self):
        for host, mode in (("0.0.0.0", "keys"), ("127.0.0.1", "legacy"),
                           ("192.168.1.5", "keys"), ("100.64.0.10", "none"),
                           ("100.128.0.1", "keys"), ("100.128.0.1", "legacy")):
            with self.subTest(host=host, mode=mode):
                self.config(host, mode)
                with self.assertRaises(ValueError):
                    preflight(self.root)

    def test_digest_detects_even_non_auth_config_changes_without_printing_config(self):
        self.config()
        self.credential("api-keys.json")
        path = self.root / "config.toml"
        before = preflight(self.root)
        self.assertEqual(before[2], hashlib.sha256(path.read_bytes()).hexdigest())
        path.write_text(path.read_text() + "# synthetic deployment comment\n")
        after = preflight(self.root)
        self.assertEqual(before[:2], after[:2])
        self.assertNotEqual(before[2], after[2])


if __name__ == "__main__":
    unittest.main()
