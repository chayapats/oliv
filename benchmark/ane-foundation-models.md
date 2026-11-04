# Typhoon on the Neural Engine and Apple local cleanup

Measured on 4 November 2026, M4 Pro with 48 GB unified memory, macOS 27.2
(build 26B123). Developer benchmarks only; the installed app continues to use
MLX Typhoon and Gemma. This follows the [Apple dictation comparison](dictation-transcriber.md).

**Keep MLX Typhoon + Gemma as the default. INT8 on ANE is a useful experimental
candidate, with about 1.05–1.30 GB less sampled owned memory in the full pipeline
(19–23%), but the private-corpus meaning match falls from 97.3% to 94.3%.
FP16 on ANE uses more full-pipeline memory in this run. The tested 4-bit recipe
fails accuracy. Apple local cleanup is not ready to replace Gemma for OLIV’s
Thai–English workload: Thai is unsupported and meaning match remains 88.3%
even with preservation instructions and content-transformation guardrails.**

## What was tested

| Speech runtime | Weights | Compiled Core ML files | Cleanup choices |
|---|---|---:|---|
| Production MLX | Existing Typhoon MLX checkpoint | — | Gemma; Apple original/strict/transform |
| Core ML / WhisperKit, CPU + ANE | FP16 | 1.628 GB | Gemma; Apple strict |
| Core ML / WhisperKit, CPU + ANE | Per-channel symmetric INT8 | 0.821 GB | Gemma; Apple strict/transform |
| Core ML / WhisperKit, CPU + ANE | Per-tensor k-means 4-bit palette | 0.416 GB | Gemma; Apple strict |
| Core ML / WhisperKit, CPU + GPU | FP16 | 1.628 GB | Gemma, matched timing control |

Sizes are decimal GB, sum of compiled encoder/decoder/mel files, not measured
RAM or total installation size. The mel front end remains uncompressed on CPU.
The compression threshold is 2,048 elements. The 4-bit result applies to this
data-free per-tensor recipe; grouped-channel, mixed-precision or calibrated
compression were not evaluated. Apple's [palettization guide](https://apple.github.io/coremltools/docs-guides/source/opt-palettization-algos.html)
explains why lower-bit data-free compression can lose accuracy.

The [conversion recipe](../tools/ane-whisper/CONVERSION.md) pins the converter,
WhisperKit and dependencies. HF `typhoon-ai/typhoon-whisper-turbo` revision
`3c03fa84c26f172944422ceb8a4e88a2dbc08b10` and MLX
`chayapats/typhoon-whisper-turbo-mlx` revision `1631224cc3adc220cc0cc77bce3e8c0aada9f261` have matching
806,958,080 learned parameters across all 586 mapped tensors after conv
transposes and BF16→FP16 conversion. This is a weight-identity check, not output
identity: MLX rebuilds the fixed encoder sinusoid in FP32, and decoder/runtime
arithmetic differs. The reference conversion explicitly enables the KV cache;
the training checkpoint's `use_cache:false` otherwise invalidates its reference
comparison. FP16 conversion checks passed: encoder 51.1 dB PSNR, decoder 46.9 dB,
mel 67.9 dB. The unconverted decoder reference matched argmax 100% in the sampled
check (134 dB).

Every primary Core ML STT result goes through the real Rust sidecar, including
confidence-based forced-English retry, silence and duration gates. Direct
WhisperKit auto-decode runs were retained as secondary ablations and are not
used for the primary comparison. Cleanup replays use exactly the same raw
transcripts for each paired Gemma/Apple comparison. The historical FLEURS live
Gemma baseline had 26 raw-transcript differences, so Gemma was replayed again
from the identical frozen MLX STT input for the cleanup comparison.

WhisperKit starts at temperature zero and permits five temperature fallback
steps. These are observed runs, not a guarantee of identical decoding on every
repeat. Confidence comes from each decoder, so its calibration and the exact
clips that trigger the shared Rust retry can differ between backends.

## Accuracy

The private corpus has 264 recordings (194 everyday, 40 held-out, 30
confirmation), all from one speaker. FLEURS Thai contributes 237 recordings of
80 sentences read by multiple speakers. Keep these populations separate; they
are not 501 independent real-world user trials. No private audio/transcripts
or ContextASR reference/hypothesis text is included here.

