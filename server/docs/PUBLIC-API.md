# OLIV server API

This is the HTTP contract between the OLIV clients (Mac, Windows, Linux,
iPhone) and an OLIV server, plus how individual API keys work. Clients depend
on this document only, never on server internals.

Examples use `https://oliv.example.com`; replace it with your deployment's
base URL. The origin (`oliv-api`) listens on `127.0.0.1:8083` in keys mode, and
TLS terminates in front of it (a tunnel or reverse proxy, see the server
README). Gemma, the ASR backend and the dashboard stay on loopback. Note that
whoever terminates TLS for you (for example a tunnel provider) is on the path
of the audio.

## Scope of the system

| Part | Behaviour |
|---|---|
| Server bind | `127.0.0.1:8083` with keys. Binding one private overlay address (100.64.0.0/10) is an explicit opt-in. Wildcard and public binds are refused. |
| Auth | `[api].auth_mode = "keys"` is the default. Each key has a name, an expiry, scopes, rate limits and a revoked flag. |
| Legacy | `auth_mode = "legacy"` (one shared token in `api.token`) is accepted only when the API binds a private overlay address, for migrating old installs. Never use the legacy token as a public credential. |
| Key management | `oliv-keys` is the only authority over the key store. The [dashboard](DASHBOARD.md) calls the same CLI. The consumer API has no key-management routes. |
| Inference | STT, cleanup and the text pipeline. Models are never exposed directly, and the dictation API cannot manage processes. |
| Client | HTTPS with certificate verification; plain HTTP only for loopback/private-network endpoints the client accepts; 120 s default timeout. |
| Ingress | Expose only `/health`, `/v1/dictate`, `/v1/clean` and `/v1/dictionary`, with a final 404. |

Example `[api]` for a new installation whose models and runtimes are in place:

```toml
[api]
host = "127.0.0.1"
port = 8083
auth_mode = "keys"
prompt = "v5"
llm_timeout = 5
```

`[gemma]`, `[whisper]` and `[dashboard]` are required too; see `vm/config.toml`
and the server README. This config alone installs no models.

## Issuing keys without printing secrets to the terminal

Build on Linux (or with `scripts/build-release.sh`):

```sh
cargo build --locked --release --manifest-path oliv-api/Cargo.toml --bins
```

This example creates a **throwaway key store on a development machine**; it
does not contact a server. The root must be a directory owned by the current
user and not writable by group/other:

```sh
install -d -m 700 "$HOME/oliv-key-demo"
oliv-api/target/release/oliv-keys --root "$HOME/oliv-key-demo" init
oliv-api/target/release/oliv-keys --root "$HOME/oliv-key-demo" create --name alice-windows --out "$HOME/oliv-key-demo/alice-windows.key" --expires-in-days 90 --scopes dictate --requests-per-minute 10 --daily-requests 500
oliv-api/target/release/oliv-keys --root "$HOME/oliv-key-demo" list
```

If you download Linux binaries from a CI artifact, check the commit and
checksums and restore the execute bit (`chmod 700 oliv-api oliv-keys`); ZIP
artifacts may drop it.

Point `--root` at a real server directory (`~/oliv`) only when you mean to
provision that server. `init` never overwrites an existing (even corrupt) store
and `create` never overwrites an existing output file. The output file holds
the raw key with mode `600`; the CLI never prints the raw key to stdout. Hand
the file to the key's owner over a private channel, and keep secrets out of
command lines, Git, CI, screenshots and error reports.

