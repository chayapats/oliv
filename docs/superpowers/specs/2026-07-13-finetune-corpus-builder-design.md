# Personal finetune corpus builder — design

**Date:** 2026-07-13 (revised 2026-07-14 after four rounds of cross-model review)
**Status:** implemented in `benchmark/finetune/`
**Scope:** build a training corpus. The finetune run itself (GPU, LoRA, MLX convert) is a
separate spec.

## Problem

OLIV transcribes Thai-English code-switched speech. Two error classes look identical to a
user and are nothing alike underneath:

1. **Recoverable.** typhoon writes an English term in Thai script but leaves a trace of
   the sound. `dictionary.py`, `phonetic.py` and the Gemma cleanup restore it.
2. **Unrecoverable.** typhoon mishears the term outright. Nothing downstream can recover
   what is no longer there — and the cleanup makes it *worse*, rewriting the wreckage into
   confident, plausible, wrong English.

From `eval_results/ship_main.json`:

```
reference  ช่วย deploy ตัวนี้ขึ้น production ให้หน่อย แล้ว merge branch main ด้วยนะ
raw        ช่วยดีพลอยตัวนี้ขึ้นโปรดักชั่นให้หน่อยแล้วเมิร์ชแบรนด์เมนด้วยนะ
final      ช่วย deploy ตัวนี้ขึ้น production ให้หน่อยแล้ว merge brand name ด้วยนะ
```

`branch main` → `แบรนด์เมน` → **`brand name`**. Class 2. Only a finetune fixes it.

## The invariants, as finally stated

**I1. No label may come from the eval corpus.** Absolute. Enforced by one predicate that
every gate calls, hardened across seven review rounds against verbatim reuse, wrapping,
insertion, reordering, fullwidth, zero-width, and bidi-override encodings.

**I2. A label must say what was spoken into its audio.** Enforced at 96.5% for single
skipped words and 100% for wrong-sentence reads; see "What is not guaranteed" below.

**I3. Audio with no speech, or whose speech is not the label, must never enter the
training set.** This is a *correction*. The original wording was "bad audio must never
enter", and that harm model is wrong: audio recorded in a noisy room whose label is
correct is not poison, it is augmentation — it teaches the model to survive the room you
actually dictate in. Measured: speech mixed with structured interference down to -8 dB SNR
is still transcribed correctly by typhoon, so the label is right and the clip is useful.
What must never enter is a clip whose audio does not say the label — and that is exactly
what I2 enforces. A reviewer held the original C3 against the code for three rounds; the
code was right and the criterion was wrong.

## What is NOT guaranteed, measured rather than hoped

* **~3.5% of single skipped words go undetected.** Short ones — omit `p99` and the hole it
  leaves in the phonetic fold is one character, indistinguishable from typhoon's own noise.
  Closing this needs forced alignment (a CTC aligner scoring each label word against the
  audio), which is a real project. Accepted deliberately: the remaining exposure is a
  handful of clips in ~2,450, and the pilot will show if it matters.
* **A near-identical sentence read in place of the intended one** cannot be distinguished.
  What makes this survivable is enforced, not lucky: `separate_neighbours()` guarantees no
  two adjacent rows sound alike, so the realistic wrong-row misread is caught.

## Non-goals

* Distribution. One speaker. Overfitting is the objective.
* Isolated words. Whisper is seq2seq over continuous speech; a corpus of one-word
  utterances teaches it that utterances are one word long. Terms are learned inside
  sentences, in many contexts.

## Architecture

```
matching.py      the ONE term matcher + the ONE leak predicate
evalcorpus.py    the eval sentences, fail-closed on missing OR empty manifests
build_terms.py   4 sources                -> terms.jsonl, TERMS_REVIEW.md
(Claude workflow) terms                   -> raw sentences
build_script.py  raw sentences            -> script.jsonl
record.py        script.jsonl             -> dataset/clips/, takes.jsonl
verify.py        does this audio say this sentence?
export.py        takes                    -> train.jsonl, val.jsonl
```

### Term list — four sources, ranked by evidential weight

| source | weight | why |
|---|---|---|
| eval_results | **highest** | terms the shipped pipeline *provably* drops. Not a guess |
| `terms_manual.txt` | high | the user's own list |
| `dictionary.py` | high | already-curated TRANSLIT / CANONICAL_CASE |
| git log + docs | nomination only | prose. Must *look* like a term to survive |

Repo mining is distrusted on purpose: its first pass produced `below`, `instead`,
`SUFeedURL`, `W0-T6` — words the user *types* and never *says*.

### Quota is coverage, not sentence count

The first cut multiplied terms by quota and arrived at 44 hours of recording. Wrong: one
sentence carries several terms. Quota is *target occurrences*; the sentence count falls
out of `slots / density`. **281 terms → ~2,450 sentences ≈ 6 h.**

Counting must use **word boundaries**. A substring count credited `app` to `mapping`,
`wrapper` and `approve` — 95 occurrences claimed against 27 real, and 415 sentences
carrying term annotations that were not in them. `matching.py` is the single matcher every
site now shares, because the first version let each site invent its own and they disagreed.

### The leak guard

If an eval sentence reaches the training set, the holdout stops measuring anything: the
score climbs while the model does not improve, which is worse than having no score.

One predicate, `matching.is_eval_leak()`, called by build, by the recorder's edit endpoint,
and again by export. A guard that runs only at generation time protects an artifact, not a
training set. It asks four questions because no three of them were enough:

