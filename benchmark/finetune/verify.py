#!/usr/bin/env python3
"""Does this audio contain the sentence we put on screen?

Not "did the model get it right" — the model is EXPECTED to mangle the English terms,
which is the whole reason for the finetune. This catches the recording session going
wrong: a line misread, a word skipped, the wrong row read twice. A label that disagrees
with its audio is the most damaging single input to a finetune, and it is invisible
without this check.

Needs pythainlp (benchmark/.venv), so record.py imports it lazily and only under
--verify. Thresholds are measured, not guessed — see THRESHOLD below.
"""
import re
import sys
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import phonetic as ph  # noqa: E402  (path must be set first)

_THAI_RUN = re.compile(r"([฀-๿]+)")

# Measured on the 191 (reference, typhoon-raw) pairs in eval_results/ship_main.json —
# real correct readings — against negatives built from the same set.
#
#   correct reads          min 0.593   p5 0.783   median 0.961
#   wrong-row negatives    max 0.567                            (a different, random row)
#   nearest-neighbour negs max 0.943   p95 0.713   median 0.581  (the most similar row)
#
# 0.70 costs 2.1% false flags and catches every realistic misread. Bias is deliberate:
# a false flag loses one take and export PRINTS it, so you look and re-record. A missed
# misread puts a label on audio that does not say it — the most damaging thing that can
# enter a finetune, and silent.
THRESHOLD = 0.70

# Longest run of the label's phonetic fold with nothing opposite it. A skipped word leaves
# one; a misheard word does not (it gets substituted, not deleted). See misread().
#
# Measured with autojunk off: gap 6 -> 2.6% false flags / 72% of skips caught; gap 4 ->
# 5.2% / 92%; gap 3 -> 7.3% / 96.5%; gap 2 -> 19.9% / 98.5%.
#
# Three, and the 7% of good takes it costs, is the deliberate trade. A false flag loses one
# take, and approve.py lets you listen to it and settle it in seconds. A skipped word that
# slips through teaches the model to produce a word that is not in the audio — silently,
# permanently, in the exact place we are trying to fix. There is no symmetry here.
MAX_GAP = 3

# WHAT THIS CANNOT DO, stated plainly so nobody trusts it further than it goes.
#
# 1. It cannot tell "you read the sentence" from "you read a DIFFERENT sentence that
#    sounds almost the same". Against nearest-neighbour negatives the distributions
#    overlap and NO threshold separates them.
#
#    The misread you are actually exposed to, though, is reading the row ABOVE or BELOW
#    the one you meant — and that is now safe by construction, not by luck. An earlier
#    version of this comment claimed the seed shuffle made neighbours unrelated; a
#    reviewer promptly found neighbours in the shipped script scoring 0.727 and 0.762,
#    which a 0.70 gate waves straight through. The shuffle gave no such guarantee, it just
#    happened to look fine on one build. So build_script.separate_neighbours() now ENFORCES
#    it: adjacent rows are pushed apart until none scores above THRESHOLD - 0.05, and
#    test_finetune.py fails if the shipped script ever violates that.
#
# 2. It catches ~96% of single SKIPPED words (see MAX_GAP). The rest are one- or two-
#    syllable words whose absence leaves a hole no bigger than typhoon's own noise.
#    Catching those needs forced alignment — a real project, not a threshold.
#
# 3. It cannot be tightened by checking that each target term survives into the
#    transcript. That was the obvious next move and it is dead: measured on the same
#    pairs, only 244/410 (60%) of annotated keywords are even phonetically recoverable
#    from typhoon's raw output, because typhoon does not merely transliterate a term, it
#    MISHEARS it ("branch main" -> "แบรนด์เมน", which folds to brandmen, not branchmain).
#    Gating on term presence would flag 40% of CORRECT readings. The terms being
#    unreliable is the entire reason this finetune exists; they cannot also be the ruler.


def pfold(s: str) -> str:
    """Fold Thai and Latin into ONE phonetic space.

    The obvious comparison — strip to Thai and diff — is broken, and quietly. typhoon
    renders English as Thai script ("migrate database" -> "ไมเกรตดาตาเบส"), so the
    hypothesis GAINS Thai mass that the label spells in Latin. The two sides are then
    unaligned and every English-heavy sentence looks like a misread. The first version
    of this check papered over that by refusing to judge any label with under 12 Thai
    characters, which abandoned 183 of 2,437 sentences as unjudgeable.

    Romanising both sides instead puts "meeting" and "มิตติ้ง" on the same footing, and
    every sentence becomes judgeable.
    """
    out = []
    for part in _THAI_RUN.split(s):
        if not part.strip():
            continue
        out.append(ph.thai_fold(part) if _THAI_RUN.fullmatch(part) else ph.fold(part))
    return "".join(out)


def misread(label: str, hyp: str) -> dict:
    """{sim, gap, flag, judged}. flag=True means the audio does not say this sentence.

    Two signals, because whole-sentence similarity is blind to the most common way a take
    goes wrong. Skip a single word while reading and the sentence still scores 0.88-0.93 —
    one word in twenty barely moves a ratio. It does, however, leave a HOLE: a run of the
    label's phonetic fold with nothing opposite it.

    That hole is what separates a skip from a mishearing. When typhoon gets a term wrong
    it substitutes something ("branch main" -> "แบรนด์เมน"), which SequenceMatcher reports
    as `replace` — text on both sides. A word you never said produces `delete` — text on
    one side only. Measured on the 191 real pairs: correct readings have a median longest
    pure-delete run of 0 characters and a 95th percentile of 3; readings with one word
    dropped have a median of 7. Gating at 6 catches 70% of skipped words for 1% more false
    flags, where the old rule caught none of them at all.
    """
    a, b = pfold(label), pfold(hyp)
    if not a:
        return {"sim": 0.0, "gap": 0, "flag": False, "judged": False}
    # autojunk=False: SequenceMatcher otherwise drops characters that appear in >1%
    # of a sequence longer than 200 — a source-code heuristic that quietly
    # undercounts matches in long Thai sentences.
    m = SequenceMatcher(None, a, b, autojunk=False)
    sim = m.ratio()
    gap = max([i2 - i1 for tag, i1, i2, _, _ in m.get_opcodes() if tag == "delete"] or [0])
    return {"sim": round(sim, 3), "gap": gap,
            "flag": sim < THRESHOLD or gap >= MAX_GAP, "judged": True}
