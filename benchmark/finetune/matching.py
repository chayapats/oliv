#!/usr/bin/env python3
"""The one place that decides whether a term is present in a sentence, and whether two
sentences are too close.

Every caller must use these. The first version of this pipeline let each site invent its
own rule — `t in text` for admission, `t.lower() in text.lower()` for coverage, a regex
for canonicalisation — and they disagreed. `mapping`, `wrapper` and `approve` all handed
credit to the term `app`, which was reported as covered 95 times when a word-boundary
count says 27, and 415 sentences carried term annotations that were not in them.

Stdlib only: record.py must run without a venv.
"""
import re
import unicodedata
from collections import Counter
from difflib import SequenceMatcher

# Thai has no inter-word spacing, so there is no boundary to anchor to; Latin does, and
# that is where the false credit came from. Anchor on Latin letters only, which also
# leaves `p99`, `Route 53`, `A/B test` and `requirements.txt` matchable.
_LATIN = re.compile(r"[A-Za-z]")


def term_re(term: str) -> re.Pattern:
    body = re.escape(term).replace(r"\ ", r"\s+")
    if not _LATIN.search(term):
        return re.compile(body)                       # Thai: plain containment
    return re.compile(r"(?<![A-Za-z])" + body + r"(?![A-Za-z])", re.I)


def has_term(text: str, term: str) -> bool:
    return bool(term_re(term).search(text))


def find_terms(text: str, terms) -> list[str]:
    """Terms genuinely present, at a word boundary, in the order given."""
    return [t for t in terms if has_term(text, t)]


def canonicalise(text: str, terms) -> tuple[str, int]:
    """Rewrite every term to its canonical spelling — that spelling is the training
    label, and the same term wearing two spellings teaches the model the disagreement.

    Longest terms match first and mask their span, so `route` can never eat `Route 53`.
    """
    taken = [False] * len(text)
    spans: list[tuple[int, int, str]] = []
    for t in sorted(terms, key=len, reverse=True):
        if not _LATIN.search(t):
            continue                                  # Thai has no case
        for m in term_re(t).finditer(text):
            if any(taken[m.start():m.end()]):
                continue
            for i in range(m.start(), m.end()):
                taken[i] = True
            if m.group(0) != t:
                spans.append((m.start(), m.end(), t))
    if not spans:
        return text, 0
    out, last = [], 0
    for s, e, t in sorted(spans):
        out.append(text[last:s])
        out.append(t)
        last = e
    out.append(text[last:])
    return "".join(out), len(spans)


# ---------------------------------------------------------------- sentence similarity
_INVISIBLE_CATS = {"Cf", "Cc", "Cs", "Co", "Cn"}   # format, control, surrogate, private


def norm(s: str) -> str:
    """The comparison form of a sentence. A codepoint stream is not a sentence, and three
    separate review rounds got in through the gap between those two things.

    NFKC folds compatibility variants onto the characters they actually are. Fullwidth
    Latin (`ｃａｃｈｅ`) renders as `cache`, is read aloud as `cache`, and shares not one
    codepoint with it — that walked 176 of 264 eval references past a guard that had
    already been hardened twice.

    Then drop everything that renders as nothing. U+200B injected every third character
    leaves a sentence a human reads aloud verbatim, and it took 263 of 264 references
    through. The first fix for that was a hand-written list of ranges, and the very next
    round arrived with U+061C, which was not on the list. There is no end to that game.
    Unicode already classifies these; ask it.

    The lesson underneath both: normalise to what the text MEANS before comparing, never
    to what it happens to be encoded as.
    """
    return re.sub(r"[\s\-_.,!?ๆฯ]+", "", clean(s).lower())


def clean(s: str) -> str:
    """NFKC, then drop what renders as nothing — but KEEP the separators.

    Newline is category Cc. Stripping the category wholesale therefore deleted it, and
    `buy milk\\nbuy eggs` tokenised as `buy / milkbuy / eggs`: two words welded into one
    that exists in no dictionary, and five multi-line eval sentences quietly stopped being
    detectable as reordered. Invisible is not the same as meaningless — whitespace is both
    invisible and load-bearing. Fold it to a space; delete only the rest.
    """
    folded = unicodedata.normalize("NFKC", s)
    return "".join(" " if c.isspace()
                   else "" if unicodedata.category(c) in _INVISIBLE_CATS
                   else c
                   for c in folded)


