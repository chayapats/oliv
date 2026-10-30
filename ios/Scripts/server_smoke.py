#!/usr/bin/env python3
"""Opt-in synthetic-audio server check; never prints credentials or transcripts."""
import argparse
import base64
import json
import ipaddress
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from pathlib import Path

USER_AGENT = "oliv-ios/0.1.0"
REQUEST_TIMEOUT = 120
MAX_RESPONSE_BYTES = 1024 * 1024

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--wav", required=True, type=Path, help="Synthetic 16k mono PCM audio only")
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        parser.error("Supply a plain OLIV base URL.")
    if parsed.scheme == "http":
        host = parsed.hostname.lower()
        private = host == "localhost" or host.endswith(".local")
        try:
            address = ipaddress.ip_address(host)
            ranges = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
                      "127.0.0.0/8", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10")
            private = any(address in ipaddress.ip_network(block) for block in ranges)
        except ValueError:
            pass
        if not private:
            parser.error("Public servers require HTTPS. HTTP is limited to local/private VPN addresses.")
    try:
        token = args.token_file.read_text().strip()
    except (OSError, UnicodeError):
        parser.error("Could not read the API key file.")
    if not token or any(ord(c) < 33 or ord(c) > 126 for c in token):
        parser.error("Invalid token file.")
    try:
        with wave.open(str(args.wav), "rb") as audio:
            if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
                parser.error("Audio must be 16 kHz mono 16-bit PCM WAV.")
            duration = audio.getnframes() / audio.getframerate()
            if not 0 < duration <= 120:
                parser.error("Audio must be nonempty and at most 120 seconds.")
    except (OSError, EOFError, wave.Error):
        parser.error("Could not read a valid PCM WAV file.")
    opener = urllib.request.build_opener(NoRedirect())
    def request(path, body=None, maximum_bytes=MAX_RESPONSE_BYTES):
        encoded = json.dumps(body).encode() if body is not None else None
        headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
        if body is not None:
            headers.update({"Content-Type": "application/json", "Authorization": "Bearer " + token})
        req = urllib.request.Request(args.url.rstrip("/") + path, encoded, headers)
        with opener.open(req, timeout=REQUEST_TIMEOUT) as response:
            if response.status != 200:
                raise ValueError("Unexpected HTTP success status.")
            data = response.read(maximum_bytes + 1)
            if len(data) > maximum_bytes:
                raise ValueError("Oversized response.")
            result = json.loads(data)
            if not isinstance(result, dict):
                raise ValueError("Expected a JSON object.")
            return result
    try:
        health = request("/health", maximum_bytes=8192)
        if health.get("ok") is not True:
            raise ValueError("API liveness check failed.")
        # Public health says nothing about key scopes or inference readiness.
        print(json.dumps({"health_ok": True, "liveness_only": True}))
        started = time.monotonic()
        reply = request("/v1/dictate", {"wav_b64": base64.b64encode(args.wav.read_bytes()).decode(),
            "cleanup": True, "remove_fillers": True, "thai_format": True, "vocabulary": [], "replacements": {}})
        if reply.get("ok") is not True:
            raise ValueError("Malformed dictation response.")
        if "no_speech" in reply and not isinstance(reply["no_speech"], bool):
            raise ValueError("Malformed no-speech response.")
        if "raw" in reply and not isinstance(reply["raw"], str):
            raise ValueError("Malformed raw text.")
        if "final" in reply:
            if not isinstance(reply["final"], str):
                raise ValueError("Malformed final text.")
            final_text = reply["final"]
        elif reply.get("no_speech") is True:
            final_text = ""
        else:
            raise ValueError("Missing dictation text.")
        if reply.get("cleanup_error") is not None and not isinstance(reply["cleanup_error"], str):
            raise ValueError("Malformed cleanup status.")
        print(json.dumps({"ok": True, "audio_seconds": round(duration, 3),
            "round_trip_seconds": round(time.monotonic()-started, 3),
            "output_characters": len(final_text), "no_speech": reply.get("no_speech", False),
            "cleanup_fallback": bool(reply.get("cleanup_error"))}))
    except urllib.error.HTTPError as error:
        raise SystemExit("HTTP " + str(error.code) + "; credentials and response body omitted.") from None
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        raise SystemExit("Connection or response validation failed; sensitive details omitted.") from None

if __name__ == "__main__":
    main()
