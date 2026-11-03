# Accuracy on other voices

Every accuracy figure OLIV publishes comes from one speaker, the developer, on
one Mac. This page covers the tools that check whether other voices, accents,
microphones and rooms get the same results:

1. a **recording kit** of 30 sentences from the existing test buckets, with a
   consent note and Mac recording instructions;
2. **per-speaker scoring**: one command runs the full pipeline on every
   speaker's recordings and reports them next to the developer's recordings of
   the same sentences;
3. a **public multi-voice proxy** on FLEURS Thai, run before friends record.

All of them run through `oliv-dev speakers`, the same sidecar, cleanup model and
metric as the [main benchmark](README.md). Recordings, reference text and
transcripts stay in gitignored files; `report.md` and `summary.json` hold
aggregate numbers only.

## Recording kit

```sh
bash scripts/build_dev.sh
build/native-tools/oliv-dev speakers kit       # writes benchmark/data/speakers/
```

The kit draws from the private everyday (`manifest_all.jsonl`) and held-out
(`manifest_holdout.jsonl`) sets, so it contains private reference text. It is
written to `benchmark/data/speakers/`, which git ignores, and the command
refuses any directory inside a checkout that git would commit. The sentence
choice is deterministic (sha256 of seed and clip id), so the same seed and
corpus always give the same kit, and an existing kit is never replaced by a
different one without `--force`, because recordings are named after its ids.

| Group | Corpus buckets | Sentences |
|---|---|---:|
| Everyday Thai and English | `th` 3, `xg` 2, `lf` 1, `en` 2 | 8 |
| Thai–English tech talk | `mx` 3, `hx` 4, `tc` 2, `vb` 3 | 12 |
| Names and places | `pn` 2, `nu` 2 | 4 |
| Numbers and dates | `nm` 3 | 3 |
| Spoken formatting and fillers | `fm` 2, `fl` 1 | 3 |

Only sentences the developer recorded are used, so every kit sentence has a
baseline. Formatting and filler sentences come with the words to say (`say`),
including the spoken commands; a multi-line reference without them cannot be
read aloud unambiguously and is skipped. The D2 set is left out because its
`nu` bucket holds numbers rather than names.

`kit` writes three files:

- `kit.jsonl`: the 30 sentences with their reference text (private);
- `script.md`: what to send the speaker, in Thai and English: why we ask, the
  consent note, how to record on a Mac and the numbered sentences to say;
- `consent.example.json`: the consent record to fill in per speaker.

### Consent

Before recording, the speaker reads the consent note in `script.md`:
recordings are used only to measure OLIV's accuracy, stay on the maintainer's
computer, are never uploaded or published; only aggregate numbers are
published, under a pseudonym; they can withdraw at any time and their
recordings are deleted. When they agree, copy `consent.example.json` into their
directory as `consent.json` and set `"agreed": true`, the date they agreed, the
microphone and the kind of room. `score` skips any directory without such a
record. Directory names are the pseudonyms shown in reports (`s1`, `s2`, …;
lowercase letters, digits, `-` and `_`); the `mic` and `room` fields are shown
next to them, so keep those generic ("MacBook Air built-in", "quiet bedroom").

### Recording on a Mac

The speaker uses QuickTime Player (File > New Audio Recording), picks the
microphone next to the record button, records one sentence per file and saves
it under the sentence's id, for example `th03.m4a`. Any format `ffmpeg` reads
works (`.m4a`, `.wav`, `.aiff`, …); nothing needs converting. A quiet room,
the same microphone throughout, natural speech (not a news-reader voice) and
every word including fillers and spoken commands. It takes about 15–20 minutes.

```
benchmark/data/speakers/
  kit.jsonl  script.md  consent.example.json
  s1/consent.json  s1/th03.m4a  s1/th02.m4a  …
  s2/…
```

## Scoring speakers

```sh
HF_HUB_OFFLINE=1 build/native-tools/oliv-dev speakers score \
  --model-dir /path/to/LaBSE/snapshot
```

