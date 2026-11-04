# NPU and memory optimization, second pass

This work prioritizes transcription quality and complete-pipeline memory over
model-file size or a compute-device preference. The production STT default is
still the native MLX decoder. Experimental Core ML graphs are opt-in.

## Evaluation boundaries

The frozen control is main `7c9b610`, rebuilt with the current native runtime.
There are 501 utterances: 194 calibration/main, 70 private held-out and 237
FLEURS recordings. Profile selection, training and synthetic-data augmentation
use only the main set. Held-out recordings are never training inputs. Private
audio, transcripts, generated text and distilled weights stay outside Git.

Quality includes the production Rust text guards, native Thai CER/WER, and
LaBSE similarity >= 0.8. A numerical export check alone cannot establish ASR
parity. Measurements come from an M4 Pro, 48 GB unified memory, macOS 27.2.
Neural Engine auxiliary memory must be counted alongside physical footprint
for every owned process, including cleanup children.

## Results and shipping decision

Only the cleanup memory policy and its Settings control are enabled by default.
The residency replay produced **identical raw/final text, LLM decisions, guardrail
flags and cleanup errors on all 501 clips**. The NPU and smaller-model paths
remain developer experiments.

| Pipeline | Private / 264 | FLEURS / 237 | Total / 501 |
| --- | ---: | ---: | ---: |
| Frozen native MLX + Gemma | 257 | 228 | 485 |
| MLX + Gemma with residency policy | 257 | 228 | 485 |
| Hybrid FP16 encoder + native decoder + Gemma | 256 | 228 | 484 |
| Hybrid INT8 encoder + native decoder + Gemma | 256 | 229 | 485 |
| Native MLX + distilled Qwen3 1.7B | 242 | 227 | 469 |

These are LaBSE threshold counts, not human-verified accuracy percentages.
The INT8 hybrid's aggregate tie hides one additional private-set failure.
The distilled model improved calibration from 183/194 to 188/194, but reached
only 281/307 on held-out evaluation versus Gemma's 295/307. Neither qualifies
as a quality-preserving replacement.

### Latency and active memory

Two sequential runs use the same 43 utterances. Per-clip latency includes audio
conversion, production STT retries and cleanup; models are warmed first.
Recording time and initial model specialization are excluded from these
per-clip values. No training or conversion ran during these measurements.

| Pipeline | Median seconds, runs 1 / 2 | p90 seconds, runs 1 / 2 | Sampled owned physical + neural peak GB, runs 1 / 2 |
| --- | ---: | ---: | ---: |
| Frozen native MLX + Gemma | 0.977 / 0.977 | 1.306 / 1.251 | 6.90 / 6.05 |
| Native MLX + Gemma, residency | 0.991 / 0.999 | 1.296 / 1.216 | 5.51 / 5.54 |
| INT8 hybrid + Gemma | 0.730 / 0.729 | 1.115 / 1.096 | 5.70 / 5.15 |
| Native MLX + distilled Qwen3 | 0.912 / 0.884 | 1.138 / 1.118 | 3.78 / 3.80 |

The first hybrid process took 149 seconds in total; the repeat took 37 seconds.
Warm prediction speed therefore does not describe its initial setup cost.
Sampled peaks include model loading, use simultaneous owned physical and neural
allocations, and are lower bounds rather than allocator-exact peaks. The
residency policy's robust benefit is idle weight release; two short runs do not
establish a precise reduction in active peak RAM or a latency guarantee.

### Idle memory and prewarming

With native STT and Gemma loaded in the same helper, physical footprint was
4.61 GB. After the real 30-second idle timeout it was **1.89 GB**, with the
STT model retained. MLX active allocations fell from 4.222 GB to 1.618 GB,
releasing **2.604 GB**. This excludes the UI and Rust process. Active inference
still has a multi-GB peak; idle release does not eliminate that peak.

An isolated cleanup test kept STT resident and simulated recording after a
background reload. Two repeats, warm file cache:

| Simulated recording seconds | Median remaining cleanup-generation seconds |
| ---: | ---: |
| 0 | 2.797 |
| 0.5 | 2.297 |
| 1 | 1.808 |
| 2 | 0.811 |
| 3 | 0.153 |
| 5 | 0.154 |

This uses public fixture text and isolates reload overlap; it is not an
end-to-end dictation latency estimate. Short speech after eviction can expose
the reload cost. Fast response mode retains the model to avoid that idle cost,
while both modes still release it under memory pressure. Actual power savings
were not measured, and no energy claim is made.

## Cleanup residency

The helper leases the cleanup model while loading, generating or tokenizing.
It releases unused cleanup weights after 30 seconds, and responds to memory
pressure after active leases finish. Epochs prevent old timers from evicting a
new request. Repeated background warms share a load. The app starts a load-only
cleanup warm after microphone startup at each eligible press; voice editing
warms its local cleanup model even with remote STT.

A per-recording token prevents idle eviction from that warm until transcription
and cleanup finish, including recordings longer than the idle timeout. Capture
failure, a cancelled opening, controller stop and processing completion release
the token. Releases are idempotent and ordered after their corresponding warm;
an older recording cannot release a newer one. Memory pressure may still evict
an idle reserved model, while actual loading/generation leases remain protected.

