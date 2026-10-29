# Developing the desktop client

One Rust crate (edition 2024) builds the Linux and Windows clients; `cfg` /
`cfg_attr(windows, path = ...)` in [main.rs](../src/main.rs) selects the OS backends
(capture, notify, overlay, paste, transport). Config, the API client, the job queue,
pending/history and retry are shared. The crate has its own `Cargo.lock`; always pass
`--locked`. It is not part of the `rust/` workspace used by the macOS app.

## Tools

| Tool | For |
|---|---|
| Rust stable with rustfmt and Clippy | everything |
| C toolchain, pkg-config, libclang, PipeWire/Wayland/xkbcommon dev libraries | Linux build/test |
| Rust MSVC x64 target, Visual Studio C++ Build Tools, Windows SDK | Windows build/test |

Ubuntu 24.04:

```sh
sudo apt-get install -y build-essential pkg-config libclang-dev libpipewire-0.3-dev libwayland-dev libxkbcommon-dev
rustup component add rustfmt clippy
```

A Linux build does not mean every desktop works: the runtime expects PipeWire,
Wayland wlr layer-shell, Hyprland (`hyprctl`), `wl-copy`/`wl-paste` and
`notify-send`; the overlay reads Noto Sans Thai / Noto Sans from the paths in
[draw.rs](../src/draw.rs).

## Build and test

Linux, from `desktop/`:

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
cargo build --locked --release        # target/release/oliv
```

Windows (PowerShell, from `desktop\`):

```powershell
$env:CARGO_BUILD_TARGET = 'x86_64-pc-windows-msvc'
$env:RUSTFLAGS = '-C target-feature=+crt-static'
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
cargo build --locked --release        # target\x86_64-pc-windows-msvc\release\oliv.exe
```

The native desktop tests are `#[ignore]`d so a normal run never injects input or
changes your clipboard. Run them one at a time in a **disposable Windows session**
and don't type meanwhile:

```powershell
cargo test --locked native_ -- --ignored --test-threads=1 --nocapture
```

With only Linux you can still type-check and lint the Windows code paths (this does
not run `oliv.exe`):

```sh
rustup target add x86_64-pc-windows-gnu      # plus a mingw-w64 C compiler for ring
cargo clippy --locked --all-targets --target x86_64-pc-windows-gnu -- -D warnings
```

[tests/cli_workflow.rs](../tests/cli_workflow.rs) runs the real executable against a
mock HTTP server with temporary config/state, the place for protocol, retry and
history regressions. It never uses real user data.

## From key press to text

| Step | Files and behaviour to preserve |
|---|---|
| Command input | Windows: [windows/hotkey.rs](../src/windows/hotkey.rs) + named pipe. Linux: Hyprland binds call the CLI over a Unix socket ([transport.rs](../src/transport.rs)). |
| Recording | [daemon.rs](../src/daemon.rs) owns state; the backend opens input only while recording and hands mono 16 kHz PCM to the WAV encoder. |
| Sending | The daemon worker is FIFO; a new clip can be recorded while an older one waits. [api.rs](../src/api.rs) sends the options, holds the request lock and checks the cooldown. |
| Pasting | The paste backend pastes into whatever is focused at paste time, not where recording started. |
| Storage/recovery | [store.rs](../src/store.rs): history, pending, locks, cooldown. `retry` lives in main.rs. |

Taps shorter than 300 ms are dropped; a long-enough clip with under 0.1 s of samples
is not sent; recordings stop at two minutes. Windows capture uses the CPAL/WASAPI
default input, downmixes and resamples to mono 16 kHz; a device error stops recording
with a reason and still sends the usable audio.

Windows hotkey: physical Right Shift held records, release stops, Escape while held
cancels. The hook does no heavy work in the callback, ignores key repeat and injected
input, and leaves Left Shift alone.

