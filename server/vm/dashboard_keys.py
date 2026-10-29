"""Dashboard key administration through the existing oliv-keys authority only."""

import copy
import json
import os
import re
import stat
import subprocess
import tempfile
import time
import unicodedata
from pathlib import Path

SCOPES = ["dictate", "clean", "status"]
DEFAULTS = {"expires_in_days": 90, "scopes": ["dictate"],
            "requests_per_minute": 10, "daily_requests": 500}
LIMITS = {"max_keys": 256, "name_utf8_bytes": 120,
          "expires_in_days": {"min": 1, "max": 3650},
          "requests_per_minute": {"min": 1, "max": 10000},
          "daily_requests": {"min": 1, "max": 1000000}, "scopes": SCOPES}
ID = re.compile(r"[0-9a-f]{16}\Z")
TOKEN = re.compile(r"oliv_([0-9a-f]{16})_[0-9a-f]{64}\Z")
INFO_FIELDS = {"id", "name", "created_at", "expires_at", "revoked", "scopes",
               "requests_per_minute", "daily_requests"}


class KeyAdminError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code


def invalid(message):
    return KeyAdminError(400, "invalid_request", message)


def unavailable():
    return KeyAdminError(503, "key_management_unavailable", "API key management is unavailable")


def validate_options(posted):
    if not isinstance(posted, dict) or set(posted) - {"name", *DEFAULTS}:
        raise invalid("Unknown key creation fields")
    name = posted.get("name")
    try:
        name_bytes = len(name.encode("utf-8")) if isinstance(name, str) else 0
    except UnicodeError:
        raise invalid("Name must contain valid UTF-8 text") from None
    if (not isinstance(name, str) or not name.strip()
            or name_bytes > LIMITS["name_utf8_bytes"]
            or any(unicodedata.category(char) == "Cc" for char in name)):
        raise invalid("Name must contain 1–120 UTF-8 bytes without control characters")
    options = {**copy.deepcopy(DEFAULTS), **posted}
    scopes = options["scopes"]
    if (not isinstance(scopes, list) or not 1 <= len(scopes) <= len(SCOPES)
            or any(not isinstance(scope, str) or scope not in SCOPES for scope in scopes)
            or len(set(scopes)) != len(scopes)):
        raise invalid("Choose unique scopes from dictate, clean and status")
    for field in ("expires_in_days", "requests_per_minute", "daily_requests"):
        value = options[field]
        if type(value) is not int or not LIMITS[field]["min"] <= value <= LIMITS[field]["max"]:
            raise invalid(f"{field} is outside the supported range")
    return options


def safe_info(value, now):
    """Whitelist metadata even if a future CLI adds fields to its list output."""
    try:
        info = {field: value[field] for field in INFO_FIELDS}
        if (not isinstance(info["id"], str) or not ID.fullmatch(info["id"])
                or type(info["revoked"]) is not bool
                or any(type(info[field]) is not int or info[field] < 0
                       for field in ("created_at", "expires_at"))
                or info["expires_at"] <= info["created_at"]):
            raise unavailable()
        validate_options({field: info[field] for field in
                          ("name", "scopes", "requests_per_minute", "daily_requests")})
    except (KeyError, TypeError, KeyAdminError):
        raise unavailable() from None
    info["status"] = ("revoked" if info["revoked"] else
                      "expired" if info["expires_at"] <= now else "active")
    return info


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise invalid("Duplicate JSON field")
        result[key] = value
    return result


