# Hybrid NPU production readiness

The native MLX encoder remains the default. The finite-window CoreML candidate
recovers live previews and uses the Neural Engine, but does **not** pass the
predeclared quality gate in both paired sampling runs. No encoder weights are
included in this source change, and the installed app is unchanged.

## Quality and reproducibility

The pipeline uses the same Typhoon checkpoint, native MLX decoder, Gemma cleanup,
Rust guards and text metrics in both arms. The built-in transliteration matcher
now derives unambiguous spellings with silent letters omitted. Explicit keys
win, real Thai words and ambiguous variants are excluded, and user replacement
tables keep their literal behavior. This was developed on calibration only;
private sentences are not added to the dictionary or published as fixtures.

An unseeded repeat of the native baseline changed 28/501 raw transcripts, all
outside calibration. Whisper's temperature fallback samples. Paired tests
therefore use predeclared seeds 2026 and 2027, with a diagnostic count of sampling
attempts. Production keeps its existing sampling policy when the benchmark
variable is unset. A public fixture that reaches five sampling attempts repeated
three times with identical UTF-8 text, logprob and fallback count.

Both arms ran the actual loaded pipeline on all 501 clips with seed 2026. For
seed 2027, both arms reran the union of 32 clips with sampling fallback or missing
diagnostics in either arm. The remaining clips had no sampling in either arm
and retain their deterministic seed-2026 output. Two no-speech responses in the
first archive lacked diagnostics and were conservatively included in the union;
current source returns an empty diagnostic array when the silence gate bypasses
ASR and retains the actual attempts when ASR produces no speech.

| Seed | Encoder | Private / 264 | FLEURS / 237 | Total / 501 |
| --- | --- | ---: | ---: | ---: |
| 2026 | Native MLX | 257 | 229 | 486 |
| 2026 | Flexible INT8 CoreML | 257 | 227 | 484 |
| 2027 | Native MLX | 257 | 229 | 486 |
| 2027 | Flexible INT8 CoreML | 257 | 229 | 486 |

These count LaBSE similarity >= 0.8, not human-verified accuracy. Calibration is
194 clips (190 matches in each arm); validation is 70 private held-out clips
(67 matches in each arm) plus 237 FLEURS clips. Model recipes and cleanup rules
were fixed before this candidate's held-out test. No further recipes or gates
were tuned against the held-out failures.

For seed 2026, overall mean CER is 0.09975 native / 0.09963 hybrid; private keyword
recall is 0.81912 / 0.82258 over 231 annotated clips. FLEURS has no keyword labels,
so no keyword-recall result is claimed for that cohort. No cleanup errors
occurred. The small improvements in other metrics do not override the failed
FLEURS semantic-count gate. Seed 2027 passes the quality gates, but promotion
requires both paired seeds to pass.

The gates were fixed before results: semantic counts at least native in each
validation cohort, mean similarity within 0.001, CER within 0.002 overall and on
validation (0.005 per validation cohort), keyword recall within 0.005 overall
and 0.01 per annotated cohort, and zero model/transport/cleanup errors.

## Encoder and live preview

The selected graph retains the upstream WhisperKit encoder arithmetic and
source positional embeddings, with finite mel windows 1000/1500/2000/2500/3000
and symmetric per-channel INT8 weights. Both FP16 and INT8 were frozen and
selected on calibration. CPU FP16 export parity with Torch was 52.24 dB PSNR
at 1000 frames and 54.76 dB at 3000. Numerical parity alone is not ASR parity.

Source learned weights were checked against the current MLX checkpoint: all
586 tensors match after layout conversion and FP16 rounding. Source snapshots:

- HF Typhoon: `3c03fa84c26f172944422ceb8a4e88a2dbc08b10`.
- MLX Typhoon: `add34db61213af09bd4bfe8dd17174543548e659`.
- Exporter: WhisperKit tools `84f77a` with coremltools 9 / Torch 2.5.