Windows overlay: a non-activating, click-through layered window drawn with the shared
[draw.rs](../src/draw.rs), painted only while visible. Priority: recording → unexpired
error → processing → info; a new info must not hide a live error.

Windows paste: Unicode clipboard and `SendInput` (`Ctrl+V`; `Shift+Insert` for
`ConsoleWindowClass`). It waits for modifiers to be released and checks the
foreground window, backs up the clipboard formats it can copy safely, and restores
only if the clipboard still holds its own data (owner/marker/content plus sequence
number, so Windows text synthesis does not defeat it and a new user copy is never
overwritten). If a format cannot be backed up it fails before clearing the
clipboard. Don't weaken these guards to make a test pass.

## Config

[config.example.toml](../config.example.toml). Windows reads `%APPDATA%\oliv\config.toml`;
Linux reads `${XDG_CONFIG_HOME:-$HOME/.config}/oliv/config.toml`. The daemon loads it
at start and again for every clip.

| Key | Meaning / limits |
|---|---|
| `[server].url` | Required. HTTPS with rustls/WebPKI roots and hostname verification; HTTP only for loopback/RFC1918/CGNAT; no userinfo/query/fragment; redirects never followed. |
| `[server].token` | Required printable ASCII without spaces. Never in the example, a command line, a log or a commit. |
| `[server].timeout_seconds` | Integer 10–180, default 120: total request deadline. |
| `[dictate].cleanup`, `remove_fillers`, `thai_format` | Booleans, default `true`. |
| `[dictate].vocabulary` | Array of strings, default empty. |
| `[replacements]` | string → string, applied in TOML order (order is preserved into the JSON). |

Unknown keys/sections are rejected. There is no microphone, hotkey or prompt
setting yet. On Linux the config must not be group/other accessible (mode 600); on
Windows the installer sets a user/SYSTEM-only ACL. `Debug` output and TOML errors
never include the key.

The reply is limited to 1 MiB and the request to the configured timeout. Only HTTP
200 with `ok:true` and a final text counts as success; the client never retries
automatically. See [API-MIGRATION.md](API-MIGRATION.md) for the status-code mapping.

## Failure, pending, history and locks

| Event | Expected result |
|---|---|
| network / timeout / non-200 / `ok:false` / bad reply / cooldown | WAV kept in `pending/`, a notice suggests `oliv retry`. |
| LLM error on the server | Server returns deterministic text with `cleanup_error`; the client still pastes it. |
| `no_speech` or empty final | Notice, nothing pasted. |
| Transcribed but paste failed | Text in history with `pasted:false`; read it with `oliv last`. Audio is not resent. |
| Disk full / unwritable | Error reported; no claim that data can never be lost. |

| Data | Windows | Linux |
|---|---|---|
| state | `%LOCALAPPDATA%\oliv` | `${XDG_STATE_HOME:-$HOME/.local/state}/oliv` |
| history | `state\history.jsonl` | `state/history.jsonl` |
| unsent audio | `state\pending\*.wav` | `state/pending/*.wav` |
| API cooldown | `state\retry-after` | `state/retry-after` |
| runtime locks | `state\run` | `$XDG_RUNTIME_DIR` |
| IPC | `\\.\pipe\oliv-<current user SID>` | `$XDG_RUNTIME_DIR/oliv.sock` |

`oliv.lock` wraps each HTTP request of the daemon and `retry`; `retry.lock` wraps a
whole retry run from reading the queue to deleting files; `history.lock` (in the
state directory) serializes append/trim. A lock file existing does not mean a
process still holds the OS lock; never delete locks while OLIV is running.

`retry` goes oldest first, stops at the first failure and deletes each file as soon
as the server succeeded. History is trimmed to 1,000 entries once it passes 1,200
and damaged lines are skipped when reading.

The Windows named pipe is restricted to the current user and SYSTEM, rejects remote
clients and prevents a second daemon. IPC needs a complete command line of at most
256 bytes within one two-second deadline; when changing framing/timeouts, cover a
slow client and check the next command still works.

