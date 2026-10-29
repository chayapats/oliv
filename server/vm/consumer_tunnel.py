#!/usr/bin/env python3
"""Consumer ingress helper, invoked only by start.sh/stop.sh api-tunnel.

It never creates a Cloudflare tunnel/DNS route or touches any other tunnel.
Explicit JSON configuration is accepted by cloudflared's YAML decoder. No YAML
dependency or credential on the command line is needed.

The operator provisions cloudflared/consumer-config.json (tunnel id, credentials
path and ingress) and the matching DNS route by hand. The public hostname is
taken from that file; everything else in the ingress is fixed by ingress().
"""

import base64
import http.client
import json
import os
import re
import select
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid
from pathlib import Path

ORIGIN = "http://127.0.0.1:8083"
METRICS_PORT = 20247
API_PATHS = "^/(health|v1/(dictate|clean|dictionary))$"
# A plain DNS name (no wildcard, no port, no scheme), e.g. oliv.example.com.
HOSTNAME_RE = re.compile(r"(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")
PROC = Path("/proc")
START_TIMEOUT = 30
STOP_TIMEOUT = 10


class Unsafe(ValueError):
    pass


def ingress(hostname):
    """The only consumer ingress allowed: the public API routes, then a 404."""
    return [
        {"hostname": hostname, "path": API_PATHS, "service": ORIGIN},
        {"service": "http_status:404"},
    ]


def ingress_hostname(rules):
    """Return the public hostname of a well-formed consumer ingress, else raise."""
    host = rules[0].get("hostname") if isinstance(rules, list) and rules and isinstance(rules[0], dict) else None
    if not isinstance(host, str) or not HOSTNAME_RE.fullmatch(host) or rules != ingress(host):
        raise Unsafe("consumer config must contain only the fixed API ingress and final 404")
    return host


def checked_directory(path):
    """Reject symlink or writable/untrusted ancestors, including the final dir."""
    path = Path(os.path.abspath(path))
    for part in [*reversed(path.parents), path]:
        info = part.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid()):
            raise Unsafe("directory is symlinked or owned by another user")
        sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX and part != path
        if info.st_mode & 0o022 and not sticky_root:
            raise Unsafe("directory is writable by other users")
    if path.stat().st_uid != os.geteuid():
        raise Unsafe("OLIV directory must belong to the current user")


def open_checked(path, flags, private=False):
    checked_directory(path.parent)
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_nlink != 1 or info.st_mode & 0o022
                or (private and stat.S_IMODE(info.st_mode) != 0o600)):
            raise Unsafe("OLIV file has unsafe type, ownership or permissions")
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_file(path, private=False, limit=16384):
    with os.fdopen(open_checked(path, os.O_RDONLY, private), "rb") as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise Unsafe("OLIV file exceeds its size limit")
    return data


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise Unsafe("duplicate JSON field")
        value[key] = item
    return value


def read_json(path):
    try:
        return json.loads(read_file(path, private=True), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError):
        raise Unsafe("malformed private JSON file") from None


