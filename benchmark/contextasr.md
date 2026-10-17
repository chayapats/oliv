# Thai ContextASR Bench in OLIV

[Thai ContextASR Bench](https://huggingface.co/datasets/wayu-ai/thai-contextasr-bench)
(wayu-ai, 2,062 utterances, 5.7 h; 33% real speech, 67% TTS with cloned
voices) measures whether a Thai ASR system *uses* a list of names and terms:
it should transcribe listed entities that are spoken (**recognition**), in the
spelling the list shows (**form-following**), and never insert listed entities that
were not spoken (**restraint**). In OLIV the list is the user's Custom
Vocabulary, so the benchmark exercises the vocabulary corrector, the cleanup LLM
and its guardrail on realistic, long vocabularies.

`oliv-dev contextasr` runs the benchmark through the shipped sidecar, the same
Rust text pipeline and MLX inference helper the app uses, and scores it with a
native port of the upstream scorer.

## Data and licence

Data and audio are **CC-BY-NC-4.0** (scorer code Apache-2.0). Nothing from the
dataset is committed: download it outside the checkout, and keep run directories
(which quote transcripts) under the ignored `benchmark/eval_results/`.
Scorer provenance and its Apache-2.0 licence are included in
[the adapter notices](../rust/crates/oliv-dev/src/contextasr/UPSTREAM.md).

```sh
bash scripts/fetch_contextasr.sh            # ~/.cache/oliv-bench/thai-contextasr-bench
# or: bash scripts/fetch_contextasr.sh /path/outside/repo; export OLIV_CONTEXTASR_DIR=...
```

The script pins upstream revision `84e3099` and verifies the frozen bias lists
by sha256 (as upstream requires); the CLI re-verifies the hash on every load.
About 0.9 GB of WAV files are fetched. Real-speech clips (`a-`, `c-`) are
mirrored by the dataset repository; see its card for upstream corpus terms.

## Running

```sh
bash scripts/build_dev.sh                    # oliv-dev + runtime
export HF_HUB_OFFLINE=1                      # models downloaded by the app
D=benchmark/eval_results/contextasr
build/native-tools/oliv-dev contextasr run --pipeline full --out $D/full
build/native-tools/oliv-dev contextasr run --pipeline vocab --out $D/vocab
build/native-tools/oliv-dev contextasr compare --baseline $D/base_full --candidate $D/full \
  --out $D/compare_full.md                   # add --shard 1/2 for the held-out half
```

| option | meaning |
|---|---|
| `--pipeline asr` | pure STT (`cleanup:false`), what Whisper alone produces |
| `--pipeline vocab` | cleanup without the LLM: dictionary, vocabulary correction, spacing, casing (`cleanup_llm:false`, as when the cleanup model is unavailable) |
| `--pipeline full` | cleanup with Gemma E2B, fillers and Thai formatting off, so text changes come from vocabulary handling and the LLM |
| `--pipeline app` | `full` plus the app defaults: filler removal and Thai number formatting |
| `--conditions` | default `none,bias@0,bias@50,dis@50` (the upstream standard eval); any of the ten frozen conditions |
| `--limit N --seed S` | deterministic subset: first N utterances in sha256(`S:utt_id`) order |
| `--shard K/N` (compare) | restrict a comparison to an utterance shard, e.g. a held-out half |

`none` sends no vocabulary. Other conditions send the frozen list for that
(utterance, condition) as `vocabulary`, in list order, and nothing else, so no
reference text or other utterance's list can leak. Runs are resumable: an
interrupted run continues with the same configuration and refuses a different one.

**STT cache.** Typhoon decodes without a vocabulary prompt, so one transcript per
audio file serves every condition and pipeline. The cache key is the engine,
model snapshot, inference-helper sha256, audio sha256 and, for engines that take
a vocabulary prompt, the vocabulary. Cached transcripts are replayed through the
sidecar's `stt_text` field, so the silence and duration gates and the whole text
pipeline still run; replayed rows report the original decode's STT time.
STT + cleanup is therefore an estimated uncached processing time for cached rows,
not their replay wall time; use fresh `--no-cache` runs to measure actual runtime.

## Metrics

`metrics.json` holds, per condition, exactly the upstream report (CER, B-CER, U-CER,
entity recall, listed-form compliance as `script_compliance`, distractor fire
rate, counts, bootstrap 95% CIs) plus OLIV additions:

- **WER**: OLIV newmm words after OLIV's `metrics::normalize` (Thai word
  boundaries are tokenizer-dependent; use CER as the primary error rate).
