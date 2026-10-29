"""Exercise the actual deploy script in a disposable local repository.

SSH, rsync, the release build, file and curl are inert local stubs. No network, compilation,
GPU, real credential, service or production path is used.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


@unittest.skipIf(os.name == "nt", "Linux deployment script requires Bash")
class DeployScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.repo = base / "repo"
        self.vm = base / "mock-vm"
        self.stub = base / "stub"
        for path in (self.repo / "deploy", self.repo / "vm", self.vm / "bin", self.stub):
            path.mkdir(parents=True)
        source = Path(__file__).resolve().parent
        shutil.copy2(source.parent / "deploy/deploy.sh", self.repo / "deploy/deploy.sh")
        shutil.copy2(source / "deploy_preflight.py", self.repo / "vm/deploy_preflight.py")
        (self.repo / "vm/oliv_config.py").write_text("# Inert config check for deploy orchestration.\n")
        config = '[api]\nhost="127.0.0.1"\nport=8083\nauth_mode="keys"\n'
        (self.repo / "vm/config.toml").write_text(config)
        self.executable(self.repo / "vm/start.sh", 'echo "start $*" >> "$OLIV_MOCK_EVENTS"')
        self.executable(self.repo / "vm/stop.sh", 'echo "stop $*" >> "$OLIV_MOCK_EVENTS"')
        for path in (self.repo / "vm").iterdir():
            shutil.copy2(path, self.vm / path.name)
        (self.vm / "api-keys.json").write_text("{}")
        (self.vm / "api-keys.json").chmod(0o600)
        self.build = self.repo / "oliv-api/target/release"
        self.build.mkdir(parents=True)
        self.executable(self.build / "oliv-api", "exit 0")
        self.executable(self.build / "oliv-keys", 'echo "keys $*" >> "$OLIV_MOCK_EVENTS"; exit "${OLIV_MOCK_KEY_RESULT:-0}"')
        for name in ("oliv-api", "oliv-keys"):
            shutil.copy2(self.build / name, self.vm / "bin" / name)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "vm"], check=True, capture_output=True)

        self.executable(self.stub / "ssh", r'''python3 - "$@" <<'PY'
import os, shlex, subprocess, sys
command = sys.argv[-1].replace("~/oliv", shlex.quote(os.environ["OLIV_MOCK_VM"]))
with open(os.environ["OLIV_MOCK_SSH_LOG"], "a") as log:
    log.write(command + "\n")
# Use fd 3 because the Python driver consumes its own heredoc on stdin.
sys.exit(subprocess.run(["bash", "-c", command], stdin=3).returncode)
PY''', preserve_stdin=True)
        self.executable(self.stub / "rsync", r'''python3 - "$@" <<'PY'
import os, pathlib, shutil, sys
args = sys.argv[1:]
source = pathlib.Path(args[-2])
remote_path = args[-1].split(":", 1)[1]
destination = pathlib.Path(os.environ["OLIV_MOCK_VM"]) / remote_path.removeprefix("oliv/")
if "--files-from=-" in args:
    with os.fdopen(3) as names:
        for name in names.read().splitlines():
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, target)
else:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
PY''', preserve_stdin=True)
        (self.repo / "scripts").mkdir()
        self.executable(self.repo / "scripts/build-release.sh", '''echo build >> "$OLIV_MOCK_EVENTS"
if [[ ${OLIV_MOCK_DRIFT:-0} == 1 ]]; then
  echo '# changed during build' >> "$OLIV_MOCK_VM/config.toml"
fi''')
        self.executable(self.stub / "file", 'echo "synthetic statically linked binary"')
        # No open API connections unless a test says otherwise.
        self.executable(self.stub / "ss", 'cat "$OLIV_MOCK_VM/connections" 2>/dev/null || true')
        self.executable(self.stub / "curl", 'echo \'{"ok":true}\'')
        self.events = base / "events"
        self.ssh_log = base / "ssh.log"
        self.env = dict(os.environ, PATH=str(self.stub) + os.pathsep + os.environ["PATH"],
                        OLIV_VM="mock-only", OLIV_MOCK_VM=str(self.vm),
                        OLIV_MOCK_EVENTS=str(self.events), OLIV_MOCK_SSH_LOG=str(self.ssh_log))

    @staticmethod
    def executable(path, body, preserve_stdin=False):
        path.write_text("#!/bin/bash\nset -eu\n" + ("exec 3<&0\n" if preserve_stdin else "") + body + "\n")
        path.chmod(0o755)

    def run_deploy(self, *args):
        return subprocess.run(["bash", str(self.repo / "deploy/deploy.sh"), *args],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def test_unchanged_binaries_still_validate_keys_and_restart_api(self):
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.events.read_text()
        self.assertIn("no file changes", result.stdout)
        self.assertIn("keys --root", events)
        self.assertIn("stop api\nstart api\n", events)
        self.assertNotIn("gemma", events)

    def test_new_tunnel_ingress_requires_the_vm_config_to_match_first(self):
        shutil.copy2(Path(__file__).resolve().parent / "consumer_tunnel.py", self.repo / "vm/consumer_tunnel.py")
        subprocess.run(["git", "-C", str(self.repo), "add", "vm"], check=True, capture_output=True)
        (self.vm / "cloudflared").mkdir()
        stale = {"ingress": [{"hostname": "oliv.example.com", "path": "^/(health|v1/(dictate|clean))$",
                              "service": "http://127.0.0.1:8083"}, {"service": "http_status:404"}]}
        (self.vm / "cloudflared/consumer-config.json").write_text(json.dumps(stale))
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("consumer tunnel ingress on the VM differs", result.stderr)
        self.assertFalse((self.vm / "consumer_tunnel.py").exists())
        self.assertNotIn("stop api", self.events.read_text() if self.events.exists() else "")

        sys.path.insert(0, str(self.repo / "vm"))
        try:
            import consumer_tunnel
        finally:
            sys.path.pop(0)
        (self.vm / "cloudflared/consumer-config.json").write_text(json.dumps({"ingress": consumer_tunnel.ingress("oliv.example.com")}))
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.vm / "consumer_tunnel.py").exists())

    def test_api_restart_waits_for_idle_and_gives_up_when_busy(self):
        (self.vm / "connections").write_text("ESTAB 0 0 127.0.0.1:8083 127.0.0.1:50000\n")
        self.env["OLIV_DEPLOY_IDLE_TRIES"] = "4"
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stayed busy", result.stderr)
        self.assertNotIn("stop api", self.events.read_text())
        (self.vm / "connections").unlink()
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("stop api\nstart api\n", self.events.read_text())

    def test_config_drift_aborts_before_activation_and_restart(self):
        self.env["OLIV_MOCK_DRIFT"] = "1"
        original = (self.vm / "bin/oliv-api").read_bytes()
        self.executable(self.build / "oliv-api", "# updated executable\nexit 0")
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config changed during deployment", result.stderr)
        self.assertEqual((self.vm / "bin/oliv-api").read_bytes(), original)
        self.assertNotIn("stop api", self.events.read_text())
        self.assertNotIn("keys --root", self.events.read_text())

    def test_key_admin_module_change_restarts_dashboard_only_among_model_services(self):
        module = self.repo / "vm/dashboard_keys.py"
        module.write_text("# Updated key administration module.\n")
        self.executable(self.repo / "vm/dashboard.sh", 'echo "dashboard $*" >> "$OLIV_MOCK_EVENTS"')
        shutil.copy2(self.repo / "vm/dashboard.sh", self.vm / "dashboard.sh")
        subprocess.run(["git", "-C", str(self.repo), "add", "vm"], check=True, capture_output=True)
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.events.read_text()
        self.assertIn("dashboard stop\ndashboard start\n", events)
        self.assertIn("stop api\nstart api\n", events)
        self.assertNotIn("gemma", events)
        self.assertNotIn("whisper", events)
        self.assertEqual((self.vm / "dashboard_keys.py").read_text(), module.read_text())

    def test_bad_key_store_aborts_before_activation_and_restart(self):
        self.env["OLIV_MOCK_KEY_RESULT"] = "1"
        original = (self.vm / "bin/oliv-api").read_bytes()
        self.executable(self.build / "oliv-api", "# updated executable\nexit 0")
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("key-store validation failed", result.stderr)
        self.assertEqual((self.vm / "bin/oliv-api").read_bytes(), original)
        self.assertNotIn("stop api", self.events.read_text())

    def test_legacy_missing_auth_stops_before_build_or_remote_writes(self):
        (self.vm / "config.toml").write_text('[api]\nhost="100.64.0.10"\nport=8083\n')
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("migration required", result.stderr)
        self.assertFalse(self.events.exists())
        self.assertFalse((self.vm / "run").exists())

    def test_config_comments_are_never_printed(self):
        path = self.vm / "config.toml"
        path.write_text(path.read_text() + "# SYNTHETIC-PRIVATE-COMMENT-MARKER\n")
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("SYNTHETIC-PRIVATE-COMMENT-MARKER", result.stdout + result.stderr)
        self.assertNotIn("cat " + str(path), self.ssh_log.read_text())


if __name__ == "__main__":
    unittest.main()