def peek_json(path, limit=16384):
    """Best-effort parse of a neighbouring JSON file, used only to compare a
    tunnel identity. Other tools keep shared, non-private metadata here (an
    Access app description, say), so an unreadable, unsafe or malformed file
    is not an error: it yields None."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    with os.fdopen(fd, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            return None
        data = source.read(limit + 1)
    if len(data) > limit:
        return None
    try:
        return json.loads(data)
    except (UnicodeError, ValueError):
        return None


def tunnel_id(value):
    if not isinstance(value, str):
        raise Unsafe("invalid tunnel identity")
    try:
        parsed = str(uuid.UUID(value))
    except ValueError:
        raise Unsafe("invalid tunnel identity") from None
    if parsed != value:
        raise Unsafe("tunnel identity must be a canonical UUID")
    return value


def ensure_port_free(port):
    """Raise OSError if a process listens on 127.0.0.1:port.

    SO_REUSEADDR only lets the probe past TIME_WAIT sockets left by the health
    timer's /ready checks (up to 60 s after each probe); without it every
    restart, including automatic recovery, waited out that window with the
    public API down. Linux still refuses the bind while anyone listens.
    """
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", port))


def local_http(port, method, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
    try:
        connection.request(method, path, body=b"" if method == "POST" else None)
        response = connection.getresponse()
        body = response.read(4097)
        if len(body) > 4096:
            raise Unsafe("local health response exceeds limit")
        return response.status, body
    finally:
        connection.close()


class ConsumerTunnel:
    def __init__(self, root):
        self.root = Path(os.path.abspath(root))
        self.binary = self.root / "bin/cloudflared"
        self.config = self.root / "cloudflared/consumer-config.json"
        self.credentials = self.root / "cloudflared/consumer-credentials.json"
        self.pidfile = self.root / "run/api-tunnel.pid"
        self.logfile = self.root / "logs/api-tunnel.log"
        self.hostname = None  # set by validate() from the consumer config

    def command(self, ident):
        return [str(self.binary), "tunnel", "--config", str(self.config),
                "--protocol", "quic", "--no-autoupdate", "--metrics",
                f"127.0.0.1:{METRICS_PORT}", "run", tunnel_id(ident)]

    @staticmethod
    def environment():
        # An inherited token/URL must not override this locally managed config.
        return {key: value for key, value in os.environ.items()
                if not key.startswith(("TUNNEL_", "CF_"))}

    def validate(self):
        checked_directory(self.root)
        config = read_json(self.config)
        if (not isinstance(config, dict)
                or set(config) != {"tunnel", "credentials-file", "ingress"}
                or config["credentials-file"] != str(self.credentials)):
            raise Unsafe("consumer config must contain only the fixed API ingress and final 404")
        self.hostname = ingress_hostname(config["ingress"])
        ident = tunnel_id(config["tunnel"])
        credentials = read_json(self.credentials)
        if (not isinstance(credentials, dict)
                or set(credentials) != {"AccountTag", "TunnelSecret", "TunnelID"}
                or credentials["TunnelID"] != ident
                or not isinstance(credentials["AccountTag"], str)
                or not re.fullmatch(r"[0-9a-f]{32}", credentials["AccountTag"])):
            raise Unsafe("consumer credentials do not match this tunnel")
        try:
            secret = base64.b64decode(credentials["TunnelSecret"], validate=True)
        except (ValueError, TypeError):
            raise Unsafe("invalid consumer credential format") from None
        if len(secret) != 32:
            raise Unsafe("invalid consumer credential format")
        # Another tunnel's credential kept beside this one (it may serve other
        # origins on the same host) must never share the consumer identity.
        for other in sorted(self.credentials.parent.glob("*.json")):
            if other in (self.config, self.credentials):
                continue
            other_credential = peek_json(other)
            if isinstance(other_credential, dict) and other_credential.get("TunnelID") == ident:
                raise Unsafe("consumer tunnel must not reuse another tunnel's identity")
        try:
            api = tomllib.loads(read_file(self.root / "config.toml").decode())["api"]
        except (ValueError, KeyError, UnicodeError):
            raise Unsafe("invalid API configuration") from None
        if not isinstance(api, dict) or (api.get("host"), api.get("port"), api.get("auth_mode")) != (
                "127.0.0.1", 8083, "keys"):
            raise Unsafe("start requires API keys mode on 127.0.0.1:8083")
        for executable in (self.binary, self.root / "bin/oliv-keys"):
            fd = open_checked(executable, os.O_RDONLY)
            try:
                if not os.fstat(fd).st_mode & stat.S_IXUSR:
                    raise Unsafe("required OLIV binary is not executable")
            finally:
                os.close(fd)
        result = subprocess.run(
            [str(self.root / "bin/oliv-keys"), "--root", str(self.root), "list"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=False)
        if result.returncode:
            raise Unsafe("API key store validation failed")
        result = subprocess.run(
            [str(self.binary), "tunnel", "--config", str(self.config), "ingress", "validate"],
            env=self.environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=5, check=False)
        if result.returncode:
            raise Unsafe("cloudflared rejected the consumer ingress configuration")
        return ident

    def identity(self, pid, ident):
        if type(pid) is not int or pid <= 1:
            raise Unsafe("invalid consumer PID")
        proc = PROC / str(pid)
        try:
            before = (proc / "stat").read_text().rsplit(")", 1)[1].split()
            if before[0] == "Z":
                return None
            argv = (proc / "cmdline").read_bytes().rstrip(b"\0").split(b"\0")
            executable = os.readlink(proc / "exe").removesuffix(" (deleted)")
            info = (proc / "exe").stat()
            uids = next(line.split()[1:] for line in (proc / "status").read_text().splitlines()
                        if line.startswith("Uid:"))
            after = (proc / "stat").read_text().rsplit(")", 1)[1].split()
            if (argv != [os.fsencode(arg) for arg in self.command(ident)]
                    or executable != str(self.binary)
                    or any(int(uid) != os.geteuid() for uid in uids)
                    or len(uids) != 4 or before[19] != after[19]):
                raise Unsafe("PID does not identify this exact OLIV consumer tunnel")
            return {"version": 1, "pid": pid, "uid": os.geteuid(), "tunnel_id": ident,
                    "start_time": after[19], "exe_dev": info.st_dev, "exe_ino": info.st_ino,
                    "boot_id": (PROC / "sys/kernel/random/boot_id").read_text().strip()}
        except (FileNotFoundError, ProcessLookupError):
            return None
        except (IndexError, StopIteration, UnicodeError, ValueError):
            raise Unsafe("could not validate consumer process identity") from None

    def read_record(self):
        record = read_json(self.pidfile)
        fields = {"version", "pid", "uid", "tunnel_id", "start_time", "exe_dev", "exe_ino", "boot_id"}
        if (not isinstance(record, dict) or set(record) != fields or record["version"] != 1
                or any(type(record[k]) is not int for k in ("pid", "uid", "exe_dev", "exe_ino"))
                or record["pid"] <= 1 or record["uid"] != os.geteuid()
                or not isinstance(record["start_time"], str) or not record["start_time"].isdigit()
                or not isinstance(record["boot_id"], str)):
            raise Unsafe("invalid consumer PID record; no process was signalled")
        tunnel_id(record["tunnel_id"])
        return record

    def write_record(self, record):
        checked_directory(self.pidfile.parent)
        fd, name = tempfile.mkstemp(prefix=".api-tunnel.", dir=self.pidfile.parent)
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(record, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(name, self.pidfile)
        finally:
            Path(name).unlink(missing_ok=True)

    def stop_record(self, record):
        """Use a pidfd so PID recycling cannot redirect our signal or wait."""
        try:
            fd = os.pidfd_open(record["pid"])
        except ProcessLookupError:
            return
        try:
            current = self.identity(record["pid"], record["tunnel_id"])
            if current is None:
                return
            if current != record:
                raise Unsafe("consumer PID identity changed; no process was signalled")
            signal.pidfd_send_signal(fd, signal.SIGTERM)
            if not select.select([fd], [], [], STOP_TIMEOUT)[0]:
                raise Unsafe("consumer tunnel did not exit after TERM; no force kill was sent")
        finally:
            os.close(fd)

    def stop(self):
        try:
            record = self.read_record()
        except FileNotFoundError:
            print("api-tunnel has no managed PID record; no process was signalled")
            return
        self.stop_record(record)
        self.pidfile.unlink()
        print("api-tunnel stopped")

    def owns_metrics(self, pid):
        """Readiness belongs to this process, and its TCP listeners stay local."""
        proc = PROC / str(pid)
        sockets = set()
        for fd in (proc / "fd").iterdir():
            try:
                target = os.readlink(fd)
            except FileNotFoundError:
                continue
            if target.startswith("socket:["):
                sockets.add(target[8:-1])
        listeners = []
        for name in ("tcp", "tcp6"):
            for line in (proc / "net" / name).read_text().splitlines()[1:]:
                fields = line.split()
                if fields[3] == "0A" and fields[9] in sockets:
                    listeners.append((name, fields[1]))
        return listeners == [("tcp", f"0100007F:{METRICS_PORT:04X}")]

    def start(self):
        ident = self.validate()
        for directory in (self.pidfile.parent, self.logfile.parent):
            directory.mkdir(mode=0o700, exist_ok=True)
            checked_directory(directory)
        if local_http(8083, "GET", "/health") != (200, b'{"ok":true}'):
            raise Unsafe("loopback API minimal health check failed")
        if local_http(8083, "POST", "/v1/dictate")[0] != 401:
            raise Unsafe("loopback API must reject missing credentials")
        if self.pidfile.exists() or self.pidfile.is_symlink():
            record = self.read_record()
            # A PID from another boot may now belong to an unrelated process.
            # Discard that record without inspecting or signalling its PID.
            boot_id = (PROC / "sys/kernel/random/boot_id").read_text().strip()
            current = (self.identity(record["pid"], record["tunnel_id"])
                       if record["boot_id"] == boot_id else None)
            if current is not None:
                if current != record or record["tunnel_id"] != ident:
                    raise Unsafe("existing consumer PID/config identity differs; review before restart")
                if not self.owns_metrics(record["pid"]) or local_http(METRICS_PORT, "GET", "/ready")[0] != 200:
                    raise Unsafe("managed consumer tunnel is running but not ready")
                print("api-tunnel already running and ready")
                return
            self.pidfile.unlink()
        # Refuse to start over a lost PID record or somebody else's metrics port.
        ensure_port_free(METRICS_PORT)
        with os.fdopen(open_checked(self.logfile, os.O_WRONLY | os.O_CREAT | os.O_APPEND,
                                    private=True), "ab", buffering=0) as log:
            process = subprocess.Popen(self.command(ident), stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT, env=self.environment(),
                                       start_new_session=True, close_fds=True)
        record = None
        try:
            record = self.identity(process.pid, ident)
            if record is None:
                raise Unsafe("consumer tunnel exited before its identity was recorded")
            self.write_record(record)
            deadline = time.monotonic() + START_TIMEOUT
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise Unsafe("consumer tunnel exited during startup; inspect its private log")
                try:
                    if (self.identity(process.pid, ident) == record and self.owns_metrics(process.pid)
                            and local_http(METRICS_PORT, "GET", "/ready")[0] == 200):
                        print("api-tunnel ready for " + (self.hostname or "its configured hostname"))
                        return
                except (OSError, http.client.HTTPException):
                    pass
                time.sleep(0.2)
            raise Unsafe("consumer tunnel readiness deadline exceeded")
        except BaseException:
            if record is not None:
                self.stop_record(record)
                self.pidfile.unlink(missing_ok=True)
            elif process.poll() is None:
                # This is our direct, still-unreaped Popen child, not a PID read
                # from a file. Its PID cannot be recycled before we wait for it.
                # Clean up even if recording its /proc identity failed early.
                process.terminate()
                process.wait(timeout=STOP_TIMEOUT)
            raise


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("start", "stop", "check"):
        print("usage: consumer_tunnel.py start|stop|check", file=sys.stderr)
        return 2
    action = sys.argv[1]
    if action != "check" and os.environ.get("OLIV_HAVE_LOCK") != "1":
        print("use start.sh/stop.sh api-tunnel under the OLIV action lock", file=sys.stderr)
        return 2
    try:
        tunnel = ConsumerTunnel(Path(__file__).absolute().parent)
        if action == "check":
            tunnel.validate()
            print("consumer tunnel configuration is valid")
        else:
            getattr(tunnel, action)()
    except Unsafe as exc:
        print("api-tunnel: " + str(exc), file=sys.stderr)
        return 1
    except (OSError, subprocess.SubprocessError, http.client.HTTPException):
        # Neither parser errors nor subprocess output may print credentials.
        print("api-tunnel action failed; check its private files, process identity and readiness", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