`api-keys.json` lives under the root and stores the SHA-256 of each token plus
metadata, never the raw secret; tokens carry a high-entropy random part. Keep
the store at mode `600` like the raw key files. The CLI refuses symlinks in the
root and output paths. Don't hand-edit the JSON to widen permissions or to
"recover" a secret (a hash can't be turned back into one); issue a new key and
revoke the old one.

`create` defaults to scope `dictate`, 90 days, 10 requests/minute and 500
requests/day. Grant only the scopes needed:

| Scope | Allows |
|---|---|
| `dictate` | `POST /v1/dictate` and the personal dictionary `GET/POST /v1/dictionary` |
| `clean` | `POST /v1/clean` for text only |
| `status` | `GET /v1/status`, which includes backend/runtime details |

`--scopes dictate,clean,status` grants all of the above; no key can restart
services or change config through the API. Use one key per person or device so
each can be revoked on its own. `list` shows ID, name, created/expiry times,
scopes, limits and revoked state, never secrets or hashes; timestamps are Unix
seconds UTC.

Revoke with the ID from `list`:

```sh
oliv-api/target/release/oliv-keys --root "$HOME/oliv-key-demo" revoke KEY_ID_FROM_LIST
```

The server re-reads the store when it authenticates the next request. A
deleted, corrupt or no-longer-private store makes authentication fail; it never
falls back to legacy auth. Revocation blocks new requests; it does not recall
text already returned or guarantee that inference started before the
revocation is cancelled. Back the store up privately before upgrades, but don't
restore an old backup that would silently bring revoked keys back.

## HTTP contract

Every authenticated request sends:

```http
Authorization: Bearer <individual-api-key>
Content-Type: application/json
```

```http
POST /v1/dictate

{
  "wav_b64": "<base64-of-wav-file-bytes>",
  "cleanup": true,
  "remove_fillers": true,
  "thai_format": true,
  "vocabulary": [],
  "replacements": {}
}
```

Audio must be **RIFF/WAVE PCM signed 16-bit little-endian, mono, 16,000 Hz, at
most 120 seconds**. Send standard base64 of the whole file, without a
`data:audio/...` prefix; no multipart, MP3, AAC or M4A. Renaming a file to
`.wav` does not convert it.

The Windows client already converts the microphone to this format. An iPhone
client must produce a WAV that matches the contract before sending; M4A from
Shortcuts or Voice Memos cannot be sent as-is.

`POST /v1/clean` needs scope `clean`, takes `{"text":"...", ...options}` and
does not run STT. `GET /health` is a small public liveness probe
(`{"ok":true}`); it does not prove the models are ready. `GET /v1/status` needs
scope `status` and is meant for operators on the private origin; keep it off
the public ingress.

A successful reply carries `ok`, `raw`, `final`, `no_speech`, `stt_redecoded`,
timings, `dictionary_revision` and pipeline metadata. If the LLM fails, the
reply still contains the deterministic text plus `cleanup_error`; don't drop
that text. Don't paste when `no_speech` is set or `final` is empty. See
[api.rs](../oliv-api/src/api.rs) for every field.

### Personal dictionary

The server keeps each user's dictionary per profile and applies it to every
dictate/clean automatically. Clients sync with `GET /v1/dictionary` and
`POST /v1/dictionary` (`{"ops":[upsert|delete…]}`); `dictionary_revision` in
replies tells them when to refresh. Details, limits and the client sync
algorithm are in [DICTIONARY.md](DICTIONARY.md). If an older server answers
`404`, clients fall back to sending `vocabulary`/`replacements`.

| HTTP status | What the caller should do |
|---|---|
| `200` + `ok:true` | Use the result; treat `no_speech` / empty `final` differently from normal text. |
| `400` | JSON/options/base64/WAV does not match the contract; fix the input before retrying. |
| `401` | Key missing, wrong, expired or revoked; get a valid key. |
| `403` | Key lacks the scope, or the request reached the origin through a proxy over non-HTTPS; HTTP is not redirected. |
| `413` | Request too large. |
| `408` | Upload exceeded the 15 s deadline. |
| `415` | Unsupported Content-Type/Content-Encoding; send uncompressed JSON. |
| `429` | Per-key rate exceeded, or that key already has a request in flight; `Retry-After: 60`. |
| `503` | Admission full, queue wait over 20 s, or key store unusable; `Retry-After: 60`. |
| `502` | STT backend failed, or the text result exceeds its cap; keep the audio and investigate before retrying. |
| `504` | Processing exceeded 95 s; the model may still be running and holding its permit, so don't retry immediately. |

## Limits and data handling

- Request bodies are at most 8 MiB. Auth, headers and the declared size are
  checked before the body is read; JSON/base64/WAV are validated after.
- At most 8 requests are admitted at once (active, queued and uploading
  together). ASR runs `[api].asr_concurrency` jobs at a time (1 unless the
  `qwen3asr` profile is configured for more) in FIFO order, and Gemma cleanup
  runs one at a time; a request waits at most 20 seconds for its turn. This is
  not a persistent job queue.
- Each key may have one request in flight. Default rates are 10/minute and
  500/day, adjustable per key at creation to fit the machine.
- Rate counters use UTC minute/day windows, live in memory and reset on
  restart; they are not a billing quota.
- The HTTP server accepts at most 32 connections, a 5 s header deadline,
  32 headers / 16 KiB, one request per connection and a 120 s overall
  connection deadline.
- Upload deadline 15 s, processing deadline 95 s. If the HTTP response times
  out or the client disconnects, the blocking task keeps its permit until it
  returns; model work is not cancelled over the network.
- Backend HTTP timeouts are a separate layer: the ASR server may keep decoding
  after the API has timed out, so it holds a lock that rejects new work with 503
  (before reading audio) until the decode really ends. Gemma runs with `-np 1`.
  There is no distributed cancellation; don't auto-retry immediately.
- Backend STT/LLM JSON is capped at 256 KiB and text at 16 KiB; backend
  redirects and non-2xx replies are refused. `raw` + `final` together are capped
  at 128 KiB so the reply fits the clients' 1 MiB limit; a replacement that
  expands past that yields a 502 without echoing content.
- Warm-up after start shares the inference lock with user requests, so a 503
  during cold start is expected. These limits reduce impact; they don't make
  the endpoint withstand arbitrary traffic.
- Clients default to a 120 s timeout (`[server].timeout_seconds`, 10–180). Don't
  let a timed-out client retry automatically and duplicate inference.

A bearer key is a capability: whoever has the file can use it until it expires
or is revoked. Don't share one key across a group, and don't log raw WAV,
transcripts or `Authorization` headers. Client-side history/pending items are
personal data too.

## Client configuration (Windows example)

```toml
[server]
url = "https://oliv.example.com"
token = "PUT-YOUR-INDIVIDUAL-KEY-HERE"
timeout_seconds = 120
```

Stored in `%APPDATA%\oliv\config.toml`, whose ACL the installer restricts. TLS
uses rustls with Mozilla roots and checks the hostname; verification can't be
relaxed for self-signed or mismatched certificates, and redirects are not
followed, so use the final URL. Plain HTTP is allowed only for `localhost`,
literal loopback, RFC 1918 IPv4 and CGNAT `100.64.0.0/10`; public HTTP
hostnames/IPs and userinfo/query/fragment in the base URL are rejected.

The origin rejects with `403`, before auth and body, any `X-Forwarded-Proto`
other than a single `https` value. The header grants nothing by itself, and
direct loopback requests without it are allowed. Proxies such as Cloudflare
overwrite the header with the visitor's protocol
([Cloudflare docs](https://developers.cloudflare.com/fundamentals/reference/http-headers/#x-forwarded-proto)),
so configure HTTPS from the start; never send a key over HTTP hoping for a
redirect.

## Deploying or upgrading

1. Run the server/auth/key CLI tests, client TLS tests and Python config tests
   with synthetic data and loopback mocks first.
2. Back up config, binaries, key store and state privately; record the commit
   and how to roll back. Wait for in-flight requests; don't change bind/auth
   while people are using the server without a maintenance window.
3. Configs without an explicit `[api].auth_mode` fail the deploy preflight. To
   keep an old private-only setup, set `host` to its overlay address and
   `auth_mode = "legacy"` explicitly and keep `api.token` at mode `600`; never
   use that profile behind public ingress.
4. For keys mode, provision `api-keys.json` and a test key first, then set
   `auth_mode = "keys"`. The first time a server has no `oliv-keys`, copy a
   checked CLI there to provision it. Deploys never bootstrap credentials. Use
   loopback when publishing through a tunnel; clients of an old overlay address
   lose access when the bind moves, so plan the client move and rollback.
5. `OLIV_VM=<host> deploy/deploy.sh --dry-run` still reads the server over SSH
   and builds the binaries; it fails **before any remote write** if
   `auth_mode` is missing, and never adds a section or creates a token.
6. `OLIV_VM=<host> deploy/deploy.sh` builds `oliv-api` and `oliv-keys`, backs
   up, stages the binaries and lets the staged key CLI validate the store
   before swapping the active binary. It re-checks bind/auth and the config's
   SHA-256 before activation and stops for review if the config changed
   meanwhile, without printing the raw config. It then **always restarts the
   API** (when idle) to apply auth/config even if the binary is unchanged. It
   never changes config/auth/key files or tunnel config and never restarts
   Gemma.
7. Test on loopback/a private network before opening ingress: good/wrong/
   expired/revoked keys, wrong scope, broken/too-long WAV, oversized body,
   full queue/rate limit, timeout and LLM fallback.

The dashboard probes Gemma/ASR directly and controls processes through the
same scripts. The API's `/health` does not disclose runtime config, so the
dashboard shows the API as reachable but its config as unverified
(`runtime_config_verified:false`). The dashboard never reads the key store or
borrows a `status` key.

`start.sh api` reads the auth mode from config: keys mode needs the key CLI and
a store that `oliv-keys list` validates; legacy mode needs the private token.
Starting a service never creates keys or tokens.

## Public ingress requirements

Whatever fronts `127.0.0.1:8083` (the bundled Cloudflare Tunnel helper
`vm/consumer_tunnel.py`, or your own proxy), keep these conditions:

- API keys mode only, trusted TLS, individual revocable keys, and rate/size
  limits at the edge where appropriate.
- Allowlist `/health`, `/v1/dictate`, `/v1/clean`, `/v1/dictionary` with the
  methods the API defines; block `/v1/status` and any admin/model route; no
  generic proxy to arbitrary hosts/paths.
- The origin is `127.0.0.1:8083` only. Never route ingress to `8081`, `8082`,
  `8087` or `8090`, and don't change the model listeners.
- Keep the consumer ingress separate from any admin/dashboard access path; don't
  give API users dashboard access to let them dictate.
- Test negative routes, that no backend metadata or credentials leak, that no
  new public listeners appeared, and that you can stop ingress and revoke keys
  before handing keys out.

For a small group you don't need accounts, a key web UI or a public admin
endpoint, but an internet-reachable endpoint still needs watching for abuse,
capacity and leaked credentials.

## Test scripts rejected by Cloudflare

If HTTPS returns `403` with the text `error code: 1010` from Cloudflare, that is
not OLIV's JSON scope `403`. Cloudflare's browser-signature checks have been
seen rejecting the default `Python-urllib` User-Agent. Clients and test scripts
should send a real app name/version as User-Agent; test both `/health` and an
authenticated request, without disabling TLS checks or loosening zone-wide
rules. See [Cloudflare error 1010](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/).
