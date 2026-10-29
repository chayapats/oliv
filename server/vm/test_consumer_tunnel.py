"""Consumer ingress safety using private synthetic files and mocked processes."""

import base64
import copy
import json
import socket
import os
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import consumer_tunnel as consumer


IDENT = "01234567-89ab-4cde-8f01-23456789abcd"
OTHER = "abcdef01-2345-4678-9abc-def012345678"


class ConsumerTunnelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "OLIV ผู้ใช้'s root"
        for name in ("bin", "cloudflared", "run", "logs"):
            (self.root / name).mkdir(mode=0o700, parents=True)
        self.tunnel = consumer.ConsumerTunnel(self.root)
        self.config = {"tunnel": IDENT, "credentials-file": str(self.tunnel.credentials),
                       "ingress": consumer.ingress("oliv.example.com")}
        self.credentials = {"AccountTag": "1" * 32, "TunnelID": IDENT,
                            "TunnelSecret": base64.b64encode(b"synthetic-key-not-live".ljust(32, b"!")).decode()}
        self.write_json(self.tunnel.config, self.config)
        self.write_json(self.tunnel.credentials, self.credentials)
        (self.root / "config.toml").write_text(
            '[api]\nhost="127.0.0.1"\nport=8083\nauth_mode="keys"\n')
        for path in (self.tunnel.binary, self.root / "bin/oliv-keys"):
            path.write_text("synthetic-inert-not-executable-code")
            path.chmod(0o700)
        self.run = patch.object(consumer.subprocess, "run", return_value=Mock(returncode=0)).start()
        self.addCleanup(patch.stopall)
        self.proc = self.root / "fake-proc"
        (self.proc / "sys/kernel/random").mkdir(parents=True)
        (self.proc / "sys/kernel/random/boot_id").write_text(OTHER)
        patch.object(consumer, "PROC", self.proc).start()

    @staticmethod
    def write_json(path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def fake_process(self, pid=510001, argv=None, uid=None, start="12345", executable=None):
        path = self.proc / str(pid)
        path.mkdir(exist_ok=True)
        # Fields after the command begin at field3; starttime is field22.
        fields = ["S", *("0" for _ in range(18)), start, "0"]
        (path / "stat").write_text(f"{pid} (cloudflared) " + " ".join(fields))
        args = self.tunnel.command(IDENT) if argv is None else argv
        (path / "cmdline").write_bytes(b"\0".join(os.fsencode(arg) for arg in args) + b"\0")
        owner = os.geteuid() if uid is None else uid
        (path / "status").write_text("Uid:\t" + "\t".join([str(owner)] * 4) + "\n")
        (path / "exe").unlink(missing_ok=True)
        (path / "exe").symlink_to(executable or self.tunnel.binary)
        return path

    def test_valid_config_uses_only_local_validation_and_no_secret_arguments(self):
        self.assertEqual(self.tunnel.validate(), IDENT)
        self.assertEqual(len(self.run.call_args_list), 2)
        self.assertEqual(self.run.call_args_list[0].args[0],
                         [str(self.root / "bin/oliv-keys"), "--root", str(self.root), "list"])
        self.assertEqual(self.run.call_args_list[1].args[0],
                         [str(self.tunnel.binary), "tunnel", "--config", str(self.tunnel.config),
                          "ingress", "validate"])
        self.assertNotIn(self.credentials["TunnelSecret"], " ".join(self.tunnel.command(IDENT)))

    def test_rejects_broader_routes_hosts_origins_and_unknown_settings(self):
        cases = []
        for field, value in (("hostname", "*"), ("path", ".*"),
                             ("service", "http://127.0.0.1:8090"),
                             ("service", "http://127.0.0.1:9999")):
            config = copy.deepcopy(self.config)
            config["ingress"][0][field] = value
            cases.append(config)
        config = copy.deepcopy(self.config)
        config["ingress"][-1] = {"service": consumer.ORIGIN}
        cases.append(config)
        cases.append(dict(self.config, metrics="0.0.0.0:20247"))
        cases.append(dict(self.config, **{"credentials-file": str(self.root / "cloudflared/other-tunnel.json")}))
        for config in cases:
            with self.subTest(config=config):
                self.write_json(self.tunnel.config, config)
                with self.assertRaises(consumer.Unsafe):
                    self.tunnel.validate()
        self.run.assert_not_called()

    def test_other_tunnel_credentials_with_their_own_identity_are_left_alone(self):
        other = self.root / "cloudflared/other-tunnel.json"
        self.write_json(other, dict(self.credentials, TunnelID=OTHER))
        before = other.read_bytes()
        self.assertEqual(self.tunnel.validate(), IDENT)
        self.assertEqual(other.read_bytes(), before)

    def test_shared_non_private_metadata_beside_the_credentials_is_tolerated(self):
        metadata = self.root / "cloudflared/access-app.json"
        metadata.write_text(json.dumps([{"name": "app", "domain": "example.com"}]))
        metadata.chmod(0o664)
        (self.root / "cloudflared/broken.json").write_text("{not json")
        self.assertEqual(self.tunnel.validate(), IDENT)
        duplicate = self.root / "cloudflared/other-tunnel.json"
        duplicate.write_text(json.dumps(self.credentials))
        duplicate.chmod(0o664)
        with self.assertRaises(consumer.Unsafe):
            self.tunnel.validate()

    def test_rejects_credential_identity_alias_permissions_and_duplicates(self):
        self.write_json(self.tunnel.credentials, dict(self.credentials, TunnelID=OTHER))
        with self.assertRaises(consumer.Unsafe):
            self.tunnel.validate()
        self.write_json(self.tunnel.credentials, self.credentials)
        self.write_json(self.root / "cloudflared/other-tunnel.json", self.credentials)
        with self.assertRaises(consumer.Unsafe):
            self.tunnel.validate()
        (self.root / "cloudflared/other-tunnel.json").unlink()
        self.tunnel.credentials.chmod(0o644)
        with self.assertRaises(consumer.Unsafe):
            self.tunnel.validate()
        self.tunnel.credentials.chmod(0o600)
        other = self.root / "cloudflared/other.json"
        self.tunnel.credentials.rename(other)
        self.tunnel.credentials.symlink_to(other)
        with self.assertRaises(OSError):
            self.tunnel.validate()
        self.tunnel.credentials.unlink()
        other.rename(self.tunnel.credentials)
        self.tunnel.config.write_text('{"tunnel":"a","tunnel":"b"}')
        with self.assertRaises(consumer.Unsafe):
            self.tunnel.validate()
        self.run.assert_not_called()

    def test_rejects_writable_ancestors_legacy_and_private_api_bind(self):
        (self.root / "cloudflared").chmod(0o775)
        with self.assertRaises(consumer.Unsafe):
            self.tunnel.validate()
        (self.root / "cloudflared").chmod(0o700)
        for host, mode in (("100.64.0.10", "keys"), ("127.0.0.1", "legacy")):
            (self.root / "config.toml").write_text(
                f'[api]\nhost="{host}"\nport=8083\nauth_mode="{mode}"\n')
            with self.assertRaises(consumer.Unsafe):
                self.tunnel.validate()
        self.run.assert_not_called()

    def test_exact_process_identity_rejects_other_binary_argv_and_uid(self):
        self.fake_process()
        record = self.tunnel.identity(510001, IDENT)
        self.assertEqual(record["start_time"], "12345")
        self.assertEqual(record["boot_id"], OTHER)
        variants = [dict(argv=self.tunnel.command(IDENT) + ["--url", consumer.ORIGIN]),
                    dict(argv=["sh", "-c", " ".join(self.tunnel.command(IDENT))]),
                    dict(uid=os.geteuid() + 1),
                    dict(executable=self.root / "bin/oliv-keys")]
        for variant in variants:
            self.fake_process(**variant)
            with self.assertRaises(consumer.Unsafe):
                self.tunnel.identity(510001, IDENT)

    def test_stop_uses_pidfd_and_never_signals_recycled_process(self):
        self.fake_process()
        record = self.tunnel.identity(510001, IDENT)
        self.tunnel.write_record(record)
        with patch.object(consumer.os, "pidfd_open", return_value=77), \
             patch.object(consumer.os, "close") as close, \
             patch.object(consumer.signal, "pidfd_send_signal") as send, \
             patch.object(consumer.select, "select", return_value=([77], [], [])):
            self.fake_process(start="54321")
            with self.assertRaises(consumer.Unsafe):
                self.tunnel.stop_record(record)
            send.assert_not_called()
            self.fake_process()
            self.tunnel.stop_record(record)
            send.assert_called_once_with(77, signal.SIGTERM)
            self.assertEqual(close.call_count, 2)

    def test_stop_timeout_never_escalates_and_does_not_need_config_or_credentials(self):
        self.fake_process()
        record = self.tunnel.identity(510001, IDENT)
        self.tunnel.write_record(record)
        self.tunnel.config.unlink()
        self.tunnel.credentials.unlink()
        with patch.object(consumer.os, "pidfd_open", return_value=77), \
             patch.object(consumer.os, "close"), \
             patch.object(consumer.signal, "pidfd_send_signal") as send, \
             patch.object(consumer.select, "select", return_value=([], [], [])):
            with self.assertRaises(consumer.Unsafe):
                self.tunnel.stop_record(record)
            send.assert_called_once_with(77, signal.SIGTERM)
        self.assertTrue(self.tunnel.pidfile.exists())

    def test_port_probe_ignores_time_wait_but_refuses_a_listener(self):
        with socket.socket() as listener:
            # Like cloudflared: Go sets SO_REUSEADDR on every listener, and
            # Linux only lets a probe past TIME_WAIT when both sides set it.
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            with self.assertRaises(OSError):
                consumer.ensure_port_free(port)
            # Leave the port in TIME_WAIT the way /ready probes do: the server
            # side closes first.
            client = socket.create_connection(("127.0.0.1", port))
            accepted, _ = listener.accept()
            accepted.close()
            client.recv(1)
            client.close()
        consumer.ensure_port_free(port)

    def test_metrics_must_belong_to_exact_pid_and_only_listen_on_loopback(self):
        proc = self.fake_process()
        (proc / "fd").mkdir()
        (proc / "fd/3").symlink_to("socket:[123]")
        (proc / "net").mkdir()
        tcp = proc / "net/tcp"
        (proc / "net/tcp6").write_text("header\n")
        tcp.write_text(f"header\n0: 0100007F:{consumer.METRICS_PORT:04X} 0 0A 0 0 0 0 0 123\n")
        self.assertTrue(self.tunnel.owns_metrics(510001))
        tcp.write_text(tcp.read_text().replace("0100007F", "00000000"))
        self.assertFalse(self.tunnel.owns_metrics(510001))
        tcp.write_text(tcp.read_text().replace("00000000", "0100007F").replace("123", "456"))
        self.assertFalse(self.tunnel.owns_metrics(510001))

    def test_inherited_cloudflare_credentials_cannot_override_local_config(self):
        with patch.dict(os.environ, {"TUNNEL_TOKEN": "synthetic", "CF_TOKEN": "synthetic"}):
            env = self.tunnel.environment()
        self.assertNotIn("TUNNEL_TOKEN", env)
        self.assertNotIn("CF_TOKEN", env)

    def test_readiness_failure_stops_only_recorded_connector_and_removes_pid(self):
        self.fake_process()
        record = self.tunnel.identity(510001, IDENT)
        child = Mock(pid=510001)
        child.poll.return_value = None
        with patch.object(self.tunnel, "validate", return_value=IDENT), \
             patch.object(consumer, "local_http", side_effect=[(200, b'{"ok":true}'), (401, b"")]), \
             patch.object(consumer.socket, "socket"), \
             patch.object(consumer.subprocess, "Popen", return_value=child) as spawn, \
             patch.object(self.tunnel, "stop_record") as stop, \
             patch.object(consumer, "START_TIMEOUT", 0):
            with self.assertRaisesRegex(consumer.Unsafe, "readiness deadline"):
                self.tunnel.start()
            stop.assert_called_once_with(record)
            self.assertEqual(spawn.call_args.args[0], self.tunnel.command(IDENT))
            self.assertTrue(spawn.call_args.kwargs["close_fds"])
        self.assertFalse(self.tunnel.pidfile.exists())
        child.terminate.assert_not_called()

    def test_start_records_ready_process_and_repeat_start_does_not_spawn_again(self):
        self.fake_process()
        child = Mock(pid=510001)
        child.poll.return_value = None
        health = [(200, b'{"ok":true}'), (401, b""), (200, b"ready")]
        with patch.object(self.tunnel, "validate", return_value=IDENT), \
             patch.object(consumer, "local_http", side_effect=health * 2), \
             patch.object(consumer.socket, "socket"), \
             patch.object(consumer.subprocess, "Popen", return_value=child) as spawn, \
             patch.object(self.tunnel, "owns_metrics", return_value=True), \
             patch.object(self.tunnel, "stop_record") as stop:
            self.tunnel.start()
            record = self.tunnel.read_record()
            self.assertEqual(record, self.tunnel.identity(510001, IDENT))
            self.tunnel.start()
            self.assertEqual(spawn.call_count, 1)
            stop.assert_not_called()
            self.assertEqual(self.tunnel.read_record(), record)
        self.assertEqual(self.tunnel.pidfile.stat().st_mode & 0o777, 0o600)

    def test_early_identity_failure_reaps_only_its_direct_child(self):
        child = Mock(pid=510001)
        child.poll.return_value = None
        with patch.object(self.tunnel, "validate", return_value=IDENT), \
             patch.object(consumer, "local_http", side_effect=[(200, b'{"ok":true}'), (401, b"")]), \
             patch.object(consumer.socket, "socket"), \
             patch.object(consumer.subprocess, "Popen", return_value=child), \
             patch.object(self.tunnel, "identity", side_effect=consumer.Unsafe("synthetic identity error")), \
             patch.object(self.tunnel, "stop_record") as stop:
            with self.assertRaises(consumer.Unsafe):
                self.tunnel.start()
            child.terminate.assert_called_once_with()
            child.wait.assert_called_once_with(timeout=consumer.STOP_TIMEOUT)
            stop.assert_not_called()
        self.assertFalse(self.tunnel.pidfile.exists())

    def test_previous_boot_record_does_not_inspect_or_signal_reused_pid(self):
        self.fake_process(pid=510002)
        record = self.tunnel.identity(510002, IDENT)
        record.update(pid=510001, boot_id=IDENT)
        self.tunnel.write_record(record)
        self.fake_process(pid=510001, argv=["unrelated-service"])
        child = Mock(pid=510002)
        child.poll.return_value = None
        with patch.object(self.tunnel, "validate", return_value=IDENT), \
             patch.object(consumer, "local_http", side_effect=[(200, b'{"ok":true}'), (401, b""), (200, b"ready")]), \
             patch.object(consumer.socket, "socket"), \
             patch.object(consumer.subprocess, "Popen", return_value=child), \
             patch.object(self.tunnel, "owns_metrics", return_value=True), \
             patch.object(self.tunnel, "identity", wraps=self.tunnel.identity) as identity, \
             patch.object(self.tunnel, "stop_record") as stop:
            self.tunnel.start()
            self.assertEqual(self.tunnel.read_record()["pid"], 510002)
            self.assertTrue(all(call.args[0] == 510002 for call in identity.call_args_list))
            stop.assert_not_called()

    def test_start_refuses_changed_pid_record_without_overwrite_or_signal(self):
        self.fake_process()
        record = self.tunnel.identity(510001, IDENT)
        self.tunnel.write_record(record)
        original = self.tunnel.pidfile.read_bytes()
        self.fake_process(start="99999")
        with patch.object(self.tunnel, "validate", return_value=IDENT), \
             patch.object(consumer, "local_http", side_effect=[(200, b'{"ok":true}'), (401, b"")]), \
             patch.object(consumer.subprocess, "Popen") as spawn, \
             patch.object(self.tunnel, "stop_record") as stop:
            with self.assertRaises(consumer.Unsafe):
                self.tunnel.start()
            stop.assert_not_called()
            spawn.assert_not_called()
        self.assertEqual(self.tunnel.pidfile.read_bytes(), original)


class ControllerIntegrationTests(unittest.TestCase):
    def test_explicit_api_tunnel_target_uses_helper_only_under_action_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = Path(__file__).parent
            (root / "consumer_tunnel.py").write_text(
                "import os,sys\nassert os.environ['OLIV_HAVE_LOCK']=='1'\nprint('helper:'+sys.argv[1])\n")
            for script, action in (("start.sh", "start"), ("stop.sh", "stop")):
                (root / script).write_text((source / script).read_text())
                result = subprocess.run(["bash", str(root / script), "api-tunnel"],
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "helper:" + action)
            # "all" still invokes only the three existing inference services.
            self.assertIn("all) start_gemma; start_whisper; start_api ;;",
                          (root / "start.sh").read_text())


if __name__ == "__main__":
    unittest.main()
