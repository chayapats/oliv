# Typhoon through Core ML / WhisperKit

Developer benchmark only. The app continues to use its existing MLX runtime.
WhisperKit is pinned in `Package.swift` and `Package.resolved`.

```sh
swift build -c release --package-path tools/ane-whisper \
  --scratch-path build/ane-whisper-swift
build/ane-whisper-swift/release/oliv-ane-whisper \
  --model-dir /absolute/path/to/converted-model \
  --tokenizer-dir /absolute/path/to/local-tokenizer \
  --manifest /absolute/path/to/manifest.jsonl \
  --audio-root /absolute/path/to/audio \
  --compute ane --out benchmark/eval_results/ane-raw.json
```

The model folder must contain `AudioEncoder`, `TextDecoder` and
`MelSpectrogram` Core ML models. Supply the local tokenizer explicitly to avoid
WhisperKit's tokenizer-download fallback. Model download is disabled.

- `--compute ane` selects CPU + Neural Engine, `gpu` CPU + GPU, `cpu` CPU only.
  The mel front end uses CPU in all modes. Selecting ANE does not prove that
  every operation runs there; retain the Core ML compute plan and profile.
- `--limit N` selects the first N manifest rows. `--language CODE` overrides
  the default language detection. Decoding uses temperature fallback and
  timestamps, with one worker. It is a different decoder implementation from
  OLIV's MLX decoder; compare accuracy, not just model weights.
- `--prepare yes` loads/specializes the model and exits, recording load time.
- `--preview yes` feeds increasingly available audio at wall-clock speed,
  decoding a new snapshot 0.3 seconds after the previous result. This measures
  a candidate snapshot-preview implementation, not the shipping app. It records
  first text, every preview and release-to-final latency.

Results are checkpointed atomically and include `complete`. Run
`oliv-dev score` and the existing semantic scorer on completed results.
Outputs include reference and hypothesis text: keep them under the ignored
`benchmark/eval_results/` directory.

## Full pipeline measurements

With `OLIV_COREML_MODEL_DIR` set, the executable becomes the JSONL inference
helper instead of the manifest runner. Pair it with the production Rust
sidecar in a separate runtime directory and use `oliv-dev eval` normally.

- `OLIV_COREML_TOKENIZER_DIR`: local tokenizer directory.
- `OLIV_COREML_COMPUTE`: `gpu` for CPU + GPU; default CPU + ANE.
- `OLIV_COREML_CLEANUP_EXECUTABLE`: production MLX inference helper for Gemma,
  or `oliv-apple-cleanup` for Apple's local model.

The Core ML model and cleanup process stay loaded together. This allows actual
pipeline latency and memory measurement, retaining the production Rust text
pipeline. It supports the benchmark's PCM STT requests, not production live
preview cancellation or model downloads.

## Memory accounting

Capture `footprint -p PID -f bytes` during inference. On this Mac, Neural Engine
weights appear in auxiliary `neural` / `neural_peak` and in an owned neural
region marked `nofootprint`. They are absent from the headline physical
footprint and process RSS. Report these allocations alongside physical
footprint; otherwise an apparently tiny ANE process hides the model's RAM.
Count cleanup child processes too. The OS model used by Foundation Models may
live in a shared service and needs separate accounting.
