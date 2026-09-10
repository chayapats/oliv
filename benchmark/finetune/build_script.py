#!/usr/bin/env python3
"""Turn raw generated sentences into the recording script.

    python3 benchmark/finetune/build_script.py _generated.json   # -> script.jsonl

Four gates, in order. Each exists because skipping it corrupts the finetune in a way
that stays invisible until much later:

  1. TERM FIDELITY   the term must be present at a WORD BOUNDARY, spelled exactly as the
                     term list has it. That spelling is the label we train toward, and a
                     substring match hands `app` credit to `mapping` and `approve`.
  2. LEAK GUARD      no sentence may reproduce OR CONTAIN anything in the eval corpus.
                     Train on the holdout and it stops measuring anything: the score
                     rises while the model does not improve, which is worse than having
                     no score. Fails CLOSED — a missing manifest aborts.
  3. DEDUP           near-identical sentences teach the frame, not the term, and cost
                     recording hours you pay for in your own time.
  4. COVERAGE        report what is still short of quota, so a gap is a decision instead
                     of something discovered after the recording sessions.
"""
import json
import random
import re
import sys
from difflib import SequenceMatcher
from collections import Counter, defaultdict
from pathlib import Path

import evalcorpus
from matching import (canonicalise, find_terms, grams, has_term, hostile_chars,
                      is_eval_leak, jaccard)

FT = Path(__file__).resolve().parent
DATA = FT.parent / "data"
ROOT = FT.parent.parent
OUT = FT / "script.jsonl"

# The leak thresholds live in matching.is_eval_leak — every gate that can put a label into
# the training set calls that one predicate. Measured cost of the contiguity cut: 0.70
# drops 5 sentences, 0.60 drops 9, 0.50 drops 47 (at which point it eats sentences that
# merely share an ordinary Thai turn of phrase). Dropping a good sentence costs 1/2447 of
# a corpus we have a surplus of; one leak costs the entire benchmark. So buy the margin.
DUP_J = 0.80
SEED = 42


def separate_neighbours(rows: list[dict], rng: random.Random) -> float:
    """Force adjacent rows to be phonetically far apart. Returns the worst remaining pair.

    The single misread this corpus is actually exposed to is reading the row above or
    below the one you meant. verify.misread() catches that only when the two sentences
    sound different — and whether they do was, until now, an accident of the shuffle. On
    one build the worst adjacent pair scored 0.585 and every wrong-row read was caught; on
    another, a reviewer found neighbours at 0.727 and 0.762, comfortably clean-looking to
    a 0.70 gate. Same code, same seed, different sentences surviving the leak guard.

    So stop leaving it to chance: after shuffling, walk the list and swap any neighbour
    that sounds too close to its predecessor out to a random later slot. The property
    verify.py depends on becomes a thing this file guarantees, and test_finetune.py holds
    it to it.
    """
    from verify import THRESHOLD, pfold          # needs pythainlp -> benchmark/.venv
    folds = [pfold(r["text"]) for r in rows]
    limit = THRESHOLD - 0.05                     # keep clear of the gate, not level with it

    def sim(i: int, j: int) -> float:
        return SequenceMatcher(None, folds[i], folds[j]).ratio()

    for i in range(1, len(rows)):
        for _ in range(40):                      # bounded: give up rather than spin
            if sim(i - 1, i) <= limit:
                break
            j = rng.randrange(i + 1, len(rows)) if i + 1 < len(rows) else None
            if j is None:
                break
            rows[i], rows[j] = rows[j], rows[i]
            folds[i], folds[j] = folds[j], folds[i]

    return max((sim(i - 1, i) for i in range(1, len(rows))), default=0.0)


