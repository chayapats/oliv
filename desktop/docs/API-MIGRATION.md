# Server API, transport and troubleshooting

How the desktop client talks to an OLIV server (`oliv-api`), what it does on failure,
and how to upgrade a client that used an old shared token or a plain-HTTP private
URL. Server-side details (keys, scopes, limits) live with the server in
[`../../server/`](../../server/).

## Contract used by the client

| Route | Client behaviour |
|---|---|
| `GET /health` | No key sent. `{"ok":true}` is liveness only; `oliv health` runs it on demand and nothing gates dictation on it. |
| `POST /v1/dictate` | `Authorization: Bearer <individual key>`; the `dictate` scope already covers cleanup. |
| `POST /v1/clean` | Not used by the client (needs scope `clean`). |
| `/v1/status`, admin/model routes | Never called, never used as a preflight. |

The JSON body is `wav_b64`, `cleanup`, `remove_fillers`, `thai_format`, `vocabulary`,
`replacements` (replacement order preserved). No `prompt` is sent, so the server
default applies. Audio is RIFF/WAVE PCM signed 16-bit little-endian, mono, 16 kHz, at
most 120 seconds; no multipart or compressed audio.

A reply is accepted only as HTTP 200 with `ok:true` and a string `final` (or
`no_speech:true`). `{"ok":true}` alone is not a dictation. `no_speech` or an empty
`final` is not pasted; a `final` with `cleanup_error` (LLM fallback) is still used.

## Upgrading an existing install

1. Get a **new individual key** with scope `dictate` from your server operator. Shared
   tokens and the server's legacy auth mode are for migration only.
2. Let any recording/upload finish before installing the new binary. If you back up
   the config, keep the copy private (mode `600`) and outside any repository.
3. Edit only `[server]` in your config with an editor (not a shell command), and
   **keep your `[dictate]`, vocabulary and `[replacements]`**:

   ```toml
   [server]
   url = "https://oliv.example.com"
   token = "PUT-YOUR-INDIVIDUAL-KEY-HERE"
   timeout_seconds = 120
   ```

4. Linux:

   ```sh
   chmod 700 "${XDG_CONFIG_HOME:-$HOME/.config}/oliv"
   chmod 600 "${XDG_CONFIG_HOME:-$HOME/.config}/oliv/config.toml"
   desktop/deploy/install-client.sh
   oliv health
   oliv status
   ```

   Windows: re-run `install-client.ps1` (see [WINDOWS.md](WINDOWS.md)); it keeps the
   config and data.
5. Dictate once in the target app and check `oliv last`. If old recordings are
   pending, run `oliv retry` after fixing the key/connection and any cooldown.

The TOML field is still called `token` for compatibility. Without `timeout_seconds`
the client uses 120 s (whole seconds, 10–180), covering upload through reading the
whole reply. Do not copy the example over an existing custom config.

## Transport and retry

- Production uses `ureq` + `rustls` with WebPKI roots: normal chain and hostname
  verification. There is no insecure mode, custom-CA option or HTTP fallback.
- Every request sends `User-Agent: oliv-linux/<version>` or
  `oliv-windows/<version>` (the Cargo package version), never a browser string.
  Edge proxies such as Cloudflare's browser-integrity check may block generic
  library user agents.
- All redirects (301/302/303/307/308) are rejected; the key and audio are never sent
  to a `Location`.
- Plain HTTP is accepted only for explicit local/private development URLs:
  `localhost`, IPv4 loopback, `::1`, RFC1918 IPv4 and CGNAT `100.64.0.0/10`. Public
  HTTP and other private-looking DNS names are refused.
- A single worker plus a request file lock means one user's daemon and CLI send one
  inference at a time. The retry lock spans read WAV → request → delete after success
  → history, so concurrent `retry` runs never send the same file twice. Using one key
  on several machines can still collide: use one key per device.
- No automatic inference retry: a failed job keeps its audio; `oliv retry` stops at
  the first failing file.
- `429` honours `Retry-After` as seconds or an HTTP date; missing/invalid means 60 s
  (minimum 1 s). A `5xx` with `Retry-After` also waits. The deadline is saved in the
  state directory as `retry-after` (private, contains only an epoch time, never a
  key), shared by the daemon and the CLI, and survives restarts. During it, new
  recordings go straight to `pending/` without calling the API. Changing key/URL
  intentionally does not clear it; do not delete it to get around a quota.
- `retry` prints to stdout and writes history without pasting; when exactly one text
  was recovered it is copied to the clipboard. A failed copy never re-sends
  inference; the text stays in `oliv last`/history.
- Known limits: the daemon keeps audio in RAM until a send fails, so a crash or power
  loss while recording/sending can lose it; `retry` deletes the WAV after API success
  but before history/clipboard. The API has no idempotency key, so exactly-once
  inference is not claimed if the server succeeded but the reply was lost.

## Troubleshooting

Details are on stderr of `oliv retry`, in the user journal on Linux
(`journalctl --user -u oliv.service -n 50 --no-pager`) or in
`%LOCALAPPDATA%\oliv\daemon.stderr.log` on Windows. The overlay shows a short hint and
whether the audio was kept. Diagnostics never print the key, response bodies or
audio. Check logs for private data before sharing, and never attach your config,
pending WAVs or history.

| Symptom | What to do |
|---|---|
| `401` | Key wrong, expired or revoked: check it or ask for a new one, then edit `server.token`. |
| `403` JSON `API key does not allow this operation` | Ask for scope `dictate` (you do not need `clean` for cleanup during dictation). |
| `403` with `error code: 1010` or a Cloudflare page | Blocked at the edge: tell the operator your client version. Do not fake a browser User-Agent or disable TLS verification. |
| Other `403` | Scope or edge policy; ask the operator. |
| `429` / `API cooldown` | Wait the stated time. Do not loop `retry` or share a key across devices. |
| `400` / `415` | Check the request/WAV: PCM16 mono 16 kHz, not just a renamed file. |
| `413` | Record a shorter clip (120 s limit); do not retry the same input repeatedly. |
| network/TLS error | Check the URL, network, system clock, certificate and hostname. Never use insecure TLS or public HTTP. |
| timeout / `5xx` / malformed reply | The WAV stays pending; `oliv retry` once the server recovers. Timeout is set in `[server]`. |
| `redirect rejected` | Configure the final HTTPS base URL directly, not a login/dashboard URL. |
| `oliv health` passes but dictation fails | Health only shows the API process answers; it does not check the key, STT, LLM or pipeline. |
| config must be mode 600 (Linux) | `chmod 600` as above. TOML errors hide values so a key is never echoed. |

`oliv status` asks the local daemon (Unix socket or named pipe); it does not call
`/v1/status` and there is no need to wait for health before dictating.

## Verifying a change

From `desktop/`:

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
cargo tree --locked -e features -i rustls
```

The TLS unit tests create a throwaway CA/certificate and handshake on loopback:
trusted CA, untrusted certificate, wrong hostname and redirect rejection (trusting a
test CA exists only under `#[cfg(test)]`). The CLI tests run the real binary in
temporary config/state directories against a mock HTTP server and cover
Authorization/User-Agent, minimal health, non-JSON/oversized errors, timeout, pending
recovery, cooldown, history, vocabulary/replacements and concurrent retry, using
synthetic silence and a test key. On Linux `wl-copy`/`hyprctl` are stubbed so the
real clipboard/desktop is untouched.

Desktop behaviour still needs a manual pass: Right Shift/Left Shift/cancel,
microphone, overlay states, Thai paste into terminal/browser/editor, clipboard
restore, recording while a send is in flight, offline → pending → retry, and service
start after reboot.