Meaning match is the share of clips with native segmented LaBSE cosine ≥0.80.
WER/CER use Rust newmm/NFC; CER ignores spaces. These are average per-clip
scores, not human grading. A sentence-level semantic threshold can miss a wrong
name or number, so the ContextASR and character-error results matter too.

| Speech / cleanup | Private meaning match | Private CER | FLEURS meaning match | FLEURS CER |
|---|---:|---:|---:|---:|
| MLX · STT only | 71.2% (188/264) | 0.280 | 96.6% (229/237) | 0.101 |
| ANE FP16 · STT only | 68.6% (181/264) | 0.297 | 96.2% (228/237) | 0.098 |
| ANE INT8 · STT only | 69.7% (184/264) | 0.289 | 97.0% (230/237) | 0.095 |
| ANE palette4 · STT only | 0.0% (0/264) | 0.967 | 0.0% (0/237) | 0.994 |
| MLX → Gemma | 97.3% (257/264) | 0.090 | 96.6% (229/237) | 0.111 |
| ANE FP16 → Gemma | 94.3% (249/264) | 0.105 | 96.2% (228/237) | 0.108 |
| ANE INT8 → Gemma | 94.3% (249/264) | 0.106 | 96.6% (229/237) | 0.105 |
| ANE palette4 → Gemma | 0.0% (0/264) | 0.962 | 0.0% (0/237) | 0.995 |

INT8 and FP16 both retain 249 of 264 private clips above the semantic threshold,
eight fewer than the paired MLX/Gemma baseline. INT8’s aggregate private semantic
score is therefore unchanged from FP16 in this experiment; the gap to MLX
cannot be attributed only to 8-bit compression. The runtime, decoder and
arithmetic also differ. On FLEURS, INT8/Gemma matches the MLX/Gemma aggregate
semantic result, while FP16 misses one additional clip. This is not evidence
of equivalence across speakers or domains. The two empty FLEURS outputs from
the shared production silence gate remain in the denominator.

The per-tensor palette4 recipe has zero semantic matches in both populations;
cleanup cannot recover the lost speech content. The three-clip public CPU control
also gives palette4 CER 1.000, versus FP16 0.216; the failure therefore reproduces
with CPU-only execution. This is a tiny public sanity check, not a CPU accuracy
benchmark.

## Apple Foundation Models cleanup

