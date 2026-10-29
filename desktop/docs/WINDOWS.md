# OLIV on Windows

The Windows client is a native port of the Linux client. It uses the same OLIV
server HTTP contract (`oliv-api`): Thai/English STT, cleanup, vocabulary,
replacements, pending/history and retry behave the same. No GPU or model runs on
Windows; the client only records, uploads to your OLIV server and pastes.

Target: Windows 10/11 x64, the Windows default microphone, hold **Right Shift** to
record, release to send and paste, **Escape** while holding to cancel.

## Install

1. Download and extract the complete release ZIP (from the `desktop` workflow
   artifacts, see [CI](#ci-and-artifacts)) into a folder, and check its SHA-256.
2. In a normal (non-admin) PowerShell in that folder, run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-client.ps1
   ```

3. Open the config with `notepad "$env:APPDATA\oliv\config.toml"` and set
   `server.url` to your OLIV server's HTTPS base URL (for example
   `https://oliv.example.com`, without `/v1/dictate`), `server.token` to your
   individual key, and optionally `timeout_seconds` (10–180, default 120). Do not put
   the key on a command line or in a commit.
4. HTTPS certificates are always verified; never disable TLS verification. Plain HTTP
   is only accepted for loopback/private-network servers.
5. Choose the default microphone in Windows Settings and allow desktop apps to use
   the microphone. Then start OLIV:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Oliv\start-oliv.ps1"
   & "$env:LOCALAPPDATA\Programs\Oliv\oliv.exe" status --json
   ```

The installer installs for the current user only, needs no admin rights, does not
change PATH and does not touch the server. Re-installing keeps the existing
config/key/history and stops only the process whose executable path matches the file
being updated.

When it has just created the example config, the installer does not start the daemon,
so you can fill in the key first. Sign-in startup is registered under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run\OlivWindows`, which runs Windows
PowerShell and the daemon with hidden windows (no VBScript).

| Data | Location |
|---|---|
| Program and launcher | `%LOCALAPPDATA%\Programs\Oliv` |
| Config and key | `%APPDATA%\oliv\config.toml` |
| History, pending recordings, API cooldown | `%LOCALAPPDATA%\oliv` |
| Launcher logs | `%LOCALAPPDATA%\oliv\daemon.stdout.log`, `daemon.stderr.log` |

The installer restricts the config and data folders (and the config file itself) to
the current user and SYSTEM. Pending recordings can contain private speech: never
upload the data folder to GitHub or a CI artifact.

Developer options:

```powershell
# Build from source (Rust MSVC + Visual Studio C++ Build Tools)
$env:RUSTFLAGS = '-C target-feature=+crt-static'
cargo build --locked --release --target x86_64-pc-windows-msvc --manifest-path desktop/Cargo.toml
powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\deploy\install-client.ps1 -BinaryPath .\desktop\target\x86_64-pc-windows-msvc\release\oliv.exe -NoStart -NoAutoStart

# History / resend kept recordings
& "$env:LOCALAPPDATA\Programs\Oliv\oliv.exe" history 10
& "$env:LOCALAPPDATA\Programs\Oliv\oliv.exe" retry

# Debug: run the daemon in this window (stop the running one first)
& "$env:LOCALAPPDATA\Programs\Oliv\oliv.exe" daemon
```

`-NoStart` skips starting now, `-NoAutoStart` leaves the startup registry unchanged,
`-InstallDir` installs elsewhere. If an OLIV startup entry points at another
installation, uninstall that one before moving.

## Uninstall

```powershell
# Keeps config/key/history/pending
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Oliv\uninstall-client.ps1"

# Or explicitly delete all private data as well
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Oliv\uninstall-client.ps1" -RemoveUserData
```

The uninstaller removes only the startup entry that matches this installation, stops
only the same executable path and deletes only files the installer created. When
running it from a source checkout for a custom location, pass the same `-InstallDir`.

## CI and artifacts

[`.github/workflows/desktop.yml`](../../.github/workflows/desktop.yml) runs on GitHub's
`windows-2022` and `windows-2025` runners (and a Linux job). With isolated temporary
config/data, synthetic silence and a loopback HTTP server (never a production API,
real key or real recording) it runs `cargo fmt`, `cargo clippy`, `cargo test`, a
release build, and:

- the real executable against mock HTTP: options/bearer key/WAV contract, history,
  configured timeout, errors, cooldown, retry and concurrent retry;
- `SendInput` through the real paste path into a native EDIT control (Thai, English,
  emoji, multi-line) and restoring clipboards holding text, bitmaps and file lists;
- a real keyboard hook: injected Right Shift does not start recording, the overlay
  does not take focus, a new user copy is not overwritten;
- WASAPI enumeration and the no-microphone case, resampling of synthetic data, named
  pipe timeouts/malformed input/multiple clients, and pipe/file ACLs;
- the PowerShell 5.1 installer/uninstaller: repeated launch, upgrade while running,
  damaged config, startup registry, Thai/space/apostrophe paths, and preservation of
  config/history/user files.

The native desktop tests are `#[ignore]`d in normal runs (they inject input and use
the clipboard) and are run explicitly in the `Native desktop and daemon regression
tests` step. The build targets `x86_64-pc-windows-msvc` with `crt-static`, so the C
runtime is linked into `oliv.exe`.

A successful run uploads `oliv-windows-x64-windows-2022` and
`oliv-windows-x64-windows-2025` (same x64 MSVC target, different runner image). Each
holds a ZIP and its SHA-256 with `oliv.exe`, the example config, installer,
uninstaller, this guide and `BUILD.txt` (commit, toolchain, OS). Only distribute an
artifact from a run where every job and the final test-outcome gate passed.

Runners are Windows Server images with an Administrator token. A compile check from
Linux (`cargo clippy --target x86_64-pc-windows-gnu`) or CI does not prove microphone,
physical keys, overlay, paste into real apps or autostart on a user's Windows 10/11
desktop. That needs the acceptance list below.

## Desktop acceptance

On Windows 10/11 with a normal user account; record the Windows version, audio
device, target app/version, commit and the result of each item:

- [ ] Hold and release Right Shift once: one clip, one request, Thai/English pasted correctly.
- [ ] Escape while recording: cancelled, no request, no paste; Left Shift still types capitals.
- [ ] No microphone / permission off / device unplugged mid-recording: an error, and the next recording works.
- [ ] Switching default input, USB/Bluetooth, 44.1/48 kHz devices: audio is not distorted.
- [ ] Overlay shows recording/processing/notice, never steals focus or blocks clicks, and appears on the right monitor with mixed DPI.
- [ ] Paste into Notepad, a browser, VS Code and a terminal, and the previous clipboard is restored.
- [ ] Previous clipboard holding text/image/files, and switching windows while waiting for the API.
- [ ] Network down or API error: a pending file, `retry` sends it exactly once, history is correct.
- [ ] Sign out/in and reboot: the daemon starts hidden once, Right Shift works once the network is up.
- [ ] Reinstall/uninstall: key and data preserved, OLIV processes from other checkouts untouched.
- [ ] Latency from key release to paste, idle CPU/RSS, memory while recording (measured on Windows, not borrowed from Linux).

Windows restricts input across integrity levels: an app running as Administrator may
not accept a paste from OLIV running as a normal user. Test with apps at the same
level first; see Microsoft's [SendInput / UIPI](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput) notes.