- **Listed-form accuracy**: listed gold entities whose exact listed spelling
  appears, over all listed gold (compliance only counts recalled entities).
- **Over-biasing**: distractor fire rate, ΔCER(`dis@50` − `none`), and CER on
  entity-free utterances.
- **Stage attribution**: every metric recomputed on the ASR transcript (`raw`),
  with gold entities kept/gained/lost/missed by cleanup, listed forms gained and
  lost, and distractor fires introduced or removed by cleanup.
- **Latency**: median, p95 and mean of STT, cleanup, LLM (when run) and
  STT + cleanup per pair, plus LLM-run counts and guardrail flags.

Other outputs: `hyps.jsonl` (upstream format, scorable by the upstream CLI),
`details.jsonl` (raw and final text, stage flags, timings), `scores.jsonl`
(per-pair counts used for paired comparisons), `entities.jsonl` (per-entity
outcomes), `metrics.csv` and `report.md` (aggregates only, no transcripts).
`run.json` records the git commit, binary hashes, model revisions, macOS
version, chip and warm-up times.

### Scoring parity

The scorer is a line-by-line port of upstream `scorer/` (stdlib alignment path).
`oliv-dev contextasr score --hyps <baselines/X/hyps.jsonl> --out DIR` reproduces
the upstream Python output exactly: across the Qwen3-ASR-1.7B (10 conditions)
and Typhoon-Whisper-large-v3 baselines, 21,902 scored pairs, every rate, every
sub/ins/del count and every bootstrap CI matched (the bootstrap reimplements
CPython's seeded Mersenne Twister). Known differences:

- If `kaldialign` is installed, upstream uses it for alignment; its tie-breaking
  can move individual errors between B-CER and U-CER (overall CER is unchanged).
  OLIV always uses the stdlib tie-breaking.
- `compare` CIs are paired utterance bootstraps of the delta, an OLIV addition.

Normalization is the pinned upstream one: NFC, zero-width removal, ำ/แ
composition, Thai digits to Arabic, canonical mark order, ๆ expansion, casefold,
whitespace collapse. Tone and vowel-length differences remain errors. Spaces never
count.

## How OLIV is evaluated against the references

References keep loanwords in Thai script unless the loanword is a gold entity
(e.g. ออนไลน์, รีวิว). OLIV deliberately restores English technical terms
(รีวิว → review), so its cleanup adds CER on non-entity spans that a
Thai-script reference counts as errors. These remain exact-transcription errors
in every reported metric; no semantic exemption is applied. Compare
`vocab`/`full` against `asr` with that in mind, and
prefer context deltas (`bias@N` − `none`, `dis@50` − `none`) on identical audio,
as the benchmark card recommends. Real-speech clips may be in Whisper's
pretraining data, so absolute numbers on `a-`/`c-` are not contamination-free.

## Results (2026-10-11)

All 2,062 utterances, standard conditions (7,864 pairs per configuration),
typhoon-turbo-mlx (`chayapats/typhoon-whisper-turbo-mlx@1631224`), Gemma 4 E2B
4-bit (`mlx-community/gemma-4-e2b-it-4bit@2387675`), prompt v2, Apple M4 Pro,
macOS 27.2. Baseline = OLIV 0.2.0 text pipeline; candidate = this change. Both
replay the same cached STT transcripts. Percentages; fire rates are per listed
distractor.

### Baseline (OLIV 0.2.0)

| config | condition | CER | B-CER | U-CER | WER | recall | listed (of recalled) | listed-form acc | fire |
|---|---|---|---|---|---|---|---|---|---|
| asr | none | 6.06 | 15.89 | 4.93 | 19.77 | 41.79 | — | — | — |
| asr | bias@0 | 5.53 | 17.26 | 3.87 | 19.68 | 41.79 | 60.45 | 25.26 | — |
| vocab | none | 6.27 | 15.92 | 5.16 | 19.99 | 41.75 | — | — | — |
| vocab | bias@0 | 5.70 | 17.13 | 4.11 | 19.41 | 44.39 | 64.07 | 28.44 | — |
| vocab | bias@50 | 6.28 | 18.84 | 4.86 | 19.59 | 44.17 | 63.89 | 28.22 | 0.049 |
| vocab | dis@50 | 6.33 | 17.59 | 5.04 | 20.04 | 41.50 | — | — | 0.048 |
| full | none | 6.73 | 20.82 | 5.51 | 20.61 | 42.37 | — | — | — |
| full | bias@0 | 6.06 | 22.05 | 4.41 | 20.28 | 45.98 | 53.77 | 24.72 | — |
| full | bias@50 | 6.68 | 23.84 | 5.23 | 20.15 | 45.76 | 53.79 | 24.61 | 0.051 |
| full | dis@50 | 6.79 | 22.61 | 5.43 | 20.67 | 42.08 | — | — | 0.049 |

For reference, the published no-context baselines on the same scorer are
Typhoon-Whisper-large-v3 CER 4.8 / B-CER 11.7 / recall 45.9 and
Pathumma-Whisper-large-v3 5.2 / 15.2 / 41.6; Qwen3-ASR-1.7B, which takes the
list as a prompt, reaches bias@0 recall 64.4 and listed 80.8.

### Failure analysis (baseline, bias@50 unless noted)

- **Thai-script vocabulary entries were ignored.** 75% of listed gold
  entities are Thai-script. The corrector folded terms to a-z only, so Thai
  entries never matched; 58% of Thai-listed entities were missed and only 29%
  appeared in the listed spelling even before cleanup. Typical misses are
  homophone spellings and silent letters (บางแคร์ for บางแค, ทิติพงศ์ for
  ฐิติพงส์, เมลเบิ้ล for เมลเบิร์น): ASR heard the name, the spelling differs.
- **The cleanup LLM rewrote listed Thai names.** Thai-listed entities in the
  listed spelling fell from 29% after ASR to 19% after the LLM (other spellings
  14% to 23%): it transliterates names and brands to English (ยูทูบ to YouTube)
  or re-spells them. bias@0 listed-form compliance: ASR 60.4, vocab stage 64.1,
  full pipeline 53.8. B-CER rose from 15.9 (ASR) to 20.8 (full) without a list.
- **Latin-listed names spoken as Thai words** (คลองเตย for "Khlong Toei",
  ประยุทธ์ for "Prayut") stayed Thai: the corrector only rewrote spans holding a
  non-dictionary token. The LLM fixed some (Latin listed form 15% after ASR,
  41% after the LLM).
- **Over-biasing came from the vocabulary corrector, not the LLM.** ASR alone
  produced 8 distractor fires on dis@50; the deterministic stage added 41,
  touching 2.4% of utterances. Most were ALL-CAPS list entries (stock tickers)
  treated as spelled acronyms and matched against ordinary words (เพื่อน to
  PROEN, กิน to KEEL, ศูนย์ to CEN, อันนี้ to NEO); others were mixed-script
  or non-ASCII entries whose fold kept a fragment (หุ้นกู้ THANA, Chișinău) and
  3-letter skeletons matching word fragments (Nan).
- **Ordinary Thai.** Without a list, cleanup raised CER from 6.06 to 6.73
  (415 utterances worse, 310 better). Most of it is OLIV's intended English
  restoration (รีวิว to review) scored against Thai-script references, but the
  LLM also makes genuine errors: translations (เอ็กซอติกเพชร to ExoticDiamond),
  wrong terms (ซอฟต์พาวเวอร์ to software, เวิร์คพอยต์ to workspace) and fused
  Latin strings. It also repairs misspelled transliterations and removes
  repeated ASR text, so reverting its Thai edits wholesale did not help (below).
- **Recognition itself** limits the rest: 36% of Thai-listed entities are still
  missed after the change (full pipeline), mostly where ASR produced a different-sounding word
  (เกลือไกล for เกริกไกร). Typhoon takes no vocabulary prompt, so only
  post-processing can use the list.

### Changes and results

1. Thai-script vocabulary: re-spell a Thai span with the same royin skeleton and
   nearly the same spelling key (homophone letters merged, silenced consonants
   dropped, consonant substitutions cost double; short keys must match exactly
   and never replace a single dictionary word).
2. Latin-listed names written as Thai words: replaced when the royin skeleton
   equals a unique listed name of at least five letters.
3. Fewer false snaps: acronyms never replace real Thai words unless those
   spell its letters; terms with Thai or non-ASCII letters and 3-letter
   skeletons are not folded.
4. The LLM may not rewrite a listed Thai-script term (edits touching it are
   reverted, flag `ok-termKept`); all other LLM behaviour is unchanged.

Full pipeline, candidate − baseline, paired bootstrap 95% CI:

| metric | none | bias@0 | bias@50 | dis@50 |
|---|---|---|---|---|
| CER | 6.73 → 6.73 (±0) | 6.06 → 5.38 (−0.68, −0.78…−0.59) | 6.68 → 6.09 (−0.59, −0.69…−0.47) | 6.79 → 6.75 (−0.04, −0.08…−0.00) |
| WER | 20.61 → 20.61 | 20.28 → 16.89 | 20.15 → 17.33 | 20.67 → 20.63 |
| B-CER | 20.82 → 20.82 | 22.05 → 14.32 | 23.84 → 15.81 | 22.61 → 22.58 |
| U-CER | 5.51 → 5.51 | 4.41 → 4.33 | 5.23 → 5.16 | 5.43 → 5.39 |
| Entity recall | 42.37 → 42.37 | 45.98 → 63.01 (+17.0, +15.5…+18.5) | 45.76 → 62.90 | 42.08 → 42.19 |
| Listed-form compliance | — | 53.77 → 74.63 | 53.79 → 74.47 | — |
| Listed-form accuracy | — | 24.72 → 47.02 | 24.61 → 46.84 | — |
| Distractor fires | — | — | 53 → 27 (0.051 → 0.026) | 51 → 31 (0.049 → 0.030) |
| ΔCER dis@50 − none | | | | +0.07 → +0.02 |
| LLM calls | 1,098 → 1,098 | 1,016 → 1,019 | 1,133 → 1,132 | 1,113 → 1,103 |

The LLM-off stage alone (`vocab`): bias@0 recall 44.4 → 60.9, compliance 64.1 →
74.6, B-CER 17.1 → 13.8; dis@50 fires 49 → 27; `none` unchanged.

**Generalisation.** Rules were tuned on the first ~370 utterances (mostly `a-`)
and the LLM variant on a 500-utterance subset. On the 1,295 utterances never
inspected (1,050 `b-`, 231 `c-`, 14 `a-`), full pipeline bias@50: recall 46.3 →
64.3, listed-form accuracy 23.8 → 47.2, B-CER 22.2 → 14.3, fires 0.05% → 0.02%,
`none` identical. The `--shard 1/2` half gives the same picture (bias@50 recall
+16.3, CI +14.0…+18.4).

**Rejected variants** (500-utterance subset, full pipeline, vs baseline): reverting
every Thai-only LLM edit left CER flat but raised WER by 0.5 pt without a list
(131 utterances better, 123 worse); allowing spelling-sized Thai edits and
reverting only deletions raised CER by 0.10–0.15 pt; a stricter Latin-garble
threshold (0.20) removed 4 fires but lost 8 recalled entities.

**Latency.** Without a list the text stage is unchanged. With a 50-term list
the deterministic stage costs +2.9 ms median and +5.9 ms p95 per utterance
(paired, CPU only), and the LLM runs on the same pairs (±1%). End-to-end medians
are about 1.3–1.5 s; run-to-run variation of the unchanged STT alone (0.72–1.03 s
median across an ABBA test) is far larger than the change, so no end-to-end
difference is attributable to it.

### Limitations and next steps

- Recognition is the ceiling: after the change 36% of Thai-listed and 42% of
  Latin-listed entities are still missed (bias@50, full pipeline). Gains beyond this need decoder biasing
  (Typhoon loops when prompted) or a context-aware ASR model.
- The listed-form path for Latin names requires an exact skeleton match;
  romanizations that differ from royin (Ketkaram for เกียรติการาม) are missed.
- The LLM still introduces errors without a list (translations, fused Latin);
  a phonetic plausibility check for its Thai-to-Latin rewrites is the next
  candidate, measured on `none` where it costs CER today.
- `app` (filler removal, Thai number formatting) and conditions beyond the
  standard four (`bias@500`, `flip@50`) were not run for this report.
- Real speech may be in Whisper's pretraining data; TTS speech is 67% of the set.
