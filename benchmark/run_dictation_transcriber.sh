#!/usr/bin/env bash
# OLIV vs Apple's on-device DictationTranscriber (th_TH): same clips, same scorer.
# Re-runs every table in benchmark/dictation-transcriber.md.
#
#   bash scripts/build_dev.sh
#   swift build -c release --package-path tools/apple-dictation
#   tools/apple-dictation/.build/release/oliv-apple-dictation install
#   LABSE_DIR=/path/to/LaBSE/snapshot bash benchmark/run_dictation_transcriber.sh [STEP...]
#
# Steps (default: all, in this order): private fleurs contextasr synth stream semantic.
# Environment: OLIV_PRIVATE_DATA (manifests + clips, default benchmark/data),
# OUT (default benchmark/eval_results/dictation), CTX_LIMIT (ContextASR
# utterances, default 300), FLEURS_SENTENCES (default 80), OLIV_GPU_LOCK
# (every model run holds this lockf lock, default /tmp/oliv-gpu.lock).
# A run whose output already exists is skipped, so an interrupted run resumes;
# FORCE=1 redoes everything. Outputs quote transcripts and stay under the
# ignored benchmark/eval_results/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DATA="${OLIV_PRIVATE_DATA:-benchmark/data}"
OUT="${OUT:-benchmark/eval_results/dictation}"
LOCK="${OLIV_GPU_LOCK:-/tmp/oliv-gpu.lock}"
CTX_LIMIT="${CTX_LIMIT:-300}"
FLEURS_SENTENCES="${FLEURS_SENTENCES:-80}"
DEV=build/native-tools/oliv-dev
APPLE=tools/apple-dictation/.build/release/oliv-apple-dictation
export HF_HUB_OFFLINE=1
[ -x "$DEV" ] || { echo "Run scripts/build_dev.sh first" >&2; exit 1; }
[ -x "$APPLE" ] || { echo "swift build -c release --package-path tools/apple-dictation" >&2; exit 1; }
case "$OUT" in benchmark/eval_results/*) ;; *) echo "OUT must be under benchmark/eval_results/ (ignored)" >&2; exit 1;; esac

locked() { lockf "$LOCK" "$@"; }
# once FILE CMD...: run CMD unless FILE (its output) exists.
once() {
  local file="$1"; shift
  if [ -e "$file" ] && [ -z "${FORCE:-}" ]; then echo "skip (exists): $file"; return 0; fi
  "$@"
}

# Per-second samples while "$@" runs: GPU utilization (all clients) and the
# CPU time / resident memory of the speech processes. ANE use needs
# powermetrics (root) and is not sampled.
sampled() {
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  ( while true; do
      printf '# %s gpu=%s load=%s\n' "$(date +%s)" \
        "$(ioreg -r -d 1 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2)" \
        "$(sysctl -n vm.loadavg | awk '{print $2}')"
      ps -A -o pid=,rss=,time=,comm= | grep -E 'localspeechrecognition|oliv-apple-dictation|oliv-inference|oliv-sidecar' || true
      sleep 1
    done ) > "$file" &
  local sampler=$!
  disown "$sampler"
  local status=0
  "$@" || status=$?
  kill "$sampler" 2>/dev/null || true
  return "$status"
}

# Apple raw and Apple -> OLIV text pipeline for one manifest; $1 = result dir,
# $2 = manifest, $3 = audio root, rest = extra harness options; $NAME names the files.
apple_pair() {
  local dir="$1" manifest="$2" root="$3"; shift 3
  if [ ! -e "$dir/${NAME}.json" ] || [ -n "${FORCE:-}" ]; then
    sampled "$dir/${NAME}.resources.txt" locked "$APPLE" run --manifest "$manifest" --audio-root "$root" \
      --label "Apple DictationTranscriber ${NAME}" --out "$dir/${NAME}.json" "$@"
    "$DEV" score --input "$dir/${NAME}.json" --out "$dir/${NAME}.json"
  fi
  once "$dir/${NAME}_oliv.json" locked "$DEV" eval --manifest "$manifest" --audio-root "$root" \
    --replay "$dir/${NAME}.json" --label "Apple ${NAME} -> OLIV text pipeline" --out "$dir/${NAME}_oliv.json"
}

private() {
  for pair in main:manifest_all holdout:manifest_holdout d2:manifest_d2; do
    local set="${pair%%:*}" manifest="$DATA/${pair#*:}.jsonl" dir="$OUT/${pair%%:*}"
    mkdir -p "$dir"
    once "$dir/typhoon_stt.json" sampled "$dir/typhoon_stt.resources.txt" locked "$DEV" eval --manifest "$manifest" --audio-root "$DATA" \
      --no-cleanup --label "Typhoon STT only" --out "$dir/typhoon_stt.json"
    once "$dir/oliv_full.json" sampled "$dir/oliv_full.resources.txt" locked "$DEV" eval --manifest "$manifest" --audio-root "$DATA" \
      --label "OLIV full pipeline" --out "$dir/oliv_full.json"
    NAME=apple_raw apple_pair "$dir" "$manifest" "$DATA"
    NAME=apple_nopunct apple_pair "$dir" "$manifest" "$DATA" --no-punctuation
    # The user's list (vb clips' `vocab`), as OLIV gets it.
    NAME=apple_ctx_vocab apple_pair "$dir" "$manifest" "$DATA" --contextual vocab
    # Oracle: each clip's own keywords, an upper bound no user list reaches.
    NAME=apple_ctx_keywords apple_pair "$dir" "$manifest" "$DATA" --contextual keywords
    echo "private/$set done"
  done
}

fleurs() {
  local dir="$OUT/fleurs" manifest="$OUT/fleurs/manifest.jsonl"
  "$DEV" speakers fleurs --sentences "$FLEURS_SENTENCES" --manifest-out "$manifest"
  once "$dir/typhoon_stt.json" locked "$DEV" eval --manifest "$manifest" --audio-root / --no-cleanup \
    --label "Typhoon STT only" --out "$dir/typhoon_stt.json"
  once "$dir/oliv_full.json" locked "$DEV" eval --manifest "$manifest" --audio-root / \
    --label "OLIV full pipeline" --out "$dir/oliv_full.json"
  NAME=apple_raw apple_pair "$dir" "$manifest" /
}

contextasr() {
  local dir="$OUT/contextasr" lim="--limit $CTX_LIMIT"
  mkdir -p "$dir"
  for c in none bias@0 bias@50 dis@50; do
    "$DEV" contextasr manifest --condition "$c" $lim --out "$dir/manifest_$c.jsonl"
  done
  locked "$DEV" contextasr run --pipeline asr $lim --cache-dir "$dir/stt_cache" --out "$dir/typhoon_asr"
  locked "$DEV" contextasr run --pipeline full $lim --cache-dir "$dir/stt_cache" --out "$dir/oliv_full"
  # Apple without a list in every condition, and with the condition's list
  # as contextual strings.
  for c in none bias@0 bias@50 dis@50; do
    once "$dir/apple_raw_$c.json" locked "$APPLE" run --manifest "$dir/manifest_$c.jsonl" \
      --out "$dir/apple_raw_$c.json" --hyps-out "$dir/apple_raw_$c.hyps.jsonl"
    [ "$c" = none ] && continue
    once "$dir/apple_ctx_$c.json" locked "$APPLE" run --manifest "$dir/manifest_$c.jsonl" --contextual vocab \
      --out "$dir/apple_ctx_$c.json" --hyps-out "$dir/apple_ctx_$c.hyps.jsonl"
  done
  mkdir -p "$dir/apple_raw" "$dir/apple_ctx"
  cat "$dir"/apple_raw_{none,bias@0,bias@50,dis@50}.hyps.jsonl > "$dir/apple_raw/hyps.jsonl"
  cat "$dir"/apple_raw_none.hyps.jsonl "$dir"/apple_ctx_{bias@0,bias@50,dis@50}.hyps.jsonl > "$dir/apple_ctx/hyps.jsonl"
  "$DEV" contextasr score --hyps "$dir/apple_raw/hyps.jsonl" --out "$dir/apple_raw"
  "$DEV" contextasr score --hyps "$dir/apple_ctx/hyps.jsonl" --out "$dir/apple_ctx"
  # OLIV's text pipeline on Apple's no-list transcript (the list as OLIV vocabulary)...
  locked "$DEV" contextasr run --pipeline full $lim --stt-replay "$dir/apple_raw_none.hyps.jsonl" \
    --label "Apple -> OLIV full" --out "$dir/apple_oliv_full"
  # ...and on the transcript Apple biased with the same list. A replay needs a
  # transcript for every selected utterance: entity-free ones (no list, not in
  # these pairs) fall back to the no-list transcript.
  for c in bias@0 bias@50 dis@50; do
    cat "$dir/apple_ctx_$c.hyps.jsonl" "$dir/apple_raw_none.hyps.jsonl" > "$dir/apple_ctx_$c.replay.jsonl"
    locked "$DEV" contextasr run --pipeline full $lim --conditions "$c" \
      --stt-replay "$dir/apple_ctx_$c.replay.jsonl" --label "Apple+list -> OLIV full" \
      --out "$dir/apple_ctx_oliv_full_$c"
  done
}

synth() {
  # Public failure examples: our own sentences (tools/apple-dictation/synthetic.jsonl)
  # read by macOS's Thai voice. A synthetic voice is not a person; examples only.
  local dir="$OUT/synth" manifest="$ROOT/tools/apple-dictation/synthetic.jsonl"
  mkdir -p "$dir"
  grep -v '^#' "$manifest" | while read -r row; do
    local id text
    id="$(jq -r .id <<<"$row")"
    text="$(jq -r '.say // .reference' <<<"$row")"
    [ -f "$dir/$id.wav" ] || say -v Kanya --file-format=WAVE --data-format=LEI16@16000 -o "$dir/$id.wav" "$text"
  done
  once "$dir/typhoon_stt.json" locked "$DEV" eval --manifest "$manifest" --audio-root "$dir" --no-cleanup \
    --label "Typhoon STT only" --out "$dir/typhoon_stt.json"
  once "$dir/oliv_full.json" locked "$DEV" eval --manifest "$manifest" --audio-root "$dir" \
    --label "OLIV full pipeline" --out "$dir/oliv_full.json"
  NAME=apple_raw apple_pair "$dir" "$manifest" "$dir"
  NAME=apple_ctx_keywords apple_pair "$dir" "$manifest" "$dir" --contextual keywords
}

stream() {
  # Real-time feed with volatile results: preview and release-to-text latency.
  local dir="$OUT/main"
  mkdir -p "$dir"
  if [ -e "$dir/apple_stream.json" ] && [ -z "${FORCE:-}" ]; then echo "skip (exists): $dir/apple_stream.json"; return 0; fi
  uptime > "$dir/apple_stream.uptime.txt"
  sampled "$dir/apple_stream.resources.txt" locked "$APPLE" run --manifest "$DATA/manifest_all.jsonl" \
    --audio-root "$DATA" --stream --label "Apple DictationTranscriber (streamed)" --out "$dir/apple_stream.json"
  uptime >> "$dir/apple_stream.uptime.txt"
  "$DEV" score --input "$dir/apple_stream.json" --out "$dir/apple_stream.json"
}

semantic() {
  : "${LABSE_DIR:?Set LABSE_DIR to a LaBSE snapshot (config.json, tokenizer.json, model.safetensors)}"
  for set in main holdout d2 fleurs synth; do
    if [ -d "$OUT/$set" ]; then locked "$DEV" semantic --results "$OUT/$set" --model-dir "$LABSE_DIR"; fi
  done
}

steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(private fleurs contextasr synth stream semantic)
for step in "${steps[@]}"; do
  case "$step" in
    private|fleurs|contextasr|synth|stream|semantic) "$step" ;;
    *) echo "Unknown step $step (private fleurs contextasr synth stream semantic)" >&2; exit 2 ;;
  esac
done
