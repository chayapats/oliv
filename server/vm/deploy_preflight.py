#!/usr/bin/env python3
"""Read-only migration guard, also sent over SSH stdin before deployment writes.

This checks explicit intent and credential-file permissions, not the key schema.
The staged oliv-keys binary validates that schema before binary activation.
"""

import hashlib
import ipaddress
import stat
import sys
import tomllib
from pathlib import Path


def private_overlay(host):
    """An IPv4 literal in 100.64.0.0/10 (Tailscale/Headscale-style overlays).

    Mirrors oliv_config.is_private_overlay; this file runs standalone over SSH.
    """
    if not isinstance(host, str):
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return (address.version == 4 and str(address) == host
            and address in ipaddress.ip_network("100.64.0.0/10"))


def preflight(root):
    root = Path(root)
    config_bytes = (root / "config.toml").read_bytes()
    config = tomllib.loads(config_bytes.decode("utf-8"))
    api = config.get("api")
    if not isinstance(api, dict) or "auth_mode" not in api:
        raise ValueError(
            "migration required: set [api].auth_mode explicitly before deployment; "
            "keep host=<private overlay IP> with auth_mode=legacy for a private-only upgrade, "
            "or prepare individual keys and auth_mode=keys. See docs/PUBLIC-API.md. "
            "No remote files or services have been changed."
        )
    host = api.get("host")
    mode = api.get("auth_mode")
    if (host != "127.0.0.1" and not private_overlay(host)) or api.get("port") != 8083:
        raise ValueError("API must use loopback or a private overlay IP on port 8083")
    if mode not in ("keys", "legacy"):
        raise ValueError("api.auth_mode must be keys or legacy")
    if mode == "legacy" and not private_overlay(host):
        raise ValueError("legacy auth is allowed only on a private overlay IP")
    credential = root / ("api-keys.json" if mode == "keys" else "api.token")
    info = credential.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError(f"{credential.name} must be a regular file with mode 600")
    if mode == "legacy":
        token = credential.read_bytes().strip()
        if len(token) < 32 or not all(0x21 <= byte <= 0x7e for byte in token):
            raise ValueError("api.token must contain at least 32 printable ASCII characters")
    return host, mode, hashlib.sha256(config_bytes).hexdigest()


def main():
    if len(sys.argv) != 2:
        print("usage: deploy_preflight.py ROOT", file=sys.stderr)
        return 2
    try:
        host, mode, digest = preflight(Path(sys.argv[1]).expanduser())
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f"deployment preflight: {exc}", file=sys.stderr)
        return 1
    print(host, mode, digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