def main() -> None:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else FT / "_generated.json"
    raw = json.loads(src.read_text(encoding="utf-8"))
    sents = raw["sentences"] if isinstance(raw, dict) else raw

    terms = {r["term"]: r for r in
             (json.loads(l) for l in (FT / "terms.jsonl").read_text(encoding="utf-8").splitlines())
             if r["include"]}
    forbidden = evalcorpus.load()
    print(f"leak guard armed against {len(forbidden)} eval sentences "
          f"from {len(evalcorpus.MANIFESTS)} manifests")

    drop = Counter()
    leaked: list[tuple[str, str, str]] = []
    kept: list[dict] = []
    kept_grams: list[set] = []
    fixed = 0

    for s in sents:
        text = re.sub(r"\s+", " ", (s.get("text") or "").strip())
        if not text or len(text) < 8:
            drop["empty"] += 1
            continue

        # 0. no adversarial encodings. Not stripped — REFUSED. A bidi override can make
        #    reversed text render as an eval sentence, and no amount of deleting characters
        #    recovers what a human actually reads off the screen.
        if hostile_chars(text):
            drop["hostile characters"] += 1
            continue

        # 1. term fidelity
        text, n = canonicalise(text, list(terms))
        fixed += n
        present = find_terms(text, terms)
        if not present:
            drop["no-term"] += 1
            continue

        g = grams(text)

        # 2. leak guard
        hit = is_eval_leak(text, forbidden)
        if hit:
            drop["eval-leak"] += 1
            leaked.append((s.get("cluster", ""), text, hit))
            continue

        # 3. dedup
        if any(jaccard(g, k) > DUP_J for k in kept_grams):
            drop["duplicate"] += 1
            continue

        kept.append({"text": text, "terms": present, "bucket": s.get("bucket", "mx")})
        kept_grams.append(g)

    # Shuffle before numbering. The generator emits cluster by cluster, so in source
    # order the first 500 rows are all git and deploy talk — no Thai names, no numbers,
    # no rare vocabulary. Recording is incremental and stops partway on purpose (the
    # pilot), so ANY prefix must be a representative sample of the whole script.
    rng = random.Random(SEED)
    rng.shuffle(kept)
    sep = separate_neighbours(kept, rng)
    for i, r in enumerate(kept, 1):
        r["id"] = f"ft{i:06d}"

    with OUT.open("w", encoding="utf-8") as f:
        for r in kept:
            f.write(json.dumps({"id": r["id"], "text": r["text"], "terms": r["terms"],
                                "bucket": r["bucket"]}, ensure_ascii=False) + "\n")

    # 4. coverage — counted with the same matcher that admitted the sentences
    cov: dict[str, int] = defaultdict(int)
    for r in kept:
        for t in terms:
            if has_term(r["text"], t):
                cov[t] += 1
    short = sorted(((t, cov[t], terms[t]["quota"]) for t in terms
                    if cov[t] < terms[t]["quota"]), key=lambda x: x[1] - x[2])

    print(f"\nin  {len(sents)} generated")
    if fixed:
        print(f"    ~{fixed:4d}  term spellings canonicalised")
    for k, v in drop.most_common():
        print(f"    -{v:4d}  {k}")
    print(f"out {len(kept)} sentences -> {OUT.relative_to(ROOT)}")

    if leaked:
        print(f"\n  ⚠ {len(leaked)} sentences DROPPED for carrying an eval sentence:")
        for cluster, text, hit in leaked[:6]:
            print(f"    train: {text[:70]}")
            print(f"    eval : {hit[:70]}")

    n_terms = sum(len(r["terms"]) for r in kept)
    print(f"\n  density   {n_terms / max(1, len(kept)):.2f} terms/sentence")
    print(f"  recording ~{len(kept) * 9 / 3600:.1f} h at 9 s/clip")
    print(f"  buckets   {dict(Counter(r['bucket'] for r in kept).most_common())}")
    print(f"\n  worst adjacent-row similarity {sep:.3f} "
          f"(a wrong-row misread must stay catchable — see verify.THRESHOLD)")
    print(f"  coverage  {len(terms) - len(short)}/{len(terms)} terms at quota")
    for t, c, q in short[:20]:
        print(f"    {t:24s} {c:3d}/{q}")
    if len(short) > 20:
        print(f"    … +{len(short) - 20} more")


if __name__ == "__main__":
    main()
