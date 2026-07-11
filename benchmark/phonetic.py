"""Vocab-aware phonetic correction (post-STT, pre-LLM) for OLIV cleanup.

Problem it solves: Pathumma-Whisper transcribes a rare English term the user
registered in their custom vocabulary as a Thai-script phonetic garble
(Kafka -> "แคฟฟาร์", Terraform -> "เทลลาฟฟอร์ม"), and the STT initial_prompt bias
is too weak to prevent it. The correct term is sitting right there in the user's
vocab list, so we match the garbled Thai token(s) back to the user's OWN terms
and substitute -- deterministically, before the LLM can invent a wrong spelling
("Cafffair"). This is the custom-vocabulary product feature working as designed:
the candidate set is the user's 1-3 vocab terms, never an open dictionary.

Why folding: raw royin(Thai) vs English spelling can't be separated by edit
distance (thellaffom vs terraform ~0.6). Thai<->English phonetics reliably mangle
exactly two axes -- ASPIRATION (kh/th/ph<->k/t/p) and LIQUIDS (l<->r) -- plus
gemination. Fold both sides into one skeleton alphabet that removes those axes and
drops vowels, and the same pair collapses to ~0.2. Because the candidate set is
tiny, we can run a lenient threshold safely, with a first-consonant-class anchor
that rejects essentially all legit-Thai false matches.

Two match paths:
  * fuzzy   -- folded edit distance vs each WORD candidate; only over
               gate-suspicious tokens (Thai token not in thai_words), 1-3 token
               windows (เอ็งจิน+เอ็กซ์ -> one term).
  * acronym -- spelled-out letters (จีพียู = "chi-phi-yu" = G-P-U). High
               precision, so it may fire even on in-dictionary tokens (that is how
               จีพียู beats the naturalized-word gate skip without touching the gate).

No torch: pythainlp romanize(engine="royin") is rule-based.
"""
from __future__ import annotations

import re
from functools import lru_cache

_THAI_RE = re.compile(r"[฀-๿]")


# --------------------------------------------------------------------------- #
# Folding: project a romanized/English string into a consonant skeleton.
# --------------------------------------------------------------------------- #
_DIGRAPHS = [("kh", "k"), ("th", "t"), ("ph", "p"), ("ch", "c"), ("ck", "k"),
             ("gh", "g"), ("wh", "w"), ("qu", "kw")]
_VOWELS = set("aeiou")


def fold(s: str) -> str:
    """Phonetic skeleton of `s`: lowercase, de-aspirate digraphs (kh/th/ph->k/t/p),
    merge liquids (l->r), collapse doubled consonants, and normalize every vowel
    RUN to a single placeholder 'a'. Same map applied to both sides so a Thai
    romanization and an English spelling of the same word land on the same key.

    We KEEP vowels as position placeholders rather than dropping them: fully
    dropping vowels over-collapses short words into colliding consonant skeletons
    (config 'knfk' vs Kafka 'kfk' fold to distance 0.25 -> false match). Keeping a
    single vowel slot per run preserves syllable structure, so config vs Kafka
    separate cleanly while Kafka's own transliteration still bridges. Precision
    over recall: a false substitution corrupts text unrecoverably; a miss is caught
    by the LLM."""
    s = s.lower()
    s = re.sub(r"[^a-z]", "", s)
    for a, b in _DIGRAPHS:
        s = s.replace(a, b)
    s = s.replace("l", "r")            # merge liquids
    s = re.sub(r"[aeiou]+", "a", s)     # every vowel run -> one placeholder slot
    s = re.sub(r"(.)\1+", r"\1", s)     # collapse doubled consonants (and doubled slots)
    return s


@lru_cache(maxsize=4096)
def _royin(thai: str) -> str:
    from pythainlp.transliterate import romanize
    try:
        return romanize(thai, engine="royin") or ""
    except Exception:
        return ""


def thai_fold(thai: str) -> str:
    return fold(_royin(thai))


