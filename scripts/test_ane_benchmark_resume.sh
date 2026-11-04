#!/usr/bin/env bash
# Exercise the public runner's restart/input-integrity contract without models.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/oliv-ane-resume.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/benchmark" "$fixture/build/ane-whisper-swift/release" \
  "$fixture/tools/apple-cleanup/.build/release" "$fixture/audio" "$fixture/tokenizer" "$fixture/runtime"
cp "$ROOT/benchmark/run_ane_foundation.sh" "$fixture/benchmark/"
cp "$ROOT/tools/apple-cleanup/preserve-language.txt" "$fixture/tools/apple-cleanup/"
printf '{"path":"relative clip.wav"}\n' > "$fixture/manifest.jsonl"
jq -nc --arg path "$fixture/audio/latency.wav" '{path:$path}' > "$fixture/latency.jsonl"
printf 'first audio' > "$fixture/audio/relative clip.wav"
printf 'latency audio' > "$fixture/audio/latency.wav"
printf '{}' > "$fixture/tokenizer/tokenizer.json"
printf '{}' > "$fixture/tokenizer/tokenizer_config.json"
for precision in fp16 int8 pal4; do
  for part in AudioEncoder TextDecoder MelSpectrogram; do
    mkdir -p "$fixture/$precision/$part.mlmodelc"
    printf 'model' > "$fixture/$precision/$part.mlmodelc/weights.bin"
  done
done
cat > "$fixture/helper" <<'SH'
#!/usr/bin/env bash
printf '{"ok":true,"supports_th_TH":false,"variant":"fixture","guardrails":"default"}\n'
SH
chmod +x "$fixture/helper"
for binary in build/ane-whisper-swift/release/oliv-ane-whisper \
  tools/apple-cleanup/.build/release/oliv-apple-cleanup runtime/oliv-sidecar runtime/oliv-inference; do
  cp "$fixture/helper" "$fixture/$binary"
done
cat > "$fixture/dev" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in --out) out="$2"; shift;; esac
  shift
done
printf '%s\n' "$FIXTURE_RUN" >> "$FIXTURE_CALLS"
if [ "${FIXTURE_FAIL_AT:-0}" = "$(wc -l < "$FIXTURE_CALLS" | tr -d ' ')" ]; then exit 9; fi
jq -nc --arg run "$FIXTURE_RUN" '{complete:true,fixture_run:$run,clips:[{id:"fixture"}]}' > "$out"
SH
chmod +x "$fixture/dev"
export MANIFEST="$fixture/manifest.jsonl" AUDIO_ROOT="$fixture/audio" TOKENIZER_DIR="$fixture/tokenizer"
export COREML_FP16="$fixture/fp16" COREML_INT8="$fixture/int8" COREML_PAL4="$fixture/pal4"
export NATIVE_RUNTIME="$fixture/runtime" DEV="$fixture/dev" OUT="$fixture/benchmark/eval_results/test"
export OLIV_BENCH_LOCKED=1 FIXTURE_CALLS="$fixture/calls" FIXTURE_RUN=A
export LATENCY_MANIFEST="$fixture/latency.jsonl"
unset FORCE LABSE_DIR FIXTURE_FAIL_AT
run() { bash "$fixture/benchmark/run_ane_foundation.sh" > "$fixture/log" 2>&1; }
reset_calls() { : > "$FIXTURE_CALLS"; }
current() { jq -r '.run_id' "$OUT/_configuration.json"; }
assert_calls() { [ "$(wc -l < "$FIXTURE_CALLS" | tr -d ' ')" = "$1" ]; }
assert_results() {
  local generation="$1" marker="$2" count="$3" result
  local results=("$OUT/runs/$generation/"[!_]*.json)
  [ "${#results[@]}" = "$count" ]
  for result in "${results[@]}"; do
    jq -e --arg generation "$generation" --arg marker "$marker" \
      '.benchmark_run == $generation and .fixture_run == $marker' "$result" >/dev/null
  done
}
reject_changed_inputs() {
  reset_calls
  if run; then echo 'Changed inputs were unexpectedly reused' >&2; exit 1; fi
  assert_calls 0
  rg -q 'Benchmark configuration changed' "$fixture/log"
}
reset_calls
run
initial="$(current)"
assert_calls 19
assert_results "$initial" A 19
reset_calls
run
assert_calls 0

# Same path and manifest, different recording bytes (relative and absolute).
printf 'changed' >> "$fixture/audio/relative clip.wav"
reject_changed_inputs
printf 'first audio' > "$fixture/audio/relative clip.wav"
printf 'changed' >> "$fixture/audio/latency.wav"
reject_changed_inputs
printf 'latency audio' > "$fixture/audio/latency.wav"
for filename in tokenizer.json tokenizer_config.json; do
  printf '{"changed":true}' > "$fixture/tokenizer/$filename"
  reject_changed_inputs
  printf '{}' > "$fixture/tokenizer/$filename"
done
printf '{}' > "$fixture/tokenizer/config.json"
reject_changed_inputs
rm "$fixture/tokenizer/config.json"

# Reproduce interruption after only the first result is replaced. Test both a
# changed configuration and an explicitly forced repeat of identical inputs.
for marker in B C; do
  if [ "$marker" = B ]; then printf 'changed' >> "$fixture/audio/relative clip.wav"; fi
  export FIXTURE_RUN="$marker" FORCE=1 FIXTURE_FAIL_AT=2
  reset_calls
  if run; then echo 'Injected interruption was ignored' >&2; exit 1; fi
  generation="$(current)"
  [ "$generation" != "$initial" ]
  assert_results "$initial" A 19
  unset FORCE FIXTURE_FAIL_AT
  reset_calls
  run
  assert_calls 18
  assert_results "$generation" "$marker" 19
done

# Omitting an optional stage must not expose its older outputs to directory scans.
unset LATENCY_MANIFEST
export FORCE=1 FIXTURE_RUN=D
reset_calls
run
assert_calls 13
assert_results "$(current)" D 13
assert_results "$generation" C 19
echo 'ANE benchmark resume/input-integrity checks passed'