class KeyManager:
    def __init__(self, root):
        self.root = Path(root)
        self.binary = self.root / "bin/oliv-keys"

    def cli(self, *args):
        try:
            info = self.binary.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or info.st_mode & 0o022 or not info.st_mode & stat.S_IXUSR):
                raise unavailable()
            result = subprocess.run([str(self.binary), "--root", str(self.root), *args],
                                    stdin=subprocess.DEVNULL, capture_output=True,
                                    timeout=10, check=False)
        except (OSError, subprocess.SubprocessError):
            raise unavailable() from None
        if result.returncode or len(result.stdout) > 1024 * 1024:
            raise unavailable()
        return result.stdout

    def keys(self):
        try:
            listed = json.loads(self.cli("list"), object_pairs_hook=unique_object)
            if not isinstance(listed, list) or len(listed) > LIMITS["max_keys"]:
                raise unavailable()
            now = int(time.time())
            keys = [safe_info(item, now) for item in listed]
            if len({key["id"] for key in keys}) != len(keys):
                raise unavailable()
            return keys
        except (ValueError, UnicodeError, RecursionError, KeyAdminError):
            raise unavailable() from None

    def listing(self):
        keys = self.keys()
        summary = {"total": len(keys), "active": 0, "expired": 0, "revoked": 0}
        for key in keys:
            summary[key["status"]] += 1
        from dashboard_usage import summaries
        usage_error = None
        try:
            usage = summaries(self.root)
        except KeyAdminError:
            usage = None
            usage_error = "Usage history is unavailable"
        if usage is not None:
            for key in keys:
                key["usage"] = usage["keys"].get(key["id"], {
                    "total": 0, "successful": 0, "failed": 0, "quota_charged": 0,
                    "today": 0, "today_charged": 0, "last_used": None})
        return {"ok": True, "keys": keys, "summary": summary,
                "defaults": copy.deepcopy(DEFAULTS), "limits": copy.deepcopy(LIMITS),
                "usage_available": usage is not None, "usage_error": usage_error,
                "recording_since": usage["recording_since"] if usage else None,
                "day_start": usage["day_start"] if usage else None}

    @staticmethod
    def read_export(path):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as source:
                info = os.fstat(source.fileno())
                if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600
                        or info.st_uid != os.geteuid() or info.st_nlink != 1):
                    raise unavailable()
                raw = source.read(257)
            token = raw.decode("ascii").removesuffix("\n")
            if len(raw) > 256 or not TOKEN.fullmatch(token):
                raise unavailable()
            return token
        except (OSError, UnicodeError):
            raise unavailable() from None

    def create(self, posted):
        options = validate_options(posted)
        if len(self.keys()) >= LIMITS["max_keys"]:
            raise KeyAdminError(409, "key_store_full", "Key store is full, including revoked keys")
        # CLI creates a NEW mode-600 file in this private directory. It is
        # removed on every exit, including export/list errors after CLI success.
        created_id = None
        try:
            with tempfile.TemporaryDirectory(prefix=".dashboard-key-", dir=self.root) as directory:
                out = Path(directory) / "new.key"
                try:
                    result = self.cli("create", "--name", options["name"], "--out", str(out),
                                      "--scopes", ",".join(options["scopes"]),
                                      "--expires-in-days", str(options["expires_in_days"]),
                                      "--requests-per-minute", str(options["requests_per_minute"]),
                                      "--daily-requests", str(options["daily_requests"]))
                    match = re.fullmatch(
                        rb"Created key ([0-9a-f]{16})\. Credential saved to the private output file\.\n",
                        result)
                    if match:
                        created_id = match[1].decode("ascii")
                    token = self.read_export(out)
                    ident = TOKEN.fullmatch(token)[1]
                    if ident != created_id:
                        raise unavailable()
                    key = next((item for item in self.keys() if item["id"] == ident), None)
                    if key is None or key["status"] != "active":
                        raise unavailable()
                    return {"ok": True, "key": key, "token": token}
                except KeyAdminError:
                    # A timed-out CLI may already have committed. Recover only
                    # our private export's ID, never diff other operators' keys.
                    if created_id is None:
                        try:
                            created_id = TOKEN.fullmatch(self.read_export(out))[1]
                        except KeyAdminError:
                            pass
                    if created_id is not None:
                        try:
                            self.cli("revoke", created_id)
                        except KeyAdminError:
                            raise KeyAdminError(503, "key_creation_incomplete",
                                                "Key creation could not finish; inspect recent keys and revoke before retrying") from None
                    raise
        except OSError:
            if created_id is not None:
                try:
                    self.cli("revoke", created_id)
                except KeyAdminError:
                    raise KeyAdminError(503, "key_creation_incomplete",
                                        "Key creation could not finish; inspect recent keys and revoke before retrying") from None
            raise unavailable() from None

    def revoke(self, posted):
        if (not isinstance(posted, dict) or set(posted) != {"id"}
                or not isinstance(posted["id"], str) or not ID.fullmatch(posted["id"])):
            raise invalid("Provide one valid key ID")
        ident = posted["id"]
        if not any(key["id"] == ident for key in self.keys()):
            raise KeyAdminError(404, "not_found", "Key not found")
        self.cli("revoke", ident)
        key = next((item for item in self.keys() if item["id"] == ident), None)
        if key is None or key["status"] != "revoked":
            raise unavailable()
        return {"ok": True, "key": key}
