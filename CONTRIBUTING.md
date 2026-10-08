# Contributing to OLIV

ไทยหรืออังกฤษก็ได้ — เปิด issue หรือ pull request เป็นภาษาไทยได้เลย

OLIV is a Thai + English push-to-talk dictation app for macOS (Apple Silicon),
local by default with opt-in remote engines. Bug reports, dictation-quality fixes, docs, and small UI
patches are the most useful contributions. Please read the
[Code of Conduct](CODE_OF_CONDUCT.md) first.

## Before you start

- **Apple Silicon Mac, macOS 14+.** The bundled runtime is `aarch64-apple-darwin`.
- Do **not** commit voice recordings, private manifests, `.venv`, `.dmg`, or
  anything listed in [`.gitignore`](.gitignore). The public benchmark code is
  fine; the developer's own clips are not.
- Security-sensitive bugs: [SECURITY.md](SECURITY.md), not a public issue.

## Dev setup

```bash
brew install xcodegen
# Install stable Rust with rustup: https://rustup.rs
xcodebuild -downloadComponent MetalToolchain
bash scripts/build_native.sh   # Rust worker + native MLX, no Python needed
```

A **usable** `.app` (Rust + native MLX workers, stable code signature so
permissions stick) is:

```bash
bash scripts/build_app.sh    # -> build/OLIV.app
```

The first build resolves pinned Swift packages and Rust crates, cached after that. `xcodebuild` Debug by itself is ad-hoc
signed and is the wrong binary to grant Accessibility / Input Monitoring.

Release packaging (signed `.dmg` + Sparkle appcast) is `bash scripts/release.sh X.Y.Z`.

## Tests to run

Hermetic — no 5 GB model download, no microphone:

```bash
$HOME/.cargo/bin/cargo test --locked --manifest-path rust/Cargo.toml --workspace
bash scripts/build_native.sh
swift scripts/test_native_runtime.swift build/native-runtime
xcodebuild -project macos/OLIV.xcodeproj -scheme OLIV \
  -destination 'platform=macOS,arch=arm64' test
```

The `sidecar/` Python files are retained as reference/benchmark tooling and are
not bundled. Native tests use isolated settings and synthetic audio, without
Keychain prompts or microphone access. The full accuracy numbers on
[the landing page](https://chayapats.github.io/oliv/) need your own audio
corpus — see [`benchmark/README.md`](benchmark/README.md).

If you change Swift sources or `macos/project.yml`, regenerate with
`xcodegen generate` before building. Do not hand-edit `OLIV.xcodeproj`.

## Pull requests

- Keep the change small and say what you ran.
- Match the surrounding style. This repo does not use pytest; sidecar and
  benchmark checks are plain `assert` scripts; native core tests use Cargo.
- User-facing copy in the app is English in code with Thai in `README.th.md`
  / the landing page. Don’t silently drop the Thai docs when you change the
  English ones.
- New user-facing behavior belongs in [CHANGELOG.md](CHANGELOG.md) under
  `## [Unreleased]` if it is something a person using the `.dmg` would notice.

## License

By contributing, you agree that your contribution is licensed under the same
[MIT License](LICENSE) as the rest of the app code. The shared OLIV Linux core remains Apache-2.0;
see the notices in `rust/` and `macos/OLIVInference/UPSTREAM.md`.
