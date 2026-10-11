# Python-free Mac runtime

OLIV now uses a shared Rust text/API core adapted from OLIV Linux, and native
MLX Swift inference for Whisper and Gemma. Swift continues to own microphone,
hotkeys, settings, Keychain and paste. Neither the app nor `build_app.sh` needs
Python. The subsequent developer-tool migration also removes Python from
benchmarks, test fixtures and DMG packaging; see [developer tooling](native-developer-tools.md).

## Architecture and compatibility

- `rust/crates/oliv-text`: deterministic Thai/English cleanup, dictionary,
  vocabulary, guardrails, fillers, formatting commands and audio gates.
- `rust/crates/oliv-transport`: WAV encoding, OLIV API and opt-in Groq requests;
  platform certificate trust, bounded replies, no redirects or automatic replay.
- `rust/crates/oliv-sidecar`: private JSON stdio, lazy model helper, bounded stage
  deadlines, progress forwarding and process recovery. API requests run as
  cancellable transactions without initializing local models.
- `rust/crates/oliv-tokenizer`: Hugging Face tokenization through a C header and
  owning Swift wrapper. Gemma chat-template tokens are rebuilt with the Rust
  tokenizer to preserve its byte-fallback and pretokenization behavior.
- `macos/OLIVInference`: native MLX models, offline HF cache loading and explicit
  model downloads. Whisper retains timestamp seek/context, precise attention,
  confidence-based English re-decode and temperature fallback. Legacy NPZ
  checkpoints load through macOS unzip and MLX's NPY reader.

Model weights remain in the existing HF cache, outside the app. The supported
local engines are Typhoon Turbo, Pathumma MLX and Whisper large-v3. The Gemma
model and text prompt remain the E2B/V2 configuration. Greedy output can differ
at numerical ties between native and Python kernels; word-for-word identity is
not promised. Failed cleanup retains deterministic corrections and text.

## Verification on 2026-10-09

Apple M4 Pro, 48 GB RAM. Baseline and native inference receive identical
Float32 mono/16 kHz PCM. Local inference only; no audio uploaded to a service.
Measurements use warmed models, a sequential pass through the existing 194-clip
main corpus and 70 additional clips, and matching per-bucket feature settings.
Recordings and per-clip outputs remain untracked. Timing varies with hardware
and system load; these measurements do not measure live microphone startup.

| Measure | Python reference | Rust + native MLX |
|---|---:|---:|
| Main 194: median STT + cleanup | 1.117 s | 0.865 s |
| Main 194: p95 STT + cleanup | 1.517 s | 1.373 s |
| Main 194: mean WER | 12.58% | 12.34% |
| Main 194: mean CER | 8.16% | 7.95% |
| All 264: mean WER | 14.53% | 14.55% |
| All 264: mean CER | 9.19% | 9.18% |

The main-corpus median improves by 22.5%. Aggregate accuracy is comparable:
WER differs by 0.012 percentage points across all 264 clips, and CER slightly
improves. Individual utterances can improve or regress. Native cleanup returned
no errors across all 264 clips.


Worker launch + model-free ping, median of ten fresh process launches:
Python 44.78 ms; Rust 3.48 ms. Both measurements use cached executable files.
Signed app size: 356 MiB → 85 MiB (about 76% smaller, excluding model weights).

Validation completed:

- 58 Rust test functions, including 109,436 public synthetic/reference fixture
  records, tokenizer Unicode parity and private stdio behavior.
- 259 Swift tests, including the production Rust API transport, loopback request
  contents, rejected redirects/certificates, cooldowns and cancellation.
- Rust formatting and Clippy with warnings denied; shell syntax and benchmark
  driver checks.
- Persistent bundled worker IPC with stdin open, clean EOF and code signature
  verification. All three local Whisper engines and Gemma execute offline from
  the packaged app while the working directory is outside the repository.
- No fresh microphone capture, paste, password entry or user-assisted permission
  tests were needed. The existing signing identity and designated requirement
  are preserved for the installed app.

The XCTest host skips real app initialization so automated tests do not read
Keychain credentials or initialize hotkeys, microphone, onboarding or updates.
The distributable has a build tripwire rejecting Python files/interpreters and
ships dependency notices. No JIT entitlement is needed by the native helpers.

## Reproduce

```sh
bash scripts/test.sh
bash scripts/build_dev.sh
HF_HUB_OFFLINE=1 build/native-tools/oliv-dev eval \
  --manifest data/manifest_all.jsonl \
  --out benchmark/eval_results/native-main.json
```

Use your own recordings and explicitly downloaded models. `latency_s` includes
benchmark file conversion; `t_stt` and `t_cleanup` isolate runtime stages.
Public golden fixtures were frozen from public test literals and
invented examples, with mocked LLM replies. Private OLIV Linux corpus-derived
fixtures and recorded generations are excluded from Git.

Sources and licenses are pinned in `rust/crates/*/UPSTREAM.md`,
`macos/OLIVInference/UPSTREAM.md`, `rust/Cargo.lock` and `macos/Package.resolved`.
Model revisions used for the paired quality run:

- Typhoon: `1631224cc3adc220cc0cc77bce3e8c0aada9f261`.
- Gemma E2B: `238767527555cb75a05732a84dff5d6ba0dd6809`.