One command: every consented speaker with recordings, plus the developer's
original recordings of the same 30 sentences (`benchmark/data/clips/`), go
through the full pipeline (`oliv-dev eval` settings: Typhoon Turbo, Gemma E2B
cleanup, fillers removed for `fl`, spoken formatting for `fm`, vocabulary for
`vb`), then LaBSE scoring of both the final text and the speech model's own
transcript. Clips run interleaved by sentence, after one discarded warm-up
clip, so machine load affects every voice alike. `--only s1,s2` restricts the
speakers; `speakers report --results …/results.json` rebuilds the report
without models.

Output in `benchmark/eval_results/speakers/`:

- `results.json`: per clip, with transcripts (private, ignored);
- `summary.json` and `report.md`: per speaker and per group, aggregates only.

The report has, per speaker, meaning match after cleanup and from the speech
model alone, WER, CER and median latency; a paired comparison against the
developer on shared sentences (difference in percentage points with a 95%
bootstrap interval over sentences, sentences lost and gained, CER and WER
differences), pooled over all people when there are two or more; and meaning
match and CER per group. With 30 sentences a single clip is 3.3 points, so read
the interval, not the point estimate, and treat groups as direction only.

The sidecar gives the cleanup model 20 seconds. On an overloaded machine it
can time out, and the clip would keep the speech model's text: a lower meaning
match that has nothing to do with the voice. So a clip whose cleanup timed out
is replayed through cleanup on the same transcript (the sidecar's `stt_text`
replay; generation is greedy, so the text is what a quiet machine produces), up
to three attempts. The report counts replayed clips and any that still failed,
and the command warns about the latter. Latency keeps the first attempt, so it
is only meaningful on a quiet machine.

### Synthetic voice check

```sh
build/native-tools/oliv-dev speakers synth --voice Kanya
```

reads the kit with macOS's Thai text-to-speech voice into `tts-kanya/` and marks
it synthetic. It exercises the whole path before anyone records, and gives a
same-content comparison with a voice that is not the developer's. It is not an
estimate for people: a synthetic voice has no accent variation, reads English
words with Thai phonology and never hesitates. Reports label it and leave it
out of the pooled row.

## FLEURS Thai proxy