def hostile_chars(s: str) -> list[str]:
    """Characters no legitimate label contains. Empty list means the text can be trusted.

    Bidi controls do not merely hide — they REORDER. Store the Latin runs of an eval
    sentence backwards, wrap them in U+202E RIGHT-TO-LEFT OVERRIDE, and the terminal
    renders the original sentence perfectly: a human reads it aloud verbatim. Deleting the
    control then leaves the guard comparing the REVERSED text, which matches nothing. 164
    of 195 references walked through exactly that.

    The mistake was treating this as a normalisation problem at all. You cannot recover
    rendered meaning from an adversarial encoding by deleting characters — the rendering is
    the output of an algorithm you are not running. Every round I tried to interpret these
    inputs, the next round found an encoding I had not thought of. So stop interpreting.
    REFUSE. No Thai-English dictation sentence has ever needed a bidi override, a private-
    use codepoint or an unpaired surrogate, and a label that contains one is not a label.
    """
    return sorted({f"U+{ord(c):04X} {unicodedata.name(c, 'unnamed')}"
                   for c in s
                   if not c.isspace() and unicodedata.category(c) in _INVISIBLE_CATS})


def grams(s: str, n: int = 4) -> set[str]:
    t = norm(s)
    return {t[i:i + n] for i in range(max(1, len(t) - n + 1))}


def jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def contiguous_ratio(needle: str, haystack: str) -> float:
    """Longest CONTIGUOUS run of `needle` present in `haystack`, over len(needle).

    Jaccard cannot see a training sentence that WRAPS an eval sentence: the extra words
    inflate the union and drag the score down. Two eval references got into the corpus
    exactly that way, scoring 0.57 and 0.42 against a 0.60 gate.

    The obvious repair — asymmetric overlap of 4-gram SETS — is worse than useless here.
    Short, generic eval lines ("ช่วย review pull request ให้หน่อย") are built from
    4-grams that any sentence on the same topic also contains, so set-containment scored
    0.77 for every unrelated sentence about reviewing a PR and 1.00 for the real leaks:
    no separation at all. What actually distinguishes a leak is that the eval sentence
    survives INTACT, in order. Contiguity is that question. Real leaks score 1.00 here;
    unrelated sentences that merely share the topic score 0.38-0.50.
    """
    a, b = norm(needle), norm(haystack)
    if not a:
        return 0.0
    return SequenceMatcher(None, a, b, autojunk=False).find_longest_match(
        0, len(a), 0, len(b)).size / len(a)


def ordered_ratio(needle: str, haystack: str) -> float:
    """How much of `needle` appears inside `haystack` IN ORDER, counting every matching
    run rather than only the longest one.

    contiguous_ratio() measures the single longest run, and that is exactly where the
    leak guard was walked through: put one phrase in the MIDDLE of an eval sentence and
    the longest run halves, while the eval sentence is still there in its entirety, in
    order, on both sides of the insertion.

        eval    ตั้ง cron job ให้ backup database ทุกเที่ยงคืน
        attack  ตั้ง cron job ให้ backup ข้อมูลสำคัญ database ทุกเที่ยงคืน
                longest run 0.50 (under a 0.60 gate) — total ordered 1.00

    A systematic midpoint insertion into every eval sentence slipped 124 of 188 past the
    longest-run gate and 0 of 188 past this one. Insertions cannot lower it at all: the
    needle's characters are all still present, all still in order.
    """
    a, b = norm(needle), norm(haystack)
    if not a:
        return 0.0
    return sum(x.size for x in
               SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks()) / len(a)


def tokens(s: str) -> list[str]:
    """Word-level tokens. Thai has no spaces, so this needs a real tokeniser (newmm);
    English runs are split off first and lowercased.

    Normalised the same way as norm(), or a fullwidth reordering walks straight past the
    one check that was built to catch reorderings.
    """
    from pythainlp.tokenize import word_tokenize      # benchmark/.venv
    out: list[str] = []
    for part in re.split(r"([A-Za-z0-9.+#/-]+)", clean(s)):
        if not part.strip():
            continue
        if re.match(r"^[A-Za-z0-9]", part):
            out.append(part.lower())
        else:
            out += [t for t in word_tokenize(part, engine="newmm") if t.strip()]
    return out


