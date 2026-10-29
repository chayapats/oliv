"""Offline config/migration regressions; models are empty files in a temp root."""

import copy
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

import oliv_config as config


class ApiConfigTests(unittest.TestCase):
    def setUp(self):
        self.raw = tomllib.loads((Path(__file__).parent / "config.toml").read_text())
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in (self.raw["gemma"]["model"], self.raw["whisper"]["model"] + "/model.bin"):
            model = self.root / name
            model.parent.mkdir(parents=True, exist_ok=True)
            model.touch()
        for name, value in (("ROOT", self.root), ("MODELS", self.root / "models"),
                            ("CONFIG_PATH", self.root / "config.toml")):
            patcher = patch.object(config, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def save(self, raw):
        cfg = config.normalize(raw)
        config.dump(cfg)
        return cfg

    def test_new_defaults_and_modes_roundtrip(self):
        for host, mode in (("127.0.0.1", "keys"), ("100.64.0.10", "keys"),
                           ("100.64.0.10", "legacy")):
            with self.subTest(host=host, mode=mode):
                raw = copy.deepcopy(self.raw)
                raw["api"].update(host=host, auth_mode=mode)
                expected = self.save(raw)
                self.assertEqual(config.load(), expected)
                self.assertEqual(tomllib.loads(config.render(expected))["api"]["auth_mode"], mode)

    def test_asr_profile_roundtrip_and_dashboard_preservation(self):
        for profile in ("turbo", "qwen3asr", "typhoon-ctx"):
            self.raw["api"]["asr_profile"] = profile
            self.raw["api"]["asr_concurrency"] = 1
            expected = self.save(self.raw)
            self.assertEqual(config.load()["api"]["asr_profile"], profile)
            posted = copy.deepcopy(self.raw)
            posted["api"]["asr_profile"] = "invalid"
            self.assertEqual(config.normalize(posted, from_client=True)["api"], expected["api"])
        for bad in ("qwen", True):
            self.raw["api"]["asr_profile"] = bad
            with self.assertRaises(config.ConfigError):
                config.normalize(self.raw)

    def test_missing_auth_does_not_enable_legacy(self):
        self.raw["api"].pop("auth_mode")
        self.raw["api"]["host"] = "100.64.0.10"
        self.assertEqual(config.normalize(self.raw)["api"]["auth_mode"], "keys")
        self.raw.pop("api")
        api = config.normalize(self.raw)["api"]
        self.assertEqual((api["host"], api["auth_mode"]), ("127.0.0.1", "keys"))

    def test_public_binds_and_loopback_legacy_are_rejected(self):
        for host, mode, port in (("0.0.0.0", "keys", 8083), ("::", "keys", 8083),
                                 ("192.168.1.5", "keys", 8083),
                                 ("100.128.0.1", "keys", 8083),
                                 ("100.128.0.1", "legacy", 8083),
                                 ("100.64.0.010", "keys", 8083),
                                 ("127.0.0.1", "legacy", 8083),
                                 ("100.64.0.10", "keys", 9999)):
            with self.subTest(host=host, mode=mode, port=port):
                self.raw["api"].update(host=host, auth_mode=mode, port=port)
                with self.assertRaises(config.ConfigError):
                    config.normalize(self.raw)

    def test_unknown_auth_fields_are_not_silently_dropped(self):
        self.raw["api"]["auth_mod"] = "legacy"
        with self.assertRaises(config.ConfigError):
            config.normalize(self.raw)

    def test_dashboard_preserves_disk_auth_not_posted_auth(self):
        self.raw["api"].update(host="100.64.0.10", auth_mode="legacy")
        expected = self.save(self.raw)
        posted = copy.deepcopy(self.raw)
        posted["api"] = {"host": "0.0.0.0", "port": 8083, "auth_mode": "keys"}
        posted["gemma"]["context"] = 4096
        updated = config.normalize(posted, from_client=True)
        self.assertEqual(updated["api"], expected["api"])
        config.dump(updated)
        self.assertEqual(config.load()["api"], expected["api"])

    def test_dashboard_cannot_replace_unreadable_auth_with_defaults(self):
        config.CONFIG_PATH.write_text("invalid = [")
        with self.assertRaises(config.ConfigError):
            config.normalize(self.raw, from_client=True)
        config.CONFIG_PATH.unlink()
        with self.assertRaises(config.ConfigError):
            config.normalize(self.raw, from_client=True)

    def test_qwen_capacity_roundtrips_and_dashboard_preserves_it(self):
        self.raw["api"].update(asr_profile="qwen3asr", asr_concurrency=2)
        expected=self.save(self.raw)
        self.assertEqual(config.load()["api"]["asr_concurrency"],2)
        posted=copy.deepcopy(self.raw);posted["api"]["asr_concurrency"]=4
        self.assertEqual(config.normalize(posted,from_client=True)["api"],expected["api"])
        for bad in (0,5,True,"2"):
            self.raw["api"]["asr_concurrency"]=bad
            with self.assertRaises(config.ConfigError):config.normalize(self.raw)
        self.raw["api"].update(asr_profile="turbo",asr_concurrency=2)
        with self.assertRaises(config.ConfigError):config.normalize(self.raw)


if __name__ == "__main__":
    unittest.main()
