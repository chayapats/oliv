"""Readiness probes target the address each service actually binds."""

import unittest
from unittest import mock

import oliv_config
import service_health


class ProbeHostTests(unittest.TestCase):
    def probed_url(self, name, api_host=None, error=None):
        load = mock.Mock(side_effect=error, return_value={"api": {"host": api_host}})
        response = mock.MagicMock(status=200)
        response.__enter__.return_value = response
        with mock.patch.object(oliv_config, "load", load), \
             mock.patch.object(service_health.urllib.request, "urlopen", return_value=response) as urlopen:
            self.assertTrue(service_health.healthy(name))
        return urlopen.call_args.args[0]

    def test_api_on_private_overlay_is_probed_there(self):
        self.assertEqual(self.probed_url("api", "100.64.1.2"), "http://100.64.1.2:8083/health")

    def test_api_on_loopback(self):
        self.assertEqual(self.probed_url("api", "127.0.0.1"), "http://127.0.0.1:8083/health")

    def test_unreadable_config_falls_back_to_loopback(self):
        url = self.probed_url("api", error=oliv_config.ConfigError("bad"))
        self.assertEqual(url, "http://127.0.0.1:8083/health")

    def test_other_services_stay_on_loopback(self):
        self.assertEqual(self.probed_url("whisper", "100.64.1.2"), "http://127.0.0.1:8082/health")
        self.assertEqual(self.probed_url("api-tunnel", "100.64.1.2"), "http://127.0.0.1:20247/ready")


if __name__ == "__main__":
    unittest.main()