def token_containment(needle: str, haystack: str) -> float:
    """How much of `needle`'s WORD multiset is present in `haystack`, order ignored.

    Order-preserving checks cannot see a reordered eval sentence — the words are all
    still there, just shuffled, and a human reading it aloud is still saying the
    benchmark's content. This is the check that does not care about order, and it is the
    only one that closes that hole: a pure reordering keeps every word, so it scores 1.00
    here no matter how the sentence is scrambled.
    """
    n, h = Counter(tokens(needle)), Counter(tokens(haystack))
    if not n:
        return 0.0
    return sum(min(c, h[w]) for w, c in n.items()) / sum(n.values())


LEAK_C = 0.60      # longest contiguous run of an eval sentence inside this one
LEAK_T = 0.90      # ...or its whole vocabulary is here, in any order (reordering).
                   # Pure reorderings score 1.00. Measured over 646,272 real pairs, this
                   # gate drops only 3 extra sentences — the ones it does hit are short
                   # generic eval lines whose every word turns up in a longer sentence,
                   # and dropping three of thousands to close a hole a reviewer called a
                   # C1 violation is not a close call.
LEAK_O = 0.80      # ...or how much of it survives in order, across all runs.
                   # Measured over 648,375 (training, eval) pairs: non-leaks sit at
                   # median 0.19, p99 0.46. Gating at 0.80 drops 22 of 2,456 generated
                   # sentences (0.9%) — a price worth paying, since a good sentence lost
                   # is one of thousands and a leak lost is the whole benchmark.


def is_eval_leak(text: str, forbidden: list[str]) -> str | None:
    """The eval sentence this text would leak, or None. THE definition — every gate that
    can put a label into the training set calls this one.

    build_script.py guarding the generated script is not enough: the recorder lets you
    edit a sentence to anything, and export writes whatever label the take carries. A
    guard that runs only at generation time protects an artifact, not the training set.

    WHAT IT CATCHES: verbatim reuse; an eval sentence surviving contiguously inside a
    longer one (how the two real leaks got in); and an eval sentence that survives in
    ORDER but broken up by inserted words (how a reviewer walked through the fix for the
    first two).

    Three questions, because no one of them is enough:
      * is the eval sentence literally in here?                       (substring)
      * does a long stretch of it survive intact?                     (contiguous)
      * does ALL of it survive in order, split up by insertions?      (ordered)
      * is its whole vocabulary here, in any order?                   (token containment)

    The last one exists because the first three all preserve order, and a reordered eval
    sentence keeps none of it while keeping every word — a human reading it aloud is still
    saying the benchmark's content. A symmetric-Jaccard branch used to stand in for that
    and could not: across 648,375 pairs, unrelated sentences reach Jaccard 0.453 while
    reorderings of a real eval sentence score 0.324-0.386, so the leaks sat BELOW the
    noise. Characters were the wrong unit. Words are the right one, and at the word level
    a pure reordering scores 1.00 by construction.
    """
    nt = norm(text)
    for e in forbidden:
        if norm(e) in nt:
            return e
        # Cheap bound before the expensive part, so a 2,448 x 264 sweep takes seconds.
        #
        # This used to compare 4-GRAM sets, and that was not a bound at all — it was a
        # guess I called a bound, and "proved" only by checking that it agreed with the
        # slow path on sentences that happened to be in the corpus. Both real metrics
        # count CHARACTERS matched in order, and order-preserving matching happily pairs
        # single characters: put a separator between every letter and the shared 4-grams
        # drop to zero while ordered_ratio stays at 1.0. A reviewer used exactly that.
        #
        # Characters are what the metrics count, so characters are what the bound must
        # count. Matching in order cannot match more of `e` than `text` physically
        # contains, so multiset overlap is a true ceiling on both ratios.
        ne = norm(e)
        avail = Counter(nt)
        overlap = sum(min(c, avail[ch]) for ch, c in Counter(ne).items())
        if overlap / len(ne) <= min(LEAK_C, LEAK_O):
            continue
        if (contiguous_ratio(e, text) > LEAK_C
                or ordered_ratio(e, text) > LEAK_O
                or token_containment(e, text) > LEAK_T):
            return e
    return None
