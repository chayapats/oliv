"""Run dashboard.sh against fake /proc entries and an inert kill function."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipIf(os.name == "nt", "Linux dashboard launcher requires Bash and /proc")
class DashboardLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "OLIV ผู้ใช้'s dashboard"
        self.root.mkdir()
        (self.root / "run").mkdir()
        self.proc = self.base / "proc"
        self.proc.mkdir()
        self.log = self.base / "signals"
        source = Path(__file__).with_name("dashboard.sh").read_text()
        # Only redirect the Linux observation paths. Production has no test
        # override, and all command matching/stopping logic runs unchanged.
        (self.root / "dashboard.sh").write_text(source.replace("/proc/", str(self.proc) + "/"))
        self.env_file = self.base / "bash-env"
        self.env_file.write_text('''
kill() {
  printf '%s\\n' "$*" >> "$TEST_SIGNAL_LOG"
  if [[ "${TEST_KEEP_ALIVE:-0}" != 1 ]]; then
    rm -f "$TEST_PROC/$1/cmdline" "$TEST_PROC/$1/exe"
  fi
}
sleep() { :; }
readonly -f kill sleep
''')
        self.env = dict(os.environ, BASH_ENV=str(self.env_file),
                        TEST_PROC=str(self.proc), TEST_SIGNAL_LOG=str(self.log))

    def process(self, pid, args, executable="/usr/bin/python3.12"):
        entry = self.proc / str(pid)
        entry.mkdir()
        (entry / "cmdline").write_bytes(b"\0".join(arg.encode() for arg in args) + b"\0")
        (entry / "exe").symlink_to(executable)

    def run_stop(self, pidfile=None):
        if pidfile is not None:
            (self.root / "run/dashboard.pid").write_text(str(pidfile))
        result = subprocess.run(["bash", str(self.root / "dashboard.sh"), "stop"],
                                env=self.env, text=True, capture_output=True, timeout=5)
        signals = self.log.read_text().splitlines() if self.log.exists() else []
        return result, signals

    def test_stale_pidfile_and_other_dashboards_never_receive_signals(self):
        script = str(self.root / "dashboard.py")
        candidates = [
            ["python3", "/other-service/dashboard.py"],
            ["python3", "-c", "print('" + script + "')"],
            ["bash", "-c", "python3 " + script],
            ["python3", script + ".other"],
            ["python3", "-u", script, "extra-argument"],
        ]
        for pid, args in enumerate(candidates, 310001):
            self.process(pid, args)
        result, signals = self.run_stop(310001)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(signals, [])
        self.assertFalse((self.root / "run/dashboard.pid").exists())

    def test_real_dashboard_pidfile_is_checked_and_stopped_once(self):
        self.process(310011, ["python3", "-u", str(self.root / "dashboard.py")])
        result, signals = self.run_stop(310011)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(signals, ["310011"])

    def test_fallback_requires_exact_script_and_real_python_executable(self):
        script = str(self.root / "dashboard.py")
        self.process(310021, ["/usr/bin/python3", script])
        self.process(310022, ["python3", "-u", script], executable="/usr/bin/sleep")
        self.process(310023, ["fake-python3", script])
        result, signals = self.run_stop("-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(signals, ["310021"])

    def test_process_that_does_not_exit_fails_without_group_or_force_kill(self):
        self.process(310031, ["python3", "-u", str(self.root / "dashboard.py")])
        self.env["TEST_KEEP_ALIVE"] = "1"
        result, signals = self.run_stop(310031)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not exit", result.stderr)
        self.assertEqual(signals, ["310031"])
        self.assertTrue((self.root / "run/dashboard.pid").exists())


if __name__ == "__main__":
    unittest.main()