| check | catches | learned from |
|---|---|---|
| substring | verbatim reuse | — |
| `contiguous_ratio` | eval sentence wrapped inside a longer one | 2 real leaks shipped; Jaccard is symmetric and cannot see containment |
| `ordered_ratio` | eval sentence split up by inserted words | reviewer's midpoint insertion slipped **124 of 188** past contiguity alone |
| `token_containment` | eval sentence **reordered** | order-preserving checks are all blind to it; characters were the wrong unit, words are the right one |

Two further lessons are baked in. `norm()` strips invisible characters — a reviewer put
U+200B every three characters and walked 263 of 264 references through a guard that read
identically to a human. And the speed prefilter bounds on a **character multiset**, not
n-grams: order-preserving matching pairs single characters, so `x`.join(eval) has zero
shared 4-grams and `ordered_ratio` 1.0. The first prefilter carried a comment calling
itself a bound. It was not one.

Fails closed on a missing **or empty** manifest. Several are gitignored, so a fresh
checkout has none of them, and a guard armed against nothing reports success.

### Take identity is (audio, label)

The recorder's job is to make it impossible for a clip's label to be something other than
what was said into it. Identity carries **both halves of the claim**:

* WAVs are immutable — `clips/<id>__<audio_hash>.wav`. A crash between publishing audio
  and appending its metadata leaves an orphan, never a clip whose audio and label came
  from different takes.
* A verifier verdict is about one `(id, audio, label)` triple. Keyed by audio alone — which
  it was — **relabelling inherited the old label's clean verdict, and export shipped a
  sentence nobody had spoken.** That was caught by executing export, not by reading it.
* Editing an already-recorded sentence **retires the take on disk first**, then makes the
  edit durable. Every crash point in between fails to "needs re-recording". The
  relabel/re-record fork used to live only in browser memory: close the tab mid-question
  and a stale label survived on real audio.
* The browser posts the label hash it displayed; the server refuses a take whose sentence
  changed mid-recording.

### QC is not a VAD, and says so

`analyse()` rejects dead mics, clipping, silence and noise. It is a cheap heuristic and
cannot tell you a human was speaking — a reviewer built a speech-free tone that passes it.
Rather than an arms race of heuristics, the **chain** was verified: that adversary passes
QC, typhoon transcribes it as `"ครับ ครับ ครับ…"`, misread scores 0.0, and export drops it.
**Verification is the speech gate. QC is the cheap pre-filter.**

### Verification, and what it cannot do

`verify.misread()` folds Thai and Latin into one phonetic space (`phonetic.thai_fold`), so
"meeting" and "มิตติ้ง" land on the same footing. Two signals:

* **similarity < 0.70** — the wrong sentence entirely.
* **longest pure-delete run ≥ 6** — a word you skipped. A *misheard* word gets substituted
  and leaves no hole; a *skipped* one does. Correct readings have a median gap of 0.

Measured: 2.6% false flags, 100% of wrong-sentence misreads, 70% of single skipped words.

Three limits are written into the module rather than hidden:

1. It cannot separate "read this sentence" from "read a near-identical one". What makes
   that survivable is **enforced, not lucky**: `build_script.separate_neighbours()` pushes
   adjacent rows apart until none scores above `THRESHOLD - 0.05`. An earlier comment
   claimed the shuffle did this for free; a reviewer found neighbours at 0.727 and 0.762.
2. The other 30% of skipped words are short ones whose absence leaves too small a hole.
   Forced alignment is the real answer and is out of scope.
3. It cannot be tightened by requiring each term to survive into the transcript — only
   244/410 (60%) of keywords are phonetically recoverable from typhoon's raw output. The
   terms being unreliable *is the reason this finetune exists*; they cannot also be the
   ruler.

### Export is the last gate and trusts nothing

It re-hashes the WAV, re-hashes the label, re-runs the leak guard, and requires a judged,
unflagged verdict for that exact `(id, audio, label)`. Every earlier version believed a
field the recorder had written, and each was wrong in a way that shipped audio under a
sentence nobody spoke.

Val is held out **by sentence**: a re-recorded line on both sides of the split would turn
the val score into a memorisation score.

`--allow-unverified` and `--keep-flagged` exist — a tool with no escape hatch traps you —
but they refuse to run without `--i-know 'the labels may be wrong'`, they shout, and
`meta.json` records `verified: false` and which override was used.

## Pilot before scale

**Record ~500, finetune, score through `eval_models.py`, then decide.** 500 will not reveal
the ceiling; it reveals whether the plumbing is sound: does loss fall, does the **holdout
not regress**, do the targeted terms improve. The script is seed-shuffled so any prefix is
representative — the first 500 touch ~275 of 281 terms.

## Privacy

`benchmark/finetune/dataset/` is gitignored (voice + transcripts), consistent with the
repo's existing posture. Verified with `git check-ignore` before any audio existed.

## Postscript: what four review rounds actually found

Not one of the twenty-plus findings was a typo or a style nit. Every one was a place where
the code did something *plausible* that was wrong in a way no test would have noticed —
a symmetric metric used for an asymmetric question, an identity missing half of what it
identified, a comment asserting a bound the code did not have. The pipeline shipped with no
tests at all; `test_finetune.py` now holds 59 assertions and every one of them is a bug
that was real.