The Swift bridge rounds a preview up to a supported finite window. The final
still uses the full 3000 frames. Actual output dimensions, dtype and strides
are checked; flexible CoreML metadata may legitimately omit a static output
shape. Cancellation is checked around the encoder call and between decoder
tokens. A synchronous CoreML prediction cannot be interrupted mid-call.

The model uses `.cpuAndNeuralEngine` and
`optimizationHints.reshapeFrequency = .infrequent`. An isolated Instruments
trace contains 16 actual ANE hardware intervals attributed to
`AudioEncoder_main_*__Op0_AneInference`; this is device evidence, rather than
inferring placement from configuration. Apple documents flexible-shape
specialization in its [flexible inputs guide](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html).

The original fixed-window graph had a realtime release-wait p90 of 186 ms,
beyond the existing 150 ms governor budget. It is not promoted. The finite-window
candidate's realtime and resource measurements are recorded below.

Two isolated warm runs used the same 43 clips, seed and actual loaded pipeline,
in ABBA order. No build, conversion, training or other benchmark ran during them.
Latency includes audio conversion, STT retries and cleanup; it excludes recording
and the initial model warm. Memory sampling includes model loading and adds the
simultaneous physical and neural ledgers of the owned inference and Rust workers.

| Encoder | Median seconds, runs 1 / 2 | p90 seconds, runs 1 / 2 | Sampled physical + neural peak GB, runs 1 / 2 |
| --- | ---: | ---: | ---: |
| Native MLX | 0.947 / 0.969 | 1.199 / 1.212 | 5.50 / 5.53 |
| Flexible INT8 CoreML | 1.146 / 1.136 | 1.345 / 1.348 | 4.35 / 4.79 |

The hybrid uses less sampled owned memory but is 17–21% slower at the median,
failing the predeclared limit of at most 5% slower in either run. Sampled peaks
are lower bounds, not allocator-exact maxima or an estimate for a smaller Mac.
Neural allocation was about 0.93 GB at both hybrid peak samples; it is included,
not treated as free memory. First-load specialization is excluded from the warm
latencies and addressed separately by the preparation process.

The realistic preview A/B uses three public synthetic utterances and one quiet
16.44-second FLEURS clip, with the actual pacer and unchanged 150 ms governor.
Both encoders preserve final UTF-8 bytes in all 4 clips and keep previews enabled.
The quiet clip triggers the silence gate in both arms and shows no preview; it
does not demonstrate long-window speech preview. For the three hybrid releases
with a preview in flight, wait median/p90 is 78/172 ms (max 195 ms); native has
two such releases at 5/7 ms. These are small timing samples, and the hybrid still
exceeds the budget. First-word median is 708 ms hybrid / 713 ms native on the
three audible clips. An additional audible long-window probe is recorded below.

The first public clip at least 15 seconds long with RMS >= 0.02 supplies a
separate runtime probe (17.34 seconds), chosen by duration/amplitude rather than
transcript or quality outcome. Hybrid shows 34 previews, preserves final bytes
and keeps the governor enabled. Its measured in-flight release waits 14 ms on
that one hold; this does not override the budget failures above or establish a
latency guarantee. Native shows 33 previews and also preserves final bytes,
waiting 3 ms at release on its measured hold. The failed staging attempt (missing tokenizer symlink in the
isolated harness) was corrected before the measured probe; no model was changed.

## Prepared components and recovery

An optional app build can supply a component through `OLIV_COREML_ENCODER_DIR`.
Source builds without it continue using MLX. No release workflow supplies a
component by default, and this failed candidate must not be used as a shipping
default. Automatic components require macOS 15 or newer; explicit developer
experiments keep their existing opt-in behavior.

A component directory contains `manifest.json`, `AudioEncoder.mlmodelc`,
`LICENSE-typhoon` and `LICENSE-whisperkittools`. Manifest version 1 has:

- `sourceRepository`: exactly `chayapats/typhoon-whisper-turbo-mlx`.
- `sourceFiles`: SHA-256 for exactly `config.json` and `weights.safetensors`.
- `modelFiles`: SHA-256 of every regular file relative to the compiled model.

Preparation and loading reject corrupt, missing, extra and symlinked model
files. Model hashes stream in bounded buffers. A manifest fingerprint binds
local readiness receipts to the exact component and this host/OS version.
The receipt is local; no machine identifier is sent anywhere.

`oliv-encoder-prepare` links CoreML without MLX. It verifies the component,
performs zero-input predictions for every supported window, and writes readiness
atomically only after success. A separate process prevents first specialization
from blocking dictation's serialized request queue. It exits on parent death,
warning/critical memory pressure or a 600-second deadline. An advisory lock
prevents duplicate preparations. The UI schedules it after five idle seconds
and cancels when recording starts. A completed component activates through an
idle helper reload, retaining the user's cleanup memory mode and cloud key.

The inference helper activates only a prepared, integrity-checked component
whose source hashes match the selected checkpoint. Other models, an unprepared
component or a mismatch keep MLX. `OLIV_WHISPER_ENCODER=mlx` disables managed
activation for controls. Explicit `OLIV_WHISPER_ANE_ENCODER` experiments remain
fail-fast unless `OLIV_WHISPER_ANE_FALLBACK=1` is requested.

Managed model-load and prediction failures retire CoreML and lazily restore only
the original MLX encoder, keeping the decoder and current utterance. The helper
remembers a failure instead of retrying the accelerator every utterance.
Load/prediction recovery, including failure during a preview, preserved exact
native final bytes and left the helper reusable.

## Validation

Local host: M4 Pro, 48 GB unified memory, macOS 27.2. Actual Neural Engine use is
verified for this host. No power, battery-life or 8/16 GB-machine claim is made.
The NPU also uses unified memory; device placement alone does not establish RAM
or energy savings.

- Rust workspace: 243 tests passed; formatting and Clippy passed.
- Swift: 557 tests, 9 skipped, zero failures. The full suite used an isolated
  internal model-cache directory; a first attempt blocked reading the external
  developer cache, and its stack sample identified filesystem access.
- Public model integrations: finite windows, preview cancellation, unchanged
  final bytes, strict failures, opt-in recovery and paired sampling passed.
- Review follow-up: 29 targeted Swift tests passed, including cancellation
  before recovery reads weights and retrying the preserved loader. The public
  integration scripts now force MLX controls and seed 2026. They passed against
  a staged prepared component that otherwise selects CoreML, with conflicting
  inherited backend/seed settings. Sampling exercised five attempts per request.
- Actual managed-component integration: unprepared MLX, prepared CoreML,
  forced MLX, checkpoint mismatch, corrupt component, and restored CoreML all
  behaved as intended. The MLX paths retained identical final bytes. Tests used
  a staged component and isolated receipt directory, without altering a real
  checkpoint, the installed app or the global model cache.
- Native preparation/routing and the queued idle reload were tested separately.
  Installed-app activation of the failed candidate was not performed.
- Native source check passed; the app build signs all three helpers and verifies
  the assembled Python-free bundle. Persistent packaged IPC and a public-file
  STT-to-cleanup smoke test passed without text injection. The source app has no
  encoder component; it is not installed over the user's current app.

Optional model integrations require cached weights and public WAV fixtures:

```sh
OLIV_WHISPER_ANE_ENCODER=/path/AudioEncoder.mlmodelc \
  swift scripts/test_hybrid_preview.swift build/native-runtime public.wav
swift scripts/test_hybrid_recovery.swift build/native-runtime \
  /path/wrong-output/AudioEncoder.mlmodelc public.wav
swift scripts/test_whisper_sampling.swift build/native-runtime public-fixtures.jsonl
```

Private audio, raw/final text, calibration manifests, local readiness receipts,
model weights, sampled processes and Instruments trace bundles remain outside
Git. Only aggregate results are published here.