[FLEURS](https://huggingface.co/datasets/google/fleurs) (CC-BY-4.0) has each
sentence read by up to three different native speakers, with speakers kept apart
between train, dev and test. That makes it a fair way to see how much the
result depends on the voice: the words stay the same and only the reader (and
their microphone and room) changes. FLEURS does not publish speaker IDs, so the
report compares readers of the same sentence rather than named speakers.
GigaSpeech2 and the Thai ContextASR Bench are non-commercial and not used here.

```sh
bash scripts/fetch_fleurs_th.sh               # ~0.6 GB, pinned revision, sha256-checked
HF_HUB_OFFLINE=1 build/native-tools/oliv-dev speakers fleurs \
  --model-dir /path/to/LaBSE/snapshot --sentences 80
```

`--sentences N` samples N test sentences that have two or more readers (sha256
order with `--seed`) and runs every recording of each through the same full
pipeline; `0` runs all 344 such sentences (1,016 recordings). References are
the FLEURS raw transcriptions. A few spell sara am as nikhahit plus sara aa (3
of 1,021 in the test split); those, and any doubled sara e, are rewritten as
the single letters a Thai keyboard produces so they don't count as errors.

`--manifest-out FILE` only writes the sampled recordings as an `eval` manifest
(absolute audio paths, so pass `--audio-root /`) and runs nothing; no LaBSE
snapshot is needed. Engines outside the sidecar use it to score the same clips.

The report gives the overall meaning match, WER and CER (full pipeline and
speech model only) and, for sentences with two or more readers: how often every
reader gets the meaning, how often the readers disagree (the voice decides),
the CER of each sentence's best and worst reading, and the share of CER variance
that lies between readers of the same sentence rather than between sentences.

What it does not tell you: FLEURS is read Wikipedia-style Thai with long
sentences and little English, unlike OLIV's dictation corpus, so its absolute
numbers are not comparable with the 97.9% headline; FLEURS readers were
recorded once each in their own rooms; every Thai test recording is labelled
female; and Whisper-family models may have seen FLEURS training data (the test
speakers are disjoint from it).

## Results (3 November 2026)

Apple M4 Pro, macOS 27.2, Typhoon Whisper Turbo
(`chayapats/typhoon-whisper-turbo-mlx@1631224`) with Gemma 4 E2B cleanup
(`mlx-community/gemma-4-e2b-it-4bit@2387675`), text pipeline from `main` (unchanged
since 0.2.2 except the personal Dictionary, which these runs do not use). The Mac
was shared with other heavy jobs, so latencies are higher than on a quiet machine
(the 28 October benchmark measured a 1.0 s median). Accuracy is not affected: no
cleanup timed out in these runs.

### Many voices: FLEURS Thai

80 test sentences (seed 2026), 237 recordings: 77 sentences with three readers,
3 with two.

| Set | Clips | Meaning match | WER | CER |
|---|---:|---:|---:|---:|
| FLEURS Thai, many readers, full pipeline | 237 | **95.4%** | 0.207 | 0.113 |
| FLEURS Thai, many readers, speech model only | 237 | 96.6% | 0.216 | 0.100 |
| Developer, Thai-only dictation (`th`, `xg`, `lf`), full pipeline | 51 | 100.0% | 0.053 | 0.029 |
| Developer, all 264 clips, full pipeline | 264 | 97.3% | 0.145 | 0.092 |

The developer rows are from the 28 October 0.2.2 run on the same models.

| Same sentence, different readers | Full pipeline | Speech model only |
|---|---:|---:|
| Every reader gets the meaning | 90.0% | 92.5% |
| Readers disagree (the voice decides) | 7.5% | 6.2% |
| No reader gets the meaning | 2.5% | 1.2% |
| CER of the best / average / worst reading | 0.069 / 0.113 / 0.173 | 0.060 / 0.100 / 0.157 |
| Share of CER variance between readers of a sentence | 43% | 45% |

What this says:

- **Meaning holds across voices.** 95% of the recordings keep their meaning
  through the full pipeline, and for 90% of sentences every reader's recording
  does. That is close to the developer's 97% on dictation, on content that is
  harder for OLIV: long read sentences full of transliterated foreign names.
- **Exact wording depends on the voice.** On the same sentence the worst
  reading has 2.5 times the CER of the best (0.173 against 0.069), and 43% of
  the variation in CER lies between readers of the same sentence rather than
  between sentences. For 6 of 80 sentences the voice decides whether the
  meaning survives.
- **The CER gap to the developer is not a voice gap yet.** FLEURS CER (0.113)
  is about four times the developer's on Thai-only dictation (0.029), but the
  content differs too much to attribute that to the voice. Only the
  same-sentence rows above isolate the voice; recordings of the kit by other
  people will give the like-for-like number.
- **Cleanup does not help on read Thai.** It lowered meaning match from 96.6%
  to 95.4% (4 recordings lost, 1 gained) and raised CER from 0.100 to 0.113.
  Two losses are rewrites of misheard transliterated names (a country name
  became a car brand; a surname gained "รีวิว"), one is a Hangul syllable the
  cleanup model wrote into Thai text and the guardrail let through, and one is
  a borderline score (0.82 to 0.80) after spacing changes. This matches the
  [ContextASR](contextasr.md) finding on ordinary Thai and is a follow-up for
  the cleanup guardrail.

### One command per speaker: developer against a synthetic voice

The 30-sentence kit, developer recordings against macOS's Thai voice Kanya
reading the same sentences.

| Speaker | Clips | Meaning match | Speech model only | WER | CER |
|---|---:|---:|---:|---:|---:|
| developer (baseline) | 30 | 90.0% | 63.3% | 0.166 | 0.098 |
| tts-kanya (synthetic) | 30 | 73.3% | 70.0% | 0.276 | 0.191 |

Against the developer: −16.7 points (95% interval −30.0 to −6.7), 5 sentences
lost, none gained. Four of the five are Thai–English tech talk (58% against
92%), where the Thai voice reads English terms with Thai phonology; names,
numbers and formatting held. The developer's result reproduces the 0.2.2
release run on these sentences exactly (90.0%, CER 0.098). The kit is harder
than the 264-clip average because it oversamples tech talk and formatting, so
compare speakers with each other on the kit, not with the headline 97%.

## Next

Recordings of the kit by three to five other people, on their own Macs, are the
remaining step; [issue #18](https://github.com/chayapats/oliv/issues/18) stays
open until their results are in this section.