# --------------------------------------------------------------------------- #
# Acronym expansion: English letters -> their Thai letter-name royin.
# --------------------------------------------------------------------------- #
# Thai spellings of the English letter names; romanized once with royin so the
# acronym key is built the SAME way a Thai token is (consistent folding).
_THAI_LETTER_NAMES = {
    "a": "เอ", "b": "บี", "c": "ซี", "d": "ดี", "e": "อี", "f": "เอฟ",
    "g": "จี", "h": "เอช", "i": "ไอ", "j": "เจ", "k": "เค", "l": "แอล",
    "m": "เอ็ม", "n": "เอ็น", "o": "โอ", "p": "พี", "q": "คิว", "r": "อาร์",
    "s": "เอส", "t": "ที", "u": "ยู", "v": "วี", "w": "ดับเบิลยู",
    "x": "เอกซ์", "y": "วาย", "z": "แซด",
}


@lru_cache(maxsize=1024)
def _acronym_fold(term: str) -> str:
    """Fold of the spelled-out letter names, e.g. GPU -> chi+phi+yu -> skeleton."""
    return fold("".join(_royin(_THAI_LETTER_NAMES[c]) for c in term.lower()
                        if c in _THAI_LETTER_NAMES))


def _is_acronym(term: str) -> bool:
    t = term.replace(".", "")
    return 2 <= len(t) <= 5 and t.isupper() and t.isalpha()


