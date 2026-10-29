"""Dashboard health compatibility without network, GPU, credentials or services."""

import json
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

import dashboard


class DashboardApiHealthTests(unittest.TestCase):
    def setUp(self):
        self.config = tomllib.loads((Path(__file__).parent / "config.toml").read_text())

    def test_minimal_liveness_is_not_a_configuration_mismatch(self):
        self.assertEqual(dashboard.api_live({"ok": True}, self.config), (None, None))
        self.assertEqual(dashboard.api_live(None, self.config), (None, False))

    def test_legacy_detailed_health_can_still_prove_match(self):
        health = {"ok": True, "version": "test", "prompt": self.config["api"]["prompt"],
                  "llm_timeout": self.config["api"]["llm_timeout"], "whisper": True, "gemma": True}
        view, matches = dashboard.api_live(health, self.config)
        self.assertTrue(matches)
        self.assertEqual(view["prompt"], self.config["api"]["prompt"])
        health["llm_timeout"] += 1
        self.assertFalse(dashboard.api_live(health, self.config)[1])

    def test_status_uses_configured_private_bind_without_reading_credentials(self):
        self.config["api"].update(host="100.64.0.10", auth_mode="legacy")
        seen = []

        def fetch(url):
            seen.append(url)
            return {"ok": True}

        with patch.object(dashboard, "load", return_value=self.config), \
             patch.object(dashboard, "find_pid", return_value=None), \
             patch.object(dashboard, "gpu_snapshot", return_value={}), \
             patch.object(dashboard, "fetch_json", side_effect=fetch):
            result = dashboard.status()["api"]
            self.assertEqual(dashboard.health_url("api"), "http://100.64.0.10:8083/health")
        self.assertIn("http://100.64.0.10:8083/health", seen)
        self.assertFalse(any("/v1/status" in url for url in seen))
        self.assertEqual(result["host"], "100.64.0.10")
        self.assertTrue(result["up"])
        self.assertIsNone(result["config_matches"])
        self.assertFalse(result["runtime_config_verified"])

    def test_public_url_comes_only_from_a_valid_consumer_tunnel_config(self):
        import consumer_tunnel

        with tempfile.TemporaryDirectory() as temp, patch.object(dashboard, "ROOT", Path(temp)):
            self.assertIsNone(dashboard.public_url())
            (Path(temp) / "cloudflared").mkdir(mode=0o700)
            path = Path(temp) / "cloudflared/consumer-config.json"
            path.write_text(json.dumps({"ingress": consumer_tunnel.ingress("oliv.example.com")}))
            path.chmod(0o600)
            self.assertEqual(dashboard.public_url(), "https://oliv.example.com")
            path.write_text(json.dumps({"ingress": consumer_tunnel.ingress("*.example.com")}))
            self.assertIsNone(dashboard.public_url())


if __name__ == "__main__":
    unittest.main()