## Which checks for which change

| Change | Checks |
|---|---|
| Config/JSON/options/timeout/history/retry/cooldown | unit tests + `cargo test --test cli_workflow`; contract changes also need the server's API tests. |
| Windows audio | sample-format/downmix/resample/limit unit tests + native Windows; a real microphone when device lifecycle changes. |
| Windows hotkey/overlay/paste/IPC | Windows fmt/Clippy/unit tests + `native_` serially; physical input, target apps and multiple monitors per [WINDOWS.md](WINDOWS.md). |
| Linux backend / shared daemon | Linux tests and Windows check/tests; a real PipeWire/Hyprland desktop. |
| Installer/startup/ACL | the PowerShell 5.1 lifecycle steps in CI; a normal-user sign-in test if that boundary changes. |

Add regressions from real failures. Native Windows desktop tests are named `native_...`
so CI can select them. Don't loosen assertions when CI shows the OS behaves
differently from an assumption.

## Install, debug, secrets

Installing changes files, permissions and (by default) startup, so do it only on a
machine you mean to use. On Windows a dev install that neither starts the daemon nor
touches startup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\install-client.ps1 -BinaryPath .\target\x86_64-pc-windows-msvc\release\oliv.exe -NoStart -NoAutoStart
```

On Linux [install-client.sh](../deploy/install-client.sh) builds, installs, enables and
restarts the systemd user service and edits Hyprland binds; it is not a build-only
command, so don't run it in CI. To debug the daemon in a terminal, stop the installed
instance, run `oliv daemon`, stop with Ctrl+C and restore the service afterwards.

| Symptom | Where to start |
|---|---|
| Linux build cannot find PipeWire/Wayland | dev packages, `pkg-config`, libclang. |
| Windows linker/SDK not found | MSVC toolchain with C++ Build Tools and Windows SDK. |
| Daemon exits immediately | stderr/log: unknown TOML keys, environment paths, token format, ACL. |
| `status` says down but the daemon won't start | executable path / user / old instance. Never kill every `oliv` process or loosen the pipe ACL. |
| Key press does nothing | daemon running? Windows: physical Right Shift (injected keys are ignored by design). Linux: Hyprland binds and IPC. |
| Overlay missing / wrong glyphs | font paths, display backend; Windows DPI/monitors; Linux needs layer-shell. |
| `401` or pending keeps growing | URL/connectivity and a valid individual key. A placeholder key parses but is rejected by the server. |
| Text in history but not pasted | focus changed, stuck modifier, clipboard format/owner, elevated target app. Use `oliv last`. |

Logs (journal on Linux, `daemon.*.log` on Windows) aim to hold no transcripts, but
errors from other systems can contain details; redact before sharing. History holds
raw/final text and pending holds real audio; never upload the state directory. Report
bugs with synthetic examples, redacted errors, commit, OS, build target and steps.

Before upgrading, let recordings/sends/retries finish, then back up config and state
to a private place (not the repository). The Windows installer stops the process at
its own executable path, including a running `retry`. The Linux installer never
overwrites the config and backs up `bindings.lua` before its first edit.

## CI

[`.github/workflows/desktop.yml`](../../.github/workflows/desktop.yml) runs on changes
under `desktop/**` (and the workflow itself) and on manual dispatch: a Windows Server
2022/2025 matrix (format, Clippy, unit/CLI tests, native desktop tests, release
build, PowerShell 5.1 installer and startup-registry lifecycle, packaged ZIP +
SHA-256 artifacts kept 14 days) and a Linux job (format, Clippy, tests). Some Windows
test steps use `continue-on-error` to collect more evidence, and a final gate fails
the job if any suite failed: check every job, not just the build step, before
handing out a binary. There is no release publishing, code signing or auto-update
for the desktop client yet.
