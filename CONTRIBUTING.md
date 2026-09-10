# Contributing to OLIV

ไทยหรืออังกฤษก็ได้ — เปิด issue หรือ pull request เป็นภาษาไทยได้เลย

OLIV is a fully-local Thai + English push-to-talk dictation app for macOS
(Apple Silicon). Bug reports, dictation-quality fixes, docs, and small UI
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
python3.11 -m venv sidecar/.venv
sidecar/.venv/bin/pip install -r sidecar/requirements.lock

cd macos && xcodegen generate   # macos/OLIV.xcodeproj is generated, not tracked
```

A **usable** `.app` (embedded Python sidecar, stable code signature so
permissions stick) is:

```bash
bash scripts/build_app.sh    # -> build/OLIV.app
```

The first run downloads a relocatable CPython and pip-installs the lockfile
into `build/` (cached after that). `xcodebuild` Debug by itself is ad-hoc
signed and is the wrong binary to grant Accessibility / Input Monitoring.

Release packaging (signed `.dmg` + Sparkle appcast) is `bash scripts/release.sh X.Y.Z`.

## Tests to run

Hermetic — no 5 GB model download, no microphone:

```bash
sidecar/.venv/bin/python sidecar/test_text_passes.py
sidecar/.venv/bin/python sidecar/test_groq_backend.py
sidecar/.venv/bin/python benchmark/test_pipeline_spacing.py

( cd macos && xcodegen generate )
xcodebuild -project macos/OLIV.xcodeproj -scheme OLIV \
  -destination 'platform=macOS,arch=arm64' test
```

`sidecar/test_sidecar.py` loads the real STT + cleanup models; skip it unless
you are changing the sidecar protocol. The full accuracy numbers on
[the landing page](https://chayapats.github.io/oliv/) need your own audio
corpus — see [`benchmark/README.md`](benchmark/README.md).

If you change Swift sources or `macos/project.yml`, regenerate with
`xcodegen generate` before building. Do not hand-edit `OLIV.xcodeproj`.

## Pull requests

- Keep the change small and say what you ran.
- Match the surrounding style. This repo does not use pytest; sidecar and
  benchmark checks are plain `assert` scripts.
- User-facing copy in the app is English in code with Thai in `README.th.md`
  / the landing page. Don’t silently drop the Thai docs when you change the
  English ones.
- New user-facing behavior belongs in [CHANGELOG.md](CHANGELOG.md) under
  `## [Unreleased]` if it is something a person using the `.dmg` would notice.

## License

By contributing, you agree that your contribution is licensed under the same
[MIT License](LICENSE) as the rest of the app code.
