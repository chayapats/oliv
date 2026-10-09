# Native developer tooling

The app runtime migration initially retained the previous prototype and
interpreter-based developer tools. This follow-up removes those dependencies
from maintained source, tests, benchmarks and release packaging.

- Rust `oliv-test-worker` replaces both the fake JSON sidecar and the real
  HTTP/TLS fixtures used by XCTest. TLS certificates are generated in memory;
  no system trust changes or credentials are needed.
- Rust `oliv-dev` evaluates the shipped workers, scores Thai WER/CER and keyword
  recall, produces local HTML reports and drives native semantic scoring.
- Swift `oliv-semantic` uses MLX BERT with cached LaBSE safetensors and Rust
  WordPiece tokenization. It is kept outside the application bundle.
- Swift `oliv-dmg` writes Finder layout metadata with pinned MIT-licensed
  DSStore and renders installer assets with AppKit. `build_dmg.sh` uses hdiutil
  to create, mount, style, verify and compress the installer without Finder
  automation. Release signing, notarization and Sparkle remain unchanged.
- Frozen public golden fixtures remain independent reference outputs. They
  are not regenerated from the Rust code being tested.

The old CLI app, reference pipeline, research spikes, personal LoRA training
tools and third-party Wispr automation are retired, not rewritten into new
supported features. Their source and tests remain in Git at `55f8da0`; local
development copies were moved to an external backup. Personal recordings,
datasets, settings and model caches are preserved. System Python installations
and other projects are outside this migration's scope.

Build tools with `bash scripts/build_dev.sh`, run model-free tests with
`bash scripts/test.sh`, and create an installer with
`bash scripts/build_dmg.sh build/OLIV.app dist/OLIV-local.dmg 'OLIV local'`.
For benchmark details see [../benchmark/README.md](../benchmark/README.md).

## Verification on 2026-10-09

- 259 XCTest cases passed with native Rust socket/IPC fixtures, with no skipped
  interpreter-dependent tests; 65 Rust test functions passed, including the
  unchanged 109,436 public golden records and new metric/CLI regression tests.
- Rustfmt, Clippy with warnings denied, shell syntax and the native source
  tripwire passed. No maintained interpreter sources or requirement files remain.
- Three local recordings exercised filler, formatting and vocabulary evaluation;
  JSON rescoring preserved metrics and text. Local HTML reporting passed.
- Native LaBSE matched 30 saved reference pairs across three configurations:
  maximum absolute cosine difference 0.000048, mean 0.000020. This is a sampled
  check, not a full rebaseline of the published benchmark matrix.
- The styled DMG was built, its Finder metadata read back, and its image checksum
  verified. The app bundle remains separately signed with the existing Developer ID.

Audio and reference pairs used for local validation remain private and untracked.
No microphone capture, paste, external publishing or password entry was needed.
