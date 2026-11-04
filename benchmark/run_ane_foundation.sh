#!/usr/bin/env bash
# Developer benchmark; no app installation or backend changes.
# Required: MANIFEST, AUDIO_ROOT, TOKENIZER_DIR, COREML_FP16, COREML_INT8,
# COREML_PAL4. See tools/ane-whisper and tools/apple-cleanup for conversion
# prerequisites and memory accounting. Model files and results stay local.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
for name in MANIFEST AUDIO_ROOT TOKENIZER_DIR COREML_FP16 COREML_INT8 COREML_PAL4; do
  [ -n "${!name:-}" ] || { echo "Set $name" >&2; exit 2; }
done
if [ "${OLIV_BENCH_LOCKED:-}" != 1 ]; then
  exec lockf "${OLIV_GPU_LOCK:-/tmp/oliv-gpu.lock}" env OLIV_BENCH_LOCKED=1 bash "$ROOT/benchmark/run_ane_foundation.sh" "$@"
fi
absolute_dir() { (cd "$1" && pwd); }
AUDIO_ROOT="$(absolute_dir "$AUDIO_ROOT")"
TOKENIZER_DIR="$(absolute_dir "$TOKENIZER_DIR")"
MANIFEST="$(absolute_dir "$(dirname "$MANIFEST")")/$(basename "$MANIFEST")"
COREML_FP16="$(absolute_dir "$COREML_FP16")"
COREML_INT8="$(absolute_dir "$COREML_INT8")"
COREML_PAL4="$(absolute_dir "$COREML_PAL4")"
NATIVE_RUNTIME="$(absolute_dir "${NATIVE_RUNTIME:-build/native-runtime}")"
DEV="${DEV:-$ROOT/build/native-tools/oliv-dev}"
WHISPER="$ROOT/build/ane-whisper-swift/release/oliv-ane-whisper"
APPLE="$ROOT/tools/apple-cleanup/.build/release/oliv-apple-cleanup"
OUT="${OUT:-benchmark/eval_results/ane-foundation-local}"
mkdir -p "$OUT"
OUT="$(absolute_dir "$OUT")"
case "$OUT" in "$ROOT"/benchmark/eval_results/*) ;; *) echo 'OUT must be under benchmark/eval_results/' >&2; exit 2;; esac
for binary in "$DEV" "$WHISPER" "$APPLE" "$NATIVE_RUNTIME/oliv-sidecar" "$NATIVE_RUNTIME/oliv-inference"; do
  [ -x "$binary" ] || { echo "Missing executable: $binary" >&2; exit 2; }
done
[ -r "$MANIFEST" ] || { echo 'MANIFEST is not readable' >&2; exit 2; }
for filename in tokenizer.json tokenizer_config.json; do
  [ -r "$TOKENIZER_DIR/$filename" ] || { echo "Missing local $filename" >&2; exit 2; }
done
export HF_HUB_OFFLINE=1

"$APPLE" status > "$OUT/_apple_status.json"
model_hash() {
  local part
  for part in AudioEncoder TextDecoder MelSpectrogram; do
    [ -d "$1/$part.mlmodelc" ] || { echo "Missing compiled $part in $1" >&2; return 2; }
  done
  find -L "$1" -type f -path '*.mlmodelc/*' -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}
fp16_hash="$(model_hash "$COREML_FP16")"
int8_hash="$(model_hash "$COREML_INT8")"
pal4_hash="$(model_hash "$COREML_PAL4")"
audio_hash() {
  # Match eval's absolute-path / audio-root-relative path resolution. Hash only
  # recordings selected by this manifest, including a separate latency subset.
  # Like oliv-dev eval: ignore blank/whitespace-only lines and comments after
  # trimming, then parse one JSON object per line. A # inside JSON stays data.
  jq -Rj 'select(test("^\\s*(#|$)") | not) | fromjson |
    if (.path | type) == "string" and (.path | length) > 0
    then .path + "\u0000" else error("Manifest row requires a nonempty path") end' "$1" |
    while IFS= read -r -d '' path; do
      case "$path" in /*) ;; *) path="$AUDIO_ROOT/$path";; esac
      shasum -a 256 "$path" || return 2
    done | shasum -a 256 | awk '{print $1}'
}
audio_hash_value="$(audio_hash "$MANIFEST")"
# These are the local files read by the pinned tokenizer loader. Optional file
# additions/removals must invalidate reuse too; large model weights aren't read.
tokenizer_hash="$(
  for filename in tokenizer.json tokenizer_config.json config.json chat_template.jinja chat_template.json; do
    if [ -f "$TOKENIZER_DIR/$filename" ]; then shasum -a 256 "$TOKENIZER_DIR/$filename"; fi
  done | shasum -a 256 | awk '{print $1}'
)"
latency_hash=""
latency_audio_hash=""
if [ -n "${LATENCY_MANIFEST:-}" ]; then
  [ -r "$LATENCY_MANIFEST" ] || { echo 'LATENCY_MANIFEST is not readable' >&2; exit 2; }
  latency_hash="$(shasum -a 256 "$LATENCY_MANIFEST")"
  latency_audio_hash="$(audio_hash "$LATENCY_MANIFEST")"
fi
candidate="$(mktemp "$OUT/.configuration-XXXXXX")"
jq -Sn --arg manifest "$MANIFEST" --arg manifest_hash "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')" \
  --arg audio_root "$AUDIO_ROOT" --arg tokenizer "$TOKENIZER_DIR" \
  --arg audio_hash "$audio_hash_value" --arg tokenizer_hash "$tokenizer_hash" \
  --arg fp16 "$fp16_hash" --arg int8 "$int8_hash" --arg pal4 "$pal4_hash" \
  --arg helpers "$(shasum -a 256 "$DEV" "$WHISPER" "$APPLE" "$NATIVE_RUNTIME/oliv-sidecar" "$NATIVE_RUNTIME/oliv-inference")" \
  --arg script "$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')" \
  --arg latency_manifest "$latency_hash" --arg latency_audio_hash "$latency_audio_hash" \
  --arg instructions "$(shasum -a 256 "$ROOT/tools/apple-cleanup/preserve-language.txt" | awk '{print $1}')" \
  --argjson apple "$(cat "$OUT/_apple_status.json")" \
  '{manifest:$manifest,manifest_hash:$manifest_hash,audio_root:$audio_root,tokenizer:$tokenizer,
    audio_hash:$audio_hash,tokenizer_hash:$tokenizer_hash,script:$script,
    model_hashes:{fp16:$fp16,int8:$int8,pal4:$pal4},helpers:$helpers,instructions:$instructions,apple:$apple,
    latency_manifest:$latency_manifest,latency_audio_hash:$latency_audio_hash}' > "$candidate"
if [ -f "$OUT/_configuration.json" ] && ! cmp -s "$candidate" <(jq -S 'del(.run_id)' "$OUT/_configuration.json") && [ "${FORCE:-0}" != 1 ]; then
  rm -f "$candidate"
  echo 'Benchmark configuration changed. Use a new OUT or FORCE=1; old results were retained.' >&2
  exit 2
fi
run_id=""
if [ "${FORCE:-0}" != 1 ] && [ -f "$OUT/_configuration.json" ]; then
  run_id="$(jq -r '.run_id // empty' "$OUT/_configuration.json")"
fi
[ -n "$run_id" ] || run_id="$(uuidgen)"
jq --arg run_id "$run_id" '.run_id = $run_id' "$candidate" > "$OUT/_configuration.json.tmp"
mv "$OUT/_configuration.json.tmp" "$OUT/_configuration.json"
rm -f "$candidate"
# Isolate the whole result set as well: removing a latency stage on a forced
# run must not leave an older live result visible to the semantic directory scan.
run_out="$OUT/runs/$run_id"
mkdir -p "$run_out"
cp "$OUT/_configuration.json" "$OUT/_apple_status.json" "$run_out/"
OUT="$run_out"

# Each output carries its experiment generation. Starting FORCE creates a new
# generation before any replacement; an interrupted run can only resume files
# from that generation, even when some older results still exist in OUT.
once() {
  local dest="$1"; shift
  if [ -s "$dest" ] && jq -e --arg run_id "$run_id" \
      '.benchmark_run == $run_id and .complete != false and (.clips | length > 0)' "$dest" >/dev/null 2>&1; then
    echo "skip: $dest"; return
  fi
  local temporary tagged
  temporary="$(mktemp "$OUT/.unfinished-XXXXXX")"
  "$@" --out "$temporary"
  jq -e '.complete != false and (.clips | length > 0)' "$temporary" >/dev/null
  tagged="$(mktemp "$OUT/.completed-XXXXXX")"
  jq --arg run_id "$run_id" '.benchmark_run = $run_id' "$temporary" > "$tagged"
  mv "$tagged" "$dest"
  rm -f "$temporary"
}

tag_apple() {
  local dest="$1" temporary
  temporary="$(mktemp "$OUT/.metadata-XXXXXX")"
  jq '.cleanup_model = "Apple Foundation Models SystemLanguageModel.default (on-device)" |
      .apple_supports_th_TH = $status.supports_th_TH |
      .apple_model_variant = $status.variant | .apple_guardrails = $status.guardrails |
      .cleanup_backend = "apple-local"' --argjson status "$(cat "$OUT/_apple_status.json")" "$dest" > "$temporary"
  mv "$temporary" "$dest"
}

tag_coreml_replay() {
  local dest="$1" precision="$2" temporary
  temporary="$(mktemp "$OUT/.metadata-XXXXXX")"
  jq --arg backend "WhisperKit Core ML $precision CPU+ANE" '.stt.backend = $backend' "$dest" > "$temporary"
  mv "$temporary" "$dest"
}

# Runtime directories are isolated from the installed application.
RUNTIME="$ROOT/build/ane-benchmark-runtimes"
mkdir -p "$RUNTIME/coreml" "$RUNTIME/apple"
ln -sf "$NATIVE_RUNTIME/oliv-sidecar" "$RUNTIME/coreml/oliv-sidecar"
ln -sf "$NATIVE_RUNTIME/oliv-sidecar" "$RUNTIME/apple/oliv-sidecar"
ln -sf "$WHISPER" "$RUNTIME/coreml/oliv-inference"
ln -sf "$APPLE" "$RUNTIME/apple/oliv-inference"
once "$OUT/mlx_stt.json" "$DEV" eval --manifest "$MANIFEST" --audio-root "$AUDIO_ROOT" \
  --runtime-dir "$NATIVE_RUNTIME" --no-cleanup --label 'Typhoon MLX, STT only'
once "$OUT/mlx_gemma.json" "$DEV" eval --manifest "$MANIFEST" --audio-root "$AUDIO_ROOT" \
  --runtime-dir "$NATIVE_RUNTIME" --replay "$OUT/mlx_stt.json" --label 'Typhoon MLX -> Gemma (replay)'
for variant in unchanged strict; do
  if [ "$variant" = strict ]; then
    export OLIV_APPLE_CLEANUP_INSTRUCTIONS="$ROOT/tools/apple-cleanup/preserve-language.txt"
  else
    unset OLIV_APPLE_CLEANUP_INSTRUCTIONS
  fi
  once "$OUT/mlx_apple_$variant.json" "$DEV" eval --manifest "$MANIFEST" --audio-root "$AUDIO_ROOT" \
    --runtime-dir "$RUNTIME/apple" --replay "$OUT/mlx_stt.json" --label "Typhoon MLX -> Apple $variant (replay)"
  tag_apple "$OUT/mlx_apple_$variant.json"
done
export OLIV_APPLE_CLEANUP_INSTRUCTIONS="$ROOT/tools/apple-cleanup/preserve-language.txt"
for precision in fp16 int8 pal4; do
  case "$precision" in fp16) model="$COREML_FP16";; int8) model="$COREML_INT8";; pal4) model="$COREML_PAL4";; esac
  # Warm the Core ML helper before the sidecar's production 120 s timeout.
  printf '{"id":1,"cmd":"stt_load"}\n' | OLIV_COREML_MODEL_DIR="$model" \
    OLIV_COREML_TOKENIZER_DIR="$TOKENIZER_DIR" "$RUNTIME/coreml/oliv-inference" > "$OUT/_${precision}_prepare.json"
  jq -e '.ok == true' "$OUT/_${precision}_prepare.json" >/dev/null
  # Use the same confidence-based forced-English retry as the MLX baseline.
  once "$OUT/${precision}_stt.json" env OLIV_COREML_MODEL_DIR="$model" OLIV_COREML_TOKENIZER_DIR="$TOKENIZER_DIR" \
    "$DEV" eval --manifest "$MANIFEST" --audio-root "$AUDIO_ROOT" --runtime-dir "$RUNTIME/coreml" \
    --no-cleanup --label "Typhoon Core ML $precision ANE, production STT guards"
  once "$OUT/${precision}_gemma.json" "$DEV" eval --manifest "$MANIFEST" --audio-root "$AUDIO_ROOT" \
    --runtime-dir "$NATIVE_RUNTIME" --replay "$OUT/${precision}_stt.json" --label "$precision ANE -> Gemma (replay)"
  tag_coreml_replay "$OUT/${precision}_gemma.json" "$precision"
  once "$OUT/${precision}_apple.json" "$DEV" eval --manifest "$MANIFEST" --audio-root "$AUDIO_ROOT" \
    --runtime-dir "$RUNTIME/apple" --replay "$OUT/${precision}_stt.json" --label "$precision ANE -> Apple strict (replay)"
  tag_apple "$OUT/${precision}_apple.json"
  tag_coreml_replay "$OUT/${precision}_apple.json" "$precision"
  if [ -n "${LATENCY_MANIFEST:-}" ]; then
    for backend in gemma apple; do
      if [ "$backend" = gemma ]; then cleanup="$NATIVE_RUNTIME/oliv-inference"; else cleanup="$APPLE"; fi
      once "$OUT/${precision}_${backend}_live.json" env OLIV_COREML_MODEL_DIR="$model" \
        OLIV_COREML_TOKENIZER_DIR="$TOKENIZER_DIR" OLIV_COREML_CLEANUP_EXECUTABLE="$cleanup" \
        "$DEV" eval --manifest "$LATENCY_MANIFEST" --audio-root "$AUDIO_ROOT" --runtime-dir "$RUNTIME/coreml" \
        --label "$precision ANE + $backend live pipeline"
      if [ "$backend" = apple ]; then tag_apple "$OUT/${precision}_${backend}_live.json"; fi
    done
  fi
done
if [ -n "${LABSE_DIR:-}" ]; then
  "$DEV" semantic --results "$OUT" --model-dir "$LABSE_DIR" --tools-dir "$(dirname "$DEV")"
fi
echo "Completed: $OUT. Replay timings exclude STT; measure the live runtime separately."
