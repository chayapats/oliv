# OLIV Server

Server for all OLIV clients (macOS, iPhone, Linux, Windows): STT + Thai/English
cleanup behind one HTTPS API on a self-hosted GPU machine. See `README.md`.

- **API contract:** `docs/PUBLIC-API.md`. Clients depend on it only. Keep
  changes backward compatible; additive fields/routes, never repurpose one.
- **Build:** `scripts/build-release.sh` (pinned alpine image, monorepo mounted
  at `/work`, reproducible). Never pass `--target`; it breaks byte-for-byte
  reproducibility.
- **Shared text core:** segmentation, the built-in and user dictionaries,
  Thai numbers and phonetic matching come from `oliv-text-core` in
  `../rust/crates/oliv-text-core` (path dependency, shared with the Mac app).
  Change them there; never fork a copy into `server/`. A text-core change
  changes the server's release bytes, so re-run the server tests too.
- **Workspace:** `server/oliv-api` is not a member of the `rust/` workspace and
  keeps its own `Cargo.lock`; don't add it to `rust/Cargo.toml`.
- **Checks (Linux only):** `cargo test --locked --manifest-path oliv-api/Cargo.toml --all-targets`;
  `python3 -m unittest discover -s vm -p 'test_*.py'`.

## Operating a server

- Restarts, deploys, benchmarks and anything touching keys on a live server
  need the operator's explicit approval. Use `deploy/deploy.sh --dry-run` first.
- Never read or print `api-keys.json`, `api.token`, `keys/` or cloudflared
  credentials.
- Never expose 8081/8082/8087/8090 beyond 127.0.0.1. The API binds loopback
  or one private overlay address (100.64.0.0/10) only.
- Services are user systemd units (`vm/systemd/`, installed in
  `~/.config/systemd/user/`); `start.sh`/`stop.sh` route through them. Don't
  add another process controller.
- The consumer tunnel uses only `start.sh api-tunnel` / `stop.sh api-tunnel`;
  `all` excludes it.
- Keep the deployed binary's commit known: deploy only committed trees built
  with `scripts/build-release.sh`, and record the sha256.

## Data

- Eval audio is private data. Never commit or upload it; eval
  manifests, clips and results stay out of git (see `.gitignore`, `eval/README.md`).
- Golden fixtures (`oliv-api/tests/golden/`) are public literals and synthetic
  examples only (see its `README.md`). Never add cases derived from eval clips,
  transcripts or recorded generations; the generator is retired. Intentional
  divergences go in `oliv-api/tests/known_diffs/` with a `KNOWN_DIFFS.md` section.
