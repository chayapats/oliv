# OLIV operator dashboard

`vm/dashboard.py` is a small operator panel (UI in Thai) for one OLIV server:
model status and settings, GPU/VRAM estimate, test requests, and API key
management with per-key usage. It runs as `oliv-dashboard.service` and binds
`127.0.0.1:8090` only.

**It has no login of its own.** Anyone who can reach port 8090 can create and
revoke keys and restart models. Open it through an SSH port forward:

```sh
ssh -L 8090:127.0.0.1:8090 <server>
# then browse http://127.0.0.1:8090
```

or put it behind an authenticating reverse proxy (for example Cloudflare
Access in front of a separate tunnel). Never route public ingress to 8090, and
never give API users dashboard access so they can dictate.

API users only need the server's base URL and their own key. The dashboard
shows the URL from `cloudflared/consumer-config.json` when the bundled tunnel
is provisioned, and `https://oliv.example.com` otherwise.

## Issuing a key for a person or a new device

1. Open **API keys** and create a key. Name it after the person/device (for
   example `alice-windows`) without unnecessary personal details.
2. Choose scopes, expiry and quotas. Defaults: `dictate`, 90 days,
   10 requests/minute, 500 requests/day.
3. Copy the key from the result page before closing it; it is shown only once.
   Send the URL and key to the device owner over a private channel.
4. The client puts the URL in `server.url` and the key in `server.token`
   (Windows/Linux), or in Settings ▸ Cloud services ▸ OLIV API (Mac).

| Scope | Use |
|---|---|
| `dictate` | Dictation and the text pipeline with the client's options, including cleanup. Right for normal users. |
| `clean` | Direct text cleanup, `/v1/clean`. |
| `status` | Internal status, `/v1/status`; not exposed through public ingress, not needed by normal users. |

If you close the result page before saving the key, it cannot be shown again:
revoke that entry and issue a new one. If the network drops after you submit,
check the latest entries before retrying, because the key may have been
created. The backend tries to revoke automatically when writing the response
fails for certain, but cannot detect every lost response. The dashboard never
stores raw keys in localStorage/sessionStorage, and the server deletes the
one-time export file after reading it; only hashes and metadata persist in
`api-keys.json`. Downloading or copying a key leaves a copy on the operator's
device/clipboard.

## Reviewing and revoking

The key list shows name, ID, scopes, issue/expiry times, configured quotas and
active/expired/revoked state; search and filter before confirming a
revocation. Revocation is permanent; issue a new key if access is needed again.

The API re-reads the key store per request, so no restart is needed after
issuing or revoking. A request that was already authorized and running may
finish. Revocation keeps the key's metadata.

The keys page shows requests today (UTC), totals, successes/errors, quota
charged today and last use, with the date recording started. Totals include
every request whose token hash matched the key, even if the key was expired,
revoked or lacked the scope; requests with a wrong token are never attributed
to the ID they claim. Configured quotas are ceilings, not remaining balances.
Admission counters live in RAM and reset when the API restarts, while history
is persistent, so a day's history can exceed the daily ceiling after a restart.

**Logs** on a key (or the key/result/UTC-date filters) shows per-request
history: time, row ID, route, HTTP status, elapsed ms, whether it was charged,
no-speech and cleanup fallback, 100 rows per page, with CSV download of the
current page. History lives in `~/oliv/usage/requests.sqlite3` (SQLite WAL,
directory 700, DB 600). It contains no tokens/hashes, IP addresses, headers,
audio or transcripts and is never pruned automatically. Back it up with the
SQLite backup API while the service runs; don't copy the DB file alone and
ignore the WAL.

History records requests the transport processed to an HTTP response,
including upload/processing timeouts. `/health`, malformed HTTP cut off before
dispatch, and connections over capacity are not recorded; if the API crashes
before responding, the last request is missing. A failed history write logs
`usage audit write failed` in the API log without changing the dictation
result. It is an operational audit, not a billing ledger.

The key store holds at most 256 entries including revoked ones. When it is
full, issuing stops; nothing is pruned automatically. Auth and quota details:
[PUBLIC-API.md](PUBLIC-API.md).

## Models

The overview shows Gemma, ASR, API and GPU status. Settings edits the model
runtime values with a VRAM estimate and a preview before apply. Start, stop,
restart and apply affect the live services; they go through
`start.sh`/`stop.sh` and the shared action lock. The tests page sends text or
an audio file of the operator's choosing. The public `/health` only proves the
API answers, not the whole inference pipeline.

Listing, issuing and revoking keys never changes config, models or the
consumer tunnel.

## Code and HTTP routes for developers

| File | Role |
|---|---|
| [dashboard.html](../vm/dashboard.html) | Single-file UI/JavaScript, no external assets/CDN |
| [dashboard.py](../vm/dashboard.py) | HTTP handler, body validation, action lock, model controls |
| [dashboard_keys.py](../vm/dashboard_keys.py) | Validates options and calls `bin/oliv-keys` with a fixed argv; separates metadata reads from the one-time secret |
| [dashboard_usage.py](../vm/dashboard_usage.py) | Read-only usage history queries |
| [oliv-keys.rs](../oliv-api/src/bin/oliv-keys.rs) / [auth.rs](../oliv-api/src/auth.rs) | The key rules, atomic store, hashing and private output files |
| [deploy.sh](../deploy/deploy.sh) | Deploys and restarts the dashboard when its modules change |

These routes exist **only on the dashboard**, never on the public API:

| Method/path | Request/response |
|---|---|
| `GET /api/keys` | `{ok,keys,summary,defaults,limits,usage_available,usage_error,recording_since,day_start}`; no raw tokens/hashes |
| `POST /api/keys/usage` | JSON `{key_id?,status?,from?,to?,before_id?}` → `{ok,rows,next_cursor}`; status `all/success/error/limited/anonymous`, dates `YYYY-MM-DD` UTC inclusive, integer cursor |
| `POST /api/keys/create` | JSON `{name,scopes,expires_in_days,requests_per_minute,daily_requests}` → `201 {ok,key,token}`; the token is sent once |
| `POST /api/keys/revoke` | JSON `{id}` → `200 {ok,key}` now revoked |

Per-key `usage` has `total`, `successful`, `failed`, `quota_charged`, `today`,
`today_charged`, `last_used` (Unix milliseconds); it is absent when history
can't be read, rather than showing false zeros. `recording_since`, `day_start`
and log timestamps are Unix milliseconds too. Key administration keeps working
when the usage DB is broken.

Key metadata is `id`, `name`, `created_at`, `expires_at`, `revoked`, `scopes`,
`requests_per_minute`, `daily_requests`, `status`, with times in Unix seconds;
revoked takes precedence over expired.

The page sends `X-OLIV-Admin: 1` on POSTs and uses
`Content-Type: application/json` for JSON routes (the ASR test takes raw
audio). If you put an authenticating proxy in front, have it check identity
itself, reject cross-site requests, enforce body limits (key routes 4 KiB,
other JSON 64 KiB, audio 8 MiB) and forward no browser cookies or tokens to
the origin. Responses are `Cache-Control: no-store`; don't add body logging,
payload-capturing analytics, session replay or third-party code to a page that
shows keys. New scopes or limits must change the Rust authority, the Python
validation, the UI and the tests together. Never add admin routes to the
consumer ingress.

Tests:

```bash
cargo test --locked --manifest-path oliv-api/Cargo.toml --all-targets
python3 -m unittest discover -s vm -p 'test_*.py'
```

The key lifecycle tests use a temporary root with the real CLI and never touch
a real key store.