# --------------------------------------------------------------------------- #
# Edit distance (normalized) + consonant-class anchor.
# --------------------------------------------------------------------------- #
def _lev(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _norm_dist(a: str, b: str) -> float:
    m = max(len(a), len(b))
    return 1.0 if m == 0 else _lev(a, b) / m


def _consonant_coverage(term: str, token_fold: str) -> float:
    """Fraction of the candidate term's DISTINCT consonants (folded, minus the
    'a' vowel slot) that appear in the token fold. Kills same-distance collisions
    that drop a key consonant: Kafka needs {k,f}, but giga 'กิกา'->'kaka' has only
    {k} -> 0.5; Terraform {t,r,f,m} fully present in 'tarafarm' -> 1.0. 1.0 if the
    candidate has no consonants (acronym-like)."""
    cand = set(fold(term)) - {"a"}
    if not cand:
        return 1.0
    have = set(token_fold) - {"a"}
    return len(cand & have) / len(cand)


# --------------------------------------------------------------------------- #
# Public: correct a text against a small vocab candidate set.
# --------------------------------------------------------------------------- #
# PRECISION-FIRST thresholds, calibrated against a generic-vocab false-positive
# sweep over all raw transcripts. Deliberately tight: auto-replace fires ONLY on
# faithful transliterations (Terraform เทลลาฟฟอร์ม d=0.12, Redis เรดดิส d=0.20) and
# near-exact spelled-out acronyms (GPU/API d=0.00). Heavily-mangled translits
# (Kafka แคฟฟาร์ d=0.33) are LEFT for the LLM candidate-hint path (see
# vocab_hint) -- because they collide with unrelated words at the SAME distance
# (giga กิกา -> Kafka d=0.20), so auto-replacing them is unsafe for a real user's
# multi-term vocab. A false substitution is unrecoverable; a miss is caught by the
# LLM with sentence context.
FUZZY_MAX = 0.20
FUZZY_MARGIN = 0.15       # winner must beat runner-up by this (>=2 word cands)
ACRO_MAX = 0.15           # spelled-out acronyms match near-exact (0.00); false ~0.25
MIN_FOLD_LEN = 3
CONS_COVERAGE = 0.6       # candidate's distinct consonants must be >=60% present


def _token_spans(text: str):
    from pythainlp.tokenize import word_tokenize
    spans, pos = [], 0
    for tok in word_tokenize(text, engine="newmm", keep_whitespace=True):
        spans.append((pos, pos + len(tok), tok))
        pos += len(tok)
    return spans


def _is_real_thai(tok: str) -> bool:
    from pythainlp.corpus import thai_words
    return tok in thai_words()


@lru_cache(maxsize=1)
def _stopwords():
    from pythainlp.corpus import thai_stopwords
    return thai_stopwords()


def _has_stopword(toks) -> bool:
    """A transliteration garble never contains a Thai function word (title/
    pronoun/particle: คุณ/นาย/ที่/ใน/และ). Such a token inside a window means the
    window straddles real speech -> not a single transliterated term. This is the
    guard that stops a NAME after a title (คุณกิ -> 'kanka') from snapping to a
    phonetically-near vocab term (Kafka 'kafka'); the transliteration fragments
    themselves (แค, เท, ลา, ฟอร์ม) are NOT stopwords, so real matches survive."""
    sw = _stopwords()
    return any(t in sw for t in toks)


def correct_with_vocab(text: str, vocab_terms):
    """Return (new_text, n_fired, subs). subs = [(thai_span, english)] for logging.

    Matches gate-suspicious Thai token windows (1-3 adjacent) against the user's
    OWN vocab terms via folded phonetics; acronym terms also match in-dictionary
    tokens. Non-overlapping, best-score-first. Byte-identical passthrough on no
    match. Never touches non-Thai spans or real Thai words (except an acronym
    token that a spelled-out-letters candidate matches tightly)."""
    if not text or not vocab_terms or not _THAI_RE.search(text):
        return text, 0, []
    word_cands = [t for t in vocab_terms if t and not _is_acronym(t)]
    acro_cands = [t for t in vocab_terms if _is_acronym(t)]
    word_folds = [(t, fold(t)) for t in word_cands]
    word_folds = [(t, f) for t, f in word_folds if len(f) >= MIN_FOLD_LEN]
    acro_folds = [(t, _acronym_fold(t)) for t in acro_cands]

    spans = _token_spans(text)
    # indices of non-space tokens
    idx = [k for k, (_, _, tok) in enumerate(spans) if tok.strip()]

    proposals = []  # (score, start, end, english)
    for a in range(len(idx)):
        for w in (1, 2, 3, 4, 5):
            if a + w > len(idx):
                break
            toks = [spans[idx[a + k]][2] for k in range(w)]
            if not all(_THAI_RE.search(t) for t in toks):
                continue  # window must be Thai-script
            if _has_stopword(toks):
                continue  # a window never spans a Thai function word (see _has_stopword)
            start = spans[idx[a]][0]
            end = spans[idx[a + w - 1]][1]
            joined = "".join(toks)
            wf = thai_fold(joined)
            if len(wf) < MIN_FOLD_LEN:
                continue
            first = wf[0]
            # A window is a candidate garble if it CONTAINS >=1 suspicious token
            # (newmm greedily splits a transliteration into real-word fragments --
            # แคฟฟาร์ -> แค[real]+ฟฟาร์, เทลลาฟฟอร์ม -> 5 pieces incl. loanword ฟอร์ม --
            # so requiring EVERY token be non-real would never fire). The tight
            # fold + first-consonant anchor + margin over a TINY candidate set are
            # what keep legit Thai safe, not this flag.
            any_suspicious = any(not _is_real_thai(t) for t in toks)

            # acronym path (may fire on real words too)
            for term, af in acro_folds:
                if not af or af[0] != first:
                    continue
                d = _norm_dist(wf, af)
                if d <= ACRO_MAX:
                    proposals.append((d, start, end, term))

            # fuzzy word path (windows anchored by >=1 suspicious token)
            if any_suspicious and word_folds:
                scored = sorted((( _norm_dist(wf, f), term) for term, f in word_folds))
                d1, best = scored[0]
                if (d1 <= FUZZY_MAX and best and fold(best)[0] == first
                        and _consonant_coverage(best, wf) >= CONS_COVERAGE):
                    if len(scored) >= 2 and scored[1][0] - d1 < FUZZY_MARGIN:
                        pass  # ambiguous -> skip
                    else:
                        proposals.append((d1, start, end, best))

    if not proposals:
        return text, 0, []

    # greedily claim best (lowest score, then longest span) non-overlapping
    proposals.sort(key=lambda p: (p[0], -(p[2] - p[1])))
    claimed = [False] * len(text)
    chosen = []
    for score, s, e, term in proposals:
        if any(claimed[s:e]):
            continue
        for x in range(s, e):
            claimed[x] = True
        chosen.append((s, e, term))
    if not chosen:
        return text, 0, []

    chosen.sort()
    out, pos, subs = "", 0, []
    for s, e, term in chosen:
        out += text[pos:s]
        if out and not out[-1].isspace():
            out += " "
        out += term
        if e < len(text) and not text[e].isspace():
            out += " "
        subs.append((text[s:e], term))
        pos = e
    out += text[pos:]
    out = re.sub(r"[ \t]{2,}", " ", out).strip()
    return out, len(chosen), subs


def fuzzy_command_spans(text: str, commands, max_dist: float = 0.28):
    """Find spans of `text` that fuzzy-match a canonical THAI command phrase.

    `commands` = [(canonical_thai_phrase, replacement)]. Different STT models
    transcribe the same spoken command differently and glue it to adjacent Thai
    (typhoon writes "ขึ้นบรรทัดใหม่" as "ขึ้นมาทัดใหม่"); enumerating exact spellings is
    whack-a-mole, so we fold both sides (royin skeleton) and match by normalized
    edit distance. Thai has no word boundaries, so there is deliberately NO flank
    guard here (that concept is Latin-only; the English commands keep their guard
    in the caller). Returns non-overlapping (start, end, replacement), best-first.
    High coverage + a tight threshold keep it from firing on ordinary Thai."""
    if not text or not _THAI_RE.search(text):
        return []
    cmd_folds = [(thai_fold(p), p, r) for p, r in commands]
    cmd_folds = [(cf, p, r) for cf, p, r in cmd_folds if len(cf) >= 4]
    spans = _token_spans(text)
    idx = [k for k, (_, _, t) in enumerate(spans) if t.strip() and _THAI_RE.search(t)]
    proposals = []
    for a in range(len(idx)):
        for w in range(1, 8):  # a command spans several newmm fragments
            if a + w > len(idx):
                break
            # windows must be (near-)contiguous Thai — stop if a big non-Thai gap opens
            start = spans[idx[a]][0]
            end = spans[idx[a + w - 1]][1]
            wf = thai_fold(text[start:end])
            if len(wf) < 4:
                continue
            for cf, phrase, repl in cmd_folds:
                # A short royin skeleton (e.g. "นิวไลน์"->"nara", len 4) has too few
                # degrees of freedom: ONE substitution collides with ordinary Thai
                # ("หน่อยได้"->"nada", d=0.25 -> phantom line break). Require an EXACT
                # fold for <6-char commands; keep fuzzy tolerance only where the
                # skeleton is long enough for drift to be distinguishable from noise.
                thresh = max_dist if len(cf) >= 6 else 0.0
                d = _norm_dist(wf, cf)
                if d <= thresh:
                    proposals.append((d, start, end, repl))
    if not proposals:
        return []
    proposals.sort(key=lambda p: (p[0], -(p[2] - p[1])))
    claimed = [False] * len(text)
    chosen = []
    for d, s, e, r in proposals:
        if any(claimed[s:e]):
            continue
        for x in range(s, e):
            claimed[x] = True
        chosen.append((s, e, r))
    return sorted(chosen)


HINT_MAX = 0.40           # wider band for LLM hints than for auto-replace


def vocab_hint(text: str, vocab_terms):
    """Vocab terms that PLAUSIBLY appear (a suspicious window bridges them within
    HINT_MAX and passes the consonant-coverage guard) but were too mangled to
    auto-replace safely (e.g. Kafka <- แคฟฟาร์, d=0.33). Returned as hints for the
    LLM, which resolves them WITH sentence context -- safer than a deterministic
    snap for the ambiguous band. Excludes terms already auto-corrected."""
    if not text or not vocab_terms or not _THAI_RE.search(text):
        return []
    _, _, subs = correct_with_vocab(text, vocab_terms)
    done = {en for _, en in subs}
    word_cands = [t for t in vocab_terms if t and not _is_acronym(t) and t not in done]
    word_folds = [(t, fold(t)) for t in word_cands if len(fold(t)) >= MIN_FOLD_LEN]
    spans = _token_spans(text)
    idx = [k for k, (_, _, tok) in enumerate(spans) if tok.strip()]
    hinted = []
    for a in range(len(idx)):
        for w in (1, 2, 3, 4, 5):
            if a + w > len(idx):
                break
            toks = [spans[idx[a + k]][2] for k in range(w)]
            if not all(_THAI_RE.search(t) for t in toks) or _has_stopword(toks):
                continue
            if not any(not _is_real_thai(t) for t in toks):
                continue
            wf = thai_fold("".join(toks))
            if len(wf) < MIN_FOLD_LEN:
                continue
            for term, f in word_folds:
                if (f[:1] == wf[:1] and _norm_dist(wf, f) <= HINT_MAX
                        and _consonant_coverage(term, wf) >= CONS_COVERAGE):
                    if term not in hinted:
                        hinted.append(term)
    return hinted


if __name__ == "__main__":
    cases = [
        ("ทีมเราใช้ แคฟฟาร์ ทำอีเวนต์สตรีมมิงก์", ["Kafka"]),
        ("ดีพลอยด้วยเทลลาฟฟอร์มขึ้น GCP", ["Terraform", "GCP"]),
        ("ตั้งค่า เอ็งจิน เอ็กซ์ เป็น รีเวิร์ส พรอก ซี", ["nginx"]),
        ("บริษัท nvidia เปิดตัวจีพียูรุ่นใหม่", ["GPU"]),
        ("ใช้ปฐมมากับเจมม่าในไพรต์ไลน์ของ โอ ลิ ฟ", ["Pathumma", "Gemma", "OLIV"]),
        ("วันนี้ประชุมทีมตอนบ่ายสอง", ["Kafka"]),          # must NOT fire (legit Thai)
        ("นัดกับคุณเจนจิรา", ["Grafana"]),                  # must NOT fire (Thai name)
    ]
    for text, vocab in cases:
        out, n, subs = correct_with_vocab(text, vocab)
        print(f"vocab={vocab}")
        print(f"  IN : {text}")
        print(f"  OUT: {out}   [{n} fired] {subs}")

    # Negative sweep: a plausible vocab over pure-Thai references must NEVER fire.
    print("\n--- negative sweep (pure Thai + jargon vocab, expect 0 fires) ---")
    thai_refs = [
        "เรียนทุกท่าน ขอสรุปประเด็นจากการประชุมเมื่อเช้านี้",
        "ประชุมทีมประจำสัปดาห์ย้ายจากวันจันทร์ไปวันอังคารนะครับ",
        "ฝากทุกคนช่วยกันทบทวนเอกสารสเปกก่อนประชุมพรุ่งนี้",
        "นัดประชุมกับคุณปัณณวิชญ์และคุณเจนจิราตอนบ่ายสอง",
        "ขอบคุณทุกคนที่ช่วยกันทำงานหนักสัปดาห์นี้",
    ]
    vocab = ["Kafka", "Terraform", "nginx", "Grafana", "Kubernetes", "GPU"]
    fires = 0
    for t in thai_refs:
        out, n, subs = correct_with_vocab(t, vocab)
        if n:
            fires += n
            print(f"  FALSE FIRE: {subs}  in  {t}")
    print(f"  total false fires: {fires}  {'PASS' if fires == 0 else 'FAIL'}")