The model, prompt, generation settings and text guardrails are retained. Idle
eviction introduces a reload cost; recording-time prewarming must be evaluated
alongside warm response time. Allocator cache clearing alone does not unload
model weights.

Settings > General > Memory use offers **Save memory** (30-second idle timeout,
the default) and **Fast response** (keep cleanup ready until memory pressure).
The preference is persisted and applied live, including after a worker respawn.
Switching to Fast response starts a background load without restarting the app.

Developer controls (these do not add model choices to the app):

- `OLIV_CLEANUP_IDLE_SECONDS`: idle timeout, default 30; 0 disables idle eviction.
  Memory-pressure trimming remains active. Invalid values use the default.
- `OLIV_CLEANUP_REPOSITORY`: an already cached cleanup-model repository.
- `OLIV_CLEANUP_MODEL_DIRECTORY`: a local experimental checkpoint; takes
  precedence over the repository when loading cleanup.
- Helper JSONL `memory_status`: residency, active users and MLX allocation bytes.
- Helper JSONL `llm_trim`: request eviction; active work finishes first.

With the model already downloaded, run the optional integration check:
`swift scripts/test_cleanup_residency.swift build/native-runtime`.
It uses public fixture text and a three-second test timeout, checks stale timer
invalidation, deferred eviction, reload and actual MLX allocation release.

## Hybrid encoder experiment

`OLIV_WHISPER_ANE_ENCODER=/absolute/path/AudioEncoder.mlmodelc` loads a fixed
30-second Core ML encoder with CPU + ANE preference and omits the MLX encoder's
parameters. Native mel computation, decoder, language detection, token sampling,
fallback, prompts and Rust guards are retained. The output bridge respects
Core ML strides. This experiment rejects short-window live previews and is
not exposed as a shipping engine. Device tracing and held-out validation are
required before promoting it.

## Stateful and Core AI experiments

The optional [WhisperKit adapter](../tools/ane-whisper/README.md) supports Core ML
KV states. Slice updates, in-place additive updates and eight per-layer states
all passed CPU numerical checks but failed ANE planning with error -14. A small
stateful toy model did load with CPU + ANE, so this is a graph-specific failure.
The compatibility adapter still allocates WhisperKit's host cache buffers.

Apple's standalone Core AI Whisper recipe was pinned at
`1286758abeb1d81fc4596083200197272acf20ae`. Its dynamic-prefix conversion failed
in Torch decomposition; a fixed four-token FP16 numerical probe succeeded
(66.88 dB logit PSNR; four argmax matches). Instruments showed MPSGraph execution
and no ANE hardware intervals for that probe. It re-encodes audio on every call
and is not an efficient autoregressive runtime.

Core AI cached decoder probes use persistent key/value buffers and test eight
steps plus a reset. They require separate placement and numerical checks;
requesting `.neuralEngine` alone is not evidence of ANE execution.

The cached FP32 probe passed all nine argmax/reset checks, with minimum logit
PSNR 87.96 dB. The FP16 probe passed with minimum 53.82 dB. A subsequent isolated
Instruments trace routed the FP16 decoder through MPSGraph and recorded zero
ANE intervals. These are functional conversion successes, not NPU successes.

## Compression and task-specific cleanup

The compression candidate uses group-16, per-channel-scaled 4-bit palettes for
encoder transformer weights, retaining input convolutions and positional
constants in FP16. The full Core ML path retains the prior INT8 decoder; the
hybrid path retains the native decoder. The source model is converted to the
iOS 18 Core ML specification before applying grouped palettization.

Qwen3 0.6B and 1.7B 4-bit cleanup are tested with the same Rust pipeline and
thinking disabled. A separate 1.7B LoRA experiment learns from 90 production
Gemma calls from calibration only, plus authored synthetic examples. Ten teacher
pairs are reserved for training validation. Held-out speech remains separate.
Training loss does not qualify a replacement model for shipping.

The grouped PAL4 encoder converted and loaded, but the guarded run advanced only
12 clips in approximately four minutes and was stopped for latency infeasibility.
A bounded public hybrid smoke then exceeded the runtime's startup budget.
The unfinished 194-clip run supplies no final accuracy result. This candidate
was rejected rather than replacing the current model with an unvalidated one.

## Validation

- 237 Rust workspace tests; format and Clippy with warnings denied passed.
- 89 selected XCTest cases covering policy leases, Settings persistence, live
  IPC/respawn behavior, localization and dictation/voice-editing regressions.
- Optional native model integration passed actual allocation release, timer
  invalidation, deferred trim, coalesced loads, reload, disabling idle eviction
  and enabling it again without restarting the helper.
- English and Thai Settings renders checked both modes; native IPC smoke,
  benchmark resume/input-integrity checks and native-source policy passed.

Conversion and training dependencies remain in ignored developer build folders.
Research pins: Core ML Tools 9 / Torch 2.5 for Core ML, coreai-core 1.0.0b3 /
coreai-torch 0.4.3 / Torch 2.9 for Core AI, and MLX LM 0.32.2 for distillation.
The Apple Core AI source pin is recorded above; WhisperKit remains pinned by
the tool's package lock. Owned runtime and maintained helpers remain native.

References: [Core ML stateful models](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html),
[Core ML compression](https://apple.github.io/coremltools/docs-guides/source/opt-workflow.html),
[Apple Core AI models](https://github.com/apple/coreai-models),
[MLX LM fine-tuning](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md).