This machine exposes **AFM 3 Core Advanced**, using
[`SystemLanguageModel.default`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
on-device. The runtime reports English supported
and **Thai unsupported** (`supportsLocale(th_TH) == false`). The variant name
is not a parameter-count claim; this benchmark does not assume an older 3B
model. No cloud model is instantiated. Gemma is `mlx-community/gemma-4-e2b-it-4bit` revision
`238767527555cb75a05732a84dff5d6ba0dd6809`. Check availability and supported locales
at runtime because the OS model can change.

Three conditions keep the same Rust cleanup gates and fallback guards:

1. Original OLIV cleanup prompt, default Apple model guardrails.
2. The same prompt plus [preservation instructions](../tools/apple-cleanup/preserve-language.txt),
   default Apple model guardrails.
3. The preservation instructions plus Apple's documented
   [`permissiveContentTransformations`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/guardrails/permissivecontenttransformations)
   mode for text rewriting. This changes the model's content-transformation
   behavior; Rust's translation/span-loss/edit-distance guards remain active.

All generations use a fresh session and greedy sampling. Most clips skip the
language model according to production gates: report errors per actual cleanup
request as well as per full corpus. An OS model safety exception falls back to
the dictionary path and remains counted; a successful final clip is not proof
that Apple generated a useful cleanup. Thai being unsupported does not mean
every request throws an unsupported-language exception.

| Speech input / Apple condition | Private meaning / CER | FLEURS meaning / CER | Generation errors / requests |
|---|---:|---:|---:|
| MLX / original prompt | 88.3% / 0.168 | 97.0% / 0.103 | 11/222 |
| MLX / preservation | 88.3% / 0.151 | 97.0% / 0.099 | 8/222 |
| MLX / preservation + transformations | 88.3% / 0.151 | 97.0% / 0.099 | 0/222 |
| INT8 / preservation | 87.1% / 0.160 | 97.0% / 0.095 | 8/221 |
| INT8 / preservation + transformations | 87.1% / 0.160 | 97.0% / 0.095 | 0/221 |

Preservation instructions reduce private CER from 0.168 to 0.151, but leave
semantic match at 233/264, versus Gemma’s 257/264 on exactly the same MLX raw
transcripts. Content transformations remove the observed generation exceptions;
they do not improve the private semantic match or CER. Error-free requests do
not establish cleanup quality or supported Thai behavior.

The request denominator counts helper generation RPCs across the full 501-clip
run, rather than independent user utterances. FLEURS mostly passes through the
production gates without invoking a language model, and its similar end score
does not establish Thai cleanup parity. These results include the unchanged
Rust guardrails and dictionary fallback; they are not the bare Apple model’s
unprotected answers.

The helper's unknown stop reason and missing production editing/cancellation
contract also mean it is not a drop-in replacement for all voice editing.

## Names and contextual vocabulary

The frozen Thai ContextASR 300-utterance subset uses INT8 STT through the same
Rust confidence retry. Both cleanup choices replay identical raw speech into
the native upstream-compatible scorer. All 1,146 planned pairs are present:
`none`, `bias@50` and `dis@50` have 300 each; `bias@0` has 246 utterances with
entities. The data includes synthetic voices and has different reference-script
preferences from OLIV’s private corpus. Metrics here use ContextASR’s
alias-aware scorer, not the per-clip CER average above. Percentages below.

| Cleanup | `none` CER / recall | `bias@0` recall / listed form | `bias@50` CER / recall / listed form | `bias@50` B-CER | `dis@50` wrong insertions |
|---|---:|---:|---:|---:|---:|
| Gemma | 6.20 / 41.50 | 64.00 / 49.50 | 5.69 / 63.75 / 49.25 | 15.14 | 3 / 14,995 |
| Apple preservation, default guardrails | 5.94 / 42.50 | 62.75 / 49.00 | 5.52 / 62.75 / 49.00 | 13.59 | 2 / 14,995 |

Raw INT8 STT scores CER 5.71% and entity recall 43.0% without a list. Vocabulary
raises recall to about 63–64% for both cleanup choices. Apple has lower CER in
this subset, while Gemma retains slightly higher listed-name recall; this does
not reverse Apple’s weaker private-corpus result. Alias-aware CER reference
lengths can differ by hypothesis, so recall and exact listed spelling should
be considered alongside CER. Apple has 11 dictionary fallbacks after generation
exceptions in `none`, 10 in `bias@0`, 13 in `bias@50`, and 11 in `dis@50`;
these are condition-level counts over repeated utterances, not 45 unique
failures. This name experiment uses default Apple guardrails, not the
content-transformation variant. No per-clip copyrighted text is published.

## Latency and unified memory

The controlled round runs the same 43 clips through the actual full Rust
pipeline, with speech and cleanup models resident together. MLX+Gemma is run
first and last to reveal desktop drift. Core ML specialization is completed
before timing. File conversion is included; loading/specialization is excluded.
Replay cleanup time is not a full-pipeline speed measurement.

| Configuration | Median | p90 | Sampled owned memory, phys + neural |
|---|---:|---:|---:|
| MLX + Gemma (start) | 0.959 s | 1.207 s | 5.44 GB |
| ANE INT8 + Gemma | 0.920 s | 1.403 s | 4.38 GB |
| ANE FP16 + Gemma | 1.066 s | 1.451 s | 6.25 GB |
| ANE palette4 + Gemma | 2.781 s | 6.267 s | 3.51 GB |
| ANE INT8 + Apple transformations | 0.904 s | 1.408 s | not comparable: shared Apple service |
| Core ML FP16 CPU+GPU + Gemma | 1.497 s | 2.008 s | 4.90 GB |
| MLX + Gemma (repeat) | 0.953 s | 1.205 s | 5.68 GB |

INT8’s median is slightly lower than MLX’s, but its p90 is slower. It is not a
uniform latency win. MLX start/repeat medians are 0.959/0.953 s, showing little
latency drift in this round. Its sampled memory peaks still vary from 5.44 to
5.68 GB. INT8’s 4.38 GB is about 1.05–1.30 GB lower; FP16 ANE reaches 6.25 GB.
Simply moving to ANE therefore does not guarantee a RAM reduction. Palette4’s
lower allocation is accompanied by unusable speech and slower decoding.

The earlier round overlapped model compilation and is not used to rank close
performance differences. This controlled round serializes our inference jobs
with a shared lock; other desktop activity is still present. One 43-clip round
is an engineering measurement, not a population latency guarantee.

Memory is the largest simultaneous sampled sum of the owned Rust sidecar,
speech helper and cleanup child footprints. On this Mac, ANE weights live in
an auxiliary `neural` ledger marked `nofootprint`; headline RSS/physical footprint
alone excludes them. We add `phys_footprint + neural` for each owned process,
then sum processes at each sample. Footprints are sampled about every 5.6
seconds, so this is a sampled peak, not an exact maximum. The benchmark tool
and installed app UI are not included.

For the loaded speech helper, neural allocations were 1.659 GB FP16, 0.850 GB
INT8 and 0.449 GB palette4, plus roughly 0.12 GB physical footprint. Moving a
model to ANE does not remove its weights from unified RAM. Compression, resident
caches and the cleanup model determine the practical savings.

Apple's text model runs in a shared `TGOnDeviceInferenceProviderService`. The
current user cannot read that service's full physical/neural ledger. Its small
caller footprint is not total Apple model memory, so **no total-RAM saving is
claimed for replacing Gemma with Apple**. `powermetrics` also requires privileges
not available in this run; energy/watts were not measured. Global GPU samples
include the desktop and do not identify per-model GPU work.

## Did it actually use ANE?

The STT model permits only CPU + ANE; [`cpuAndNeuralEngine`](https://developer.apple.com/documentation/coreml/mlcomputeunits)
excludes GPU. That does not guarantee all operations use ANE. The FP16 compute
plan assigns all 22,247 encoder operations to ANE and 203 of 205 decoder
operations to ANE. Two CPU embedding gathers have about 39% of the decoder's
**estimated** cost; operation count is not utilization or wall-clock share.

An Instruments Core ML recording of INT8 decoding eight clips (plus one warm-up)
contains **9 encoder and 501 decoder ANE hardware `Prediction` intervals**
with the matching model names. These are execution events, not just preferred
compute units. They establish actual ANE use; they do not establish that every
operation or every millisecond runs there. The exported high-level Core ML
activity table is empty, so no full per-operation wall-time allocation is
claimed. Profiling timings are not used as ordinary latency measurements.

Gemma still uses the GPU when it performs cleanup. This experiment does not
measure rendering smoothness during gaming/video editing or claim that the
whole app becomes GPU-free.

## Preview, cold setup and integration

A simple real-time snapshot prototype on eight private clips records
47 partial decodes. First nonempty text arrives a median
1.87 s after RMS-detected speech onset (worst 4.96 s);
release-to-final is 0.86 s median (worst 1.40 s).
It starts at 0.5 s and schedules another snapshot 0.3 s after each prior decode
returns, with one worker. It does not implement incremental encoder reuse,
production preview cancellation or the Rust confidence retry. This is a small
prototype sanity check, not the shipping app’s live-preview benchmark.

First Core ML specialization took minutes in these experiments. One cold Rust
request hit the production 120-second timeout; pre-specializing via the helper
before starting the benchmark avoided it. Warm loads were roughly two seconds.
The initial cold runs overlapped compiler activity, so their load times are
not ranked against each other. A shipping backend would need explicit model
preparation, progress/error handling and storage management.

The final helper source builds successfully, including argument/error guards.
The public 12-sentence synthetic corpus completes all 13 stages of the committed
runner with the final binary. A second unchanged invocation skips all 13
completed results in the same generation. Model-free tests also cover forced
interruption with changed and identical configurations, replacing audio or
tokenizer contents at the same path, optional-stage removal, and commented
main/latency manifests. Shell syntax, whitespace and native-source checks pass.
No app installation or production backend change is part of this experiment.

## Reproduce

Build the native tools and the two Swift helpers, convert the model using the
[pinned recipe](../tools/ane-whisper/CONVERSION.md), then run
[`run_ane_foundation.sh`](run_ane_foundation.sh) with your manifest/audio root,
local tokenizer and the three compiled models. `LATENCY_MANIFEST` enables live
pipeline measurements. Result files contain text and stay under ignored
`benchmark/eval_results/`.

The runner fingerprints selected main/latency audio contents, tokenizer files,
compiled Core ML models, tool binaries, instructions and Apple model status.
Each forced run gets a separate experiment generation; resume only reuses
completed results from that generation. Cached MLX/Gemma weights still require
a fresh `OUT` or `FORCE=1` after they change. Model-free regression:
`bash scripts/test_ane_benchmark_resume.sh`.

These findings apply to this M4 Pro, OS/model versions and limited corpora.
M1, 8 GB Macs and iPhone performance were not tested. The next shipping decision
requires broader speakers and those target machines.
