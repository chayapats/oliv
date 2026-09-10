"""OLIV cleanup pipeline (CLN-T2): the composed, production-shaped cleanup.

Architecture:

    raw ASR text
      -> apply_dictionary()   deterministic known-term fixes (dictionary.py)
      -> GATE                 decide if the LLM pass is worth its latency
      -> v2 LLM cleanup       Gemma 4 E2B, prompt CLEANUP_V2 (frozen), thinking OFF
      -> guardrails           strip stop-tokens, token-count clamp, safe fallback

Public API
----------
    clean(text)     -> str            the final cleaned text
    clean_ex(text)  -> CleanResult    full per-stage trace + timings
    clean() == clean_ex().text

Lazy loading: `import pipeline` must NOT load the LLM. The Gemma model is loaded
once, on the first call that actually needs it (singleton). Its load time is
recorded in the module global LOAD_TIME and is *excluded* from every per-call
timing (t_llm / t_total) so CLN-T3 measures steady-state per-utterance latency.

--------------------------------------------------------------------------------
GATE DESIGN (runs on the POST-dictionary text)
--------------------------------------------------------------------------------
Skip the LLM iff either:
  1. the text contains no Thai characters at all  -> gate_reason="no-thai"
     (pure English/Latin; nothing to de-transliterate), OR
  2. dict_hits == 0 AND there are no *suspicious* Thai tokens AND no
     *loan-compound* Thai runs                 -> gate_reason="clean-thai"
Otherwise run the LLM, with gate_reason one of:
     "dict-hit"                 (a deterministic fix fired -> code-switching proven)
     "suspect-tokens"           (an unknown Thai token looks like a residual)
     "loan-compound"            (Thai run looks like syllable-soup transliteration)
     combinations joined with "+"

Suspicious token = a newmm token (plain built-in dictionary, keep_whitespace=
False) that CONTAINS Thai characters and is NOT in pythainlp.corpus.thai_words().
Pure-Latin / digit / punctuation tokens are ignored.

Loan-compound run = a contiguous Thai substring (>=10 chars) that newmm splits
into mostly short real-word syllables with almost no long narrative Thai
content words — the "โหลดบาลานเซอร์" class that used to look like clean Thai.

Rationale:
  (a) dict_hits > 0 proves a code-switching utterance, so residual
      transliterations the dictionary didn't know are likely -> always run.
  (b) unknown Thai tokens are likely transliterations / garbles the dictionary
      couldn't map.

Known, accepted trade-offs (measured in CLN-T3, not defects):
  * Thai person names *may* be OOV and false-trigger the LLM. Harmless: the v2
    prompt is validated no-op-safe on monolingual Thai, so it costs only latency.
    Empirically the rate is low — newmm decomposes most common names into known
    syllables (สมชาย -> สม|ชาย, ธีรภัทร -> ธีร|ภัทร) that never trigger; only names
    newmm cannot segment (e.g. ปัณณวิชญ์) do. Demo case 8 exercises exactly this:
    the LLM runs and returns the sentence unchanged.
  * Naturalized transliterations that ARE already in thai_words (ล็อก, ซูม,
    ซิงค์, ฟอนต์, คอร์ส) will not trigger the gate by themselves. This is a
    deliberate safe-fail: they are indistinguishable from genuine Thai loanwords
    at the token level. (Verified against the two "mixed residual" demo cases,
    which correctly gate-skip.)

No refinement to the gate was needed: every tested case behaved as designed.

--------------------------------------------------------------------------------
GUARDRAILS (lifted from the gemma4 cleanup spike, with the fallback target changed)
--------------------------------------------------------------------------------
Philosophy: the transcript must never be lost or degraded by cleanup. On ANY
suspicion the candidate is discarded and we fall back to dict_text (the LLM
INPUT = post-dictionary text) -- the deterministic dictionary fixes survive, the
LLM's output does not. Checks run cheapest/grossest first (W2-T2):

  * strip the generation at the first stop marker in STOPS, then .strip().
  * empty output                 -> empty->dict
  * newmm token count vs dict_text:
        < 0.6x                   -> tooShort->dict  (model dropped content)
                                   EXCEPTION: Latin-gain vs dict_text
                                   (de-transliteration shrunk Thai syllables
                                   into fewer English tokens) — skip the floor;
                                   R1/R2 still apply
        > 1.6x                   -> tooLong->dict   (model rambled / hallucinated)
  * R1 protected Latin spans (_lost_spans): the LLM's only licensed edit is
    de-transliterating Thai-scripted English to Latin, so every Latin span the
    dictionary already produced must survive verbatim. Any drop / substitution /
    re-Thai-ification -> spanLoss->dict.
  * R2 Thai-content divergence (_thai_divergence): the token clamp misses
    same-length rewrites (the th05 blanket-hallucination class). If the candidate
    loses long genuine Thai words or invents new Thai content -> editDist->dict.
  * FALLBACK TARGET = the post-dictionary text, NOT the raw input. The dictionary
    fixes are deterministic and safe, so they must survive an LLM failure.
  * flags: ok / empty->dict / tooShort->dict / tooLong->dict / spanLoss->dict /
    editDist->dict ; and "skipped" when the gate never ran the LLM.

Both R1 and R2 were calibrated to fire on ZERO of the 145 cached good
generations (_clean_cache_dict.json v2+dict, plus the two spike-cleaned sets)
and to fire on the reconstructable v1-era blanket hallucinations (th05 both
bases + the "A/B testing" garbage). See _lost_spans / _thai_divergence for the
per-threshold justifications and the clip ids that forced each relaxation.
"""
from __future__ import annotations

import os
import re
import sys
import threading
import time
from dataclasses import dataclass, field

from pythainlp.corpus import thai_words
from pythainlp.tokenize import word_tokenize

import metrics
from dictionary import CANONICAL_CASE, apply_canonical_casing, apply_dictionary
from phonetic import correct_with_vocab, vocab_hint
from prompts import CLEANUP_V2, CLEANUP_V3, CLEANUP_V4

# Cleanup system prompt, A/B-selectable via OLIV_CLEANUP_PROMPT.
# Default stays V2 (frozen anti-hallucination baseline). V4 adds English ASR
# near-miss repair but still risks Thai→English translation on E2B — opt in via
# OLIV_CLEANUP_PROMPT=v4 after checking holdout/nm/fm.
_PROMPTS = {"v2": CLEANUP_V2, "v3": CLEANUP_V3, "v4": CLEANUP_V4}
CLEANUP_PROMPT = _PROMPTS.get(os.environ.get("OLIV_CLEANUP_PROMPT", "v2").lower(), CLEANUP_V2)

# --------------------------------------------------------------------------- #
# Model / generation config (lifted verbatim from the gemma4 cleanup spike)
# --------------------------------------------------------------------------- #
# The cleanup LLM. Overridable via OLIV_CLEANUP_MODEL so the eval harness can A/B
# any model WITHOUT editing code. Default is E2B: the 2026-07 down-sizing search
# (STT held at typhoon-turbo) found it TIES E4B on the holdout (0.891/90.0 vs
# 0.893/90.0, 0 catastrophic) at −1.5GB and faster; every smaller off-the-shelf
# model regressed the holdout (typhoon2.1-gemma3-4b −2.5pp; Qwen3-1.7B collapsed to
# no-LLM level). See memory oliv-cleanup-model-search-2026-07.
# GATE: confirm E2B vs E4B on ~15-20 FRESH clips (D2 session) before merging to main.
DEFAULT_CLEANUP_MODEL = "mlx-community/gemma-4-e2b-it-4bit"
MODEL = os.environ.get("OLIV_CLEANUP_MODEL", DEFAULT_CLEANUP_MODEL)
MAX_TOKENS = 200

STOPS = ["<end_of_turn>", "<eos>", "<end_of_text>", "<|channel", "\nIN:", "\nOUT:", "\n\n"]

_THAI_RE = re.compile(r"[฀-๿]")
_THAI_WORDS = thai_words()  # ~62k real Thai words incl. naturalized loans (frozenset)

# --------------------------------------------------------------------------- #
# Lazy singleton model state — importing this module must NOT load the model.
# --------------------------------------------------------------------------- #
_MODEL = None
_TOK = None
_SAMPLER = None
LOAD_TIME: float | None = None  # seconds spent loading the model (excluded from per-call timings)
# Serializes the one-time load so a background warm loader (sidecar Option B) and a
# concurrent dictate lazy-load coordinate: exactly one load, the other waits.
_MODEL_LOCK = threading.Lock()


def _ensure_model():
    """Load Gemma 4 once; record load time in LOAD_TIME. Returns (model, tok, sampler).

    Thread-safe via DOUBLE-CHECKED locking so the sidecar's background warm loader
    and a concurrent dictate lazy-load never both load: the lock-free fast path
    returns immediately once loaded (steady state pays no lock); otherwise a caller
    takes _MODEL_LOCK, RE-CHECKS under it, and only the first runs the load body —
    the second blocks, then the re-check sees the published model and returns it.

    Publish ORDER matters: _TOK / _SAMPLER / LOAD_TIME are assigned first and
    _MODEL is published LAST, so the lock-free fast path can never observe a
    non-None _MODEL beside a still-None _TOK / _SAMPLER (each assignment is atomic
    under the GIL; publish-last is the ordering guarantee). Single-threaded
    behaviour is unchanged — the fast path is the old `if _MODEL is None` inverted.
    """
    global _MODEL, _TOK, _SAMPLER, LOAD_TIME
    # Lock-free fast path: once loaded, never take the lock.
    if _MODEL is not None:
        return _MODEL, _TOK, _SAMPLER
    with _MODEL_LOCK:
        # Re-check under the lock: a concurrent caller may have loaded while we
        # waited, so the load body runs exactly once.
        if _MODEL is None:
            from mlx_lm import load
            from mlx_lm.sample_utils import make_sampler

            t0 = time.time()
            model, tok = load(MODEL)
            sampler = make_sampler(temp=0.0)  # greedy / deterministic
            _TOK = tok
            _SAMPLER = sampler
            LOAD_TIME = time.time() - t0
            _MODEL = model  # publish LAST (after _TOK / _SAMPLER / LOAD_TIME)
    return _MODEL, _TOK, _SAMPLER


# One priming generation warms the MLX generate graph AND -- critically for
# warm_load below -- materializes the weights on the thread that loaded them. A
# dict-hit code-switch text exercises the real path; the exact content only affects
# warmth, not correctness.
_PRIME_TEXT = "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา"


def warm_load() -> None:
    """LOAD **and prime** Gemma under _MODEL_LOCK, publishing _MODEL LAST — the
    thread-safe entry point for loading the model OFF the request loop (the
    sidecar's Option B background warm).

    Why this exists separately from _ensure_model: on this MLX/Metal stack a model
    whose weights were loaded on thread A cannot be generated with from thread B
    until thread A has first MATERIALIZED the weights with a real generate —
    otherwise thread B crashes with "There is no Stream(gpu, N) in current thread."
    (reproduced live). And two generates running on different threads at once ALSO
    crash. So a background loader must (1) prime on its OWN thread so the request
    loop can later generate safely, and (2) never let a request-loop generate
    overlap that prime.

    Both are satisfied by holding _MODEL_LOCK across BOTH the load and the prime and
    publishing _MODEL only AFTER the prime: a concurrent dictate's _ensure_model
    blocks on _MODEL_LOCK (its fast path can't fire — _MODEL is still None) until
    this returns, then takes the fast path and generates on the request-loop thread
    with fully-materialized weights, never concurrently with the prime. A pure-Thai
    dictate gate-skips the LLM entirely, so its STT runs concurrent with the prime —
    the exact load+prime-vs-STT scenario the Option B spike validated as safe.

    If the prime raises, _MODEL is left UNPUBLISHED on purpose: the caller
    (_bg_cleanup_warm) logs it and the request loop's own _ensure_model then loads
    cleanly on-thread (load and first generate on the same thread — trivially safe).
    Idempotent; a no-op once loaded."""
    global _MODEL, _TOK, _SAMPLER, LOAD_TIME
    if _MODEL is not None:
        return
    with _MODEL_LOCK:
        if _MODEL is not None:
            return
        from mlx_lm import generate, load
        from mlx_lm.sample_utils import make_sampler

        t0 = time.time()
        model, tok = load(MODEL)
        sampler = make_sampler(temp=0.0)  # greedy / deterministic
        LOAD_TIME = time.time() - t0
        # Prime on THIS (loader) thread so the weights are materialized here BEFORE
        # _MODEL is published. If this raises, _MODEL stays None (unpublished) so the
        # lazy path reloads cleanly on the request-loop thread.
        generate(model, tok, prompt=_build_prompt(tok, _PRIME_TEXT),
                 max_tokens=MAX_TOKENS, sampler=sampler, verbose=False)
        _TOK = tok
        _SAMPLER = sampler
        _MODEL = model  # publish LAST (after load + prime)


def _hint_line(hints: "list[str] | None") -> str:
    """A strongly-conditional vocabulary hint for the LLM. Only the mangled-but-
    plausible terms from the user's own vocab (phonetic.vocab_hint) reach here;
    the phrasing keeps the v2 anti-hallucination contract intact -- restore ONLY
    on a sound match, never insert an absent term."""
    if not hints:
        return ""
    return ("\n\nThe user's vocabulary may include: " + ", ".join(hints)
            + ". If a Thai-script word clearly SOUNDS like one of these, restore"
              " that exact spelling. If its sound is not present, ignore the list"
              " -- never add a term that was not spoken.")


def _build_prompt(tok, text: str, hints: "list[str] | None" = None):
    """CLEANUP_PROMPT chat-template usage (thinking OFF), optionally with a
    user-vocabulary hint line for terms too mangled to auto-correct."""
    return tok.apply_chat_template(
        [{"role": "user", "content": CLEANUP_PROMPT + _hint_line(hints)
          + f"\n\nIN:  {text}\nOUT: "}],
        add_generation_prompt=True,
        enable_thinking=False,  # Gemma 4 is a reasoning model; keep CoT off
    )


def _llm_generate(text: str, hints: "list[str] | None" = None) -> str:
    """Run the v2 LLM cleanup on `text`, returning the RAW generation.

    Indirection point: tests monkeypatch `pipeline._llm_generate` to inject a
    bogus generation and exercise the guardrail fallback without loading a model.
    """
    from mlx_lm import generate

    model, tok, sampler = _ensure_model()
    return generate(
        model, tok, prompt=_build_prompt(tok, text, hints),
        max_tokens=MAX_TOKENS, sampler=sampler, verbose=False,
    )


# --------------------------------------------------------------------------- #
# Gate
# --------------------------------------------------------------------------- #
def _suspicious_tokens(text: str) -> list[str]:
    """newmm tokens that contain Thai characters but are not real Thai words."""
    out = []
    for t in word_tokenize(text, engine="newmm", keep_whitespace=False):
        if not t.strip():
            continue
        if not _THAI_RE.search(t):
            continue  # ignore pure-Latin / digit / punctuation tokens
        if t not in _THAI_WORDS:
            out.append(t)
    return out


# Contiguous Thai runs. Loan compounds (โหลดบาลานเซอร์, ออบเซอร์วาบิลิตี้) are
# long Thai strings that newmm splits into short real-word syllables with
# almost no long narrative content words — so _suspicious_tokens stays empty
# and the gate used to skip as "clean-thai".
_THAI_RUN_RE = re.compile(r"[฀-๿]+")
_LOAN_RUN_MIN_CHARS = 10
_LOAN_RUN_MIN_TOKS = 3
_LOAN_SHORT_MAX = 4          # syllable-like real words (โหลด=4; เซอร์=5 is mid)
_LOAN_LONG_CONTENT_MIN = 6   # narrative Thai content (ประชุม, ประเด็น, บรรทัด, …)
# Spoken-number utterances are also short-syllable runs; exclude them so nm
# clips stay clean-thai (v2 would no-op, but we avoid the extra latency).
_SPOKEN_NUMBER_WORDS = frozenset({
    "ศูนย์", "หนึ่ง", "เอ็ด", "สอง", "สาม", "สี่", "ห้า", "หก", "เจ็ด", "แปด",
    "เก้า", "สิบ", "ยี่สิบ", "ร้อย", "พัน", "หมื่น", "แสน", "ล้าน",
})
# Closed-class / discourse tokens: common in keep-Thai tech prose
# ("ช่วยเช็คล็อกในระบบ") and must NOT count as loan-syllable shreds.
_THAI_FUNCTION_WORDS = frozenset({
    "ใน", "ที่", "ของ", "และ", "กับ", "ให้", "ไป", "มา", "แล้ว", "ก็", "จะ",
    "ไม่", "ได้", "เป็น", "อยู่", "นี้", "นั้น", "หน่อย", "ไหม", "ครับ", "ค่ะ",
    "นะ", "เลย", "ด้วย", "จาก", "ถึง", "บน", "ลง", "ขึ้น", "หรือ", "แต่",
    "ถ้า", "เมื่อ", "ยัง", "แค่", "อีก", "ว่า", "เพื่อ", "โดย", "ตาม",
})


def _is_loan_compound_run(run: str) -> bool:
    """Structural: Thai run looks like transliterated English, not prose/numbers.

    newmm shreds loan compounds into short real-word syllables (โหลด|บา|ลาน|เซอร์)
    with near-zero long narrative content. Require at least one non-function
    shred (len<=2) so keep-Thai tech strings like ช่วยเช็คล็อกในระบบ stay
    clean-thai (they are short words but not syllable-soup).
    """
    if len(run) < _LOAN_RUN_MIN_CHARS:
        return False
    toks = [t for t in word_tokenize(run, engine="newmm", keep_whitespace=False)
            if t.strip() and _THAI_RE.search(t)]
    if len(toks) < _LOAN_RUN_MIN_TOKS:
        return False
    if sum(1 for t in toks if t in _SPOKEN_NUMBER_WORDS) >= 3:
        return False
    long_content = sum(
        1 for t in toks if t in _THAI_WORDS and len(t) >= _LOAN_LONG_CONTENT_MIN
    )
    short_real = sum(
        1 for t in toks if t in _THAI_WORDS and len(t) <= _LOAN_SHORT_MAX
        and t not in _THAI_FUNCTION_WORDS and t not in _SPOKEN_NUMBER_WORDS
    )
    shreds = sum(
        1 for t in toks if len(t) <= 2 and t not in _THAI_FUNCTION_WORDS
    )
    # Dense loan compounds: short dict syllables + newmm shreds, no long prose.
    return long_content == 0 and short_real >= 2 and shreds >= 1


def _loan_compound_runs(text: str) -> list[str]:
    """Thai substrings that look like English loan compounds (transliteration)."""
    return [m.group(0) for m in _THAI_RUN_RE.finditer(text)
            if _is_loan_compound_run(m.group(0))]


def _latin_crumbs(text: str) -> list[str]:
    """Single-letter Latin tokens amid Thai (ASR crumbs like 'P' in p99 garble).

    Pure prose with real Latin words (email, latency) does not qualify; a lone
    letter is almost never intentional in Thai+English dictation and is a cheap
    signal to run cleanup.
    """
    return [s for s in _LATIN_SPAN_RE.findall(text) if len(s) == 1 and s.isalpha()]


def _gate(dict_text: str, dict_hits: int) -> tuple[bool, str, list[str]]:
    """Return (run_llm, gate_reason, suspect_tokens) for the post-dictionary text."""
    if not _THAI_RE.search(dict_text):
        return False, "no-thai", []
    susp = _suspicious_tokens(dict_text)
    loans = _loan_compound_runs(dict_text)
    crumbs = _latin_crumbs(dict_text)
    if dict_hits == 0 and not susp and not loans and not crumbs:
        return False, "clean-thai", susp
    reasons = []
    if dict_hits > 0:
        reasons.append("dict-hit")
    if susp:
        reasons.append("suspect-tokens")
    if loans:
        reasons.append("loan-compound")
    if crumbs:
        reasons.append("latin-crumb")
    return True, "+".join(reasons), susp


# --------------------------------------------------------------------------- #
# Thai-spacing normalization (deterministic, whitespace-only)
# --------------------------------------------------------------------------- #
# Pathumma (and Whisper generally) sometimes emit Thai output segmented
# word-by-word -- "งาน ชิ้น นี้ ยาก" instead of "งานชิ้นนี้ยาก". Thai is written
# without inter-word spaces, so a space flanked by Thai script on BOTH sides is
# an ASR artifact. We collapse exactly those; a space touching a Latin letter or
# digit (i.e. around embedded English) is KEPT so code-switched text stays
# readable. This matches the manifest reference style (no Thai-Thai spaces,
# single spaces around English). It touches ONLY whitespace between Thai chars
# (never alters a word), but it DOES improve the metric: newmm tokenizes spaced
# vs unspaced Thai differently, so the artifact was inflating token-WER on mono
# Thai (th09 53.8->0.0, th03 14.3->0.0). results_clean_dict.json + the report
# were re-scored with this pass applied.
_THAI_THAI_SPACE_RE = re.compile(r"(?<=[฀-๿])[ \t]+(?=[฀-๿])")
# House style puts a space between Thai text and an embedded English word. Some
# cleanup models emit them glued ("ตั้งalert"); insert a single space at any
# Thai<->Latin-LETTER boundary that has none. Zero-width lookaround => idempotent,
# and it never touches Thai<->digit or already-spaced boundaries.
_THAI_LATIN_GLUE_RE = re.compile(r"(?<=[฀-๿])(?=[A-Za-z])|(?<=[A-Za-z])(?=[฀-๿])")


def normalize_thai_spacing(text: str) -> str:
    """Normalise OLIV's Thai/English spacing to house style: remove ASR
    word-segmentation spaces between two Thai characters, AND insert a single
    space at any glued Thai<->Latin-letter boundary (some cleanup models emit
    "ตั้งalert"; house style is "ตั้ง alert"). Spaces already around embedded
    English/digits are preserved; pure-Thai and pure-Latin are untouched;
    idempotent."""
    text = _THAI_LATIN_GLUE_RE.sub(" ", text)
    return _THAI_THAI_SPACE_RE.sub("", text)


# --------------------------------------------------------------------------- #
# Guardrails (fallback target = the post-dictionary text)
# --------------------------------------------------------------------------- #
def _strip_out(t: str) -> str:
    for s in STOPS:
        i = t.find(s)
        if i != -1:
            t = t[:i]
    return t.strip()


# --------------------------------------------------------------------------- #
# R1 — protected Latin spans (flag spanLoss->dict)
# --------------------------------------------------------------------------- #
# A "span" is a maximal run of Latin script the LLM must carry through verbatim:
# it starts with an ASCII letter and continues with letters/digits, allowing the
# ASCII "joiners" ( / . _ + - ) that glue a code identifier into one token
# (A/B, p99, requirements.txt, CI/CD, fine-tune). Bare digit runs are NOT spans:
# they are not Latin script and the LLM legitimately rewrites numerals
# (ห้าร้อย->500, พีเก้าเก้า->99). The de-transliteration job only ever ADDS Latin
# (Thai script -> Latin); it must never drop, mutate, or re-Thai-ify Latin that
# dict_text already contained.
_LATIN_SPAN_RE = re.compile(r"[A-Za-z][A-Za-z0-9]*(?:[/._+-][A-Za-z0-9]+)*")
# Canonical / brand Latin must survive verbatim — never count as "ASR repair".
_PROTECTED_LATIN = frozenset(CANONICAL_CASE) | frozenset(
    v.lower() for v in CANONICAL_CASE.values() if isinstance(v, str)
)


def _within_one_edit(a: str, b: str) -> bool:
    """True iff a and b differ by at most one insert/delete/substitution."""
    la, lb = len(a), len(b)
    if abs(la - lb) > 1:
        return False
    if la == lb:
        return sum(1 for x, y in zip(a, b) if x != y) <= 1
    if la > lb:  # make `a` the shorter one
        a, b, la, lb = b, a, lb, la
    i = j = 0
    edited = False
    while i < la and j < lb:
        if a[i] == b[j]:
            i += 1
            j += 1
        else:
            if edited:
                return False
            edited = True
            j += 1  # consume the extra char in the longer string
    return True


def _edit_distance(a: str, b: str) -> int:
    """Levenshtein distance (small strings only — Latin spans)."""
    n, m = len(a), len(b)
    if abs(n - m) > 3:
        return 99
    prev = list(range(m + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * m
        for j, cb in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
        prev = cur
    return prev[m]


def _is_asr_english_repair(lost: str, cand_spans: list[str]) -> bool:
    """True when a lost Latin span looks like STT English junk repaired in cand.

    Used only together with Latin-gain (see _guardrail) so server→sorter alone
    still fires spanLoss. Brands in CANONICAL_CASE stay strict. Short acronyms
    (UI) stay strict via len < 4.
    """
    sl = lost.lower()
    if len(sl) < 4 or sl in _PROTECTED_LATIN:
        return False
    for t in cand_spans:
        tl = t.lower()
        if not tl or sl[0] != tl[0]:
            continue
        if _within_one_edit(sl, tl) or _edit_distance(sl, tl) <= 3:
            return True
    return False


def _lost_spans(dict_text: str, cand: str, *, allow_asr_repair: bool = False) -> list[str]:
    """Latin spans in dict_text that fail to survive into the candidate.

    Matching relaxations, each calibrated to fire on ZERO of the 145 cached good
    generations and justified by the good pair that forced it:
      * case-insensitive  -- the LLM re-cases loanwords (pn05 google->Google,
        pn08 facebook->Facebook, mx02 recasing). Casing is not content.
      * whitespace-insensitive substring  -- the LLM merges/splits spans around
        the same letters (tc03 นูพอยเตอร์->NullPointerException vs a "null pointer
        exception" split; branch/main glued or spaced). We match on the
        space-stripped candidate so either grouping survives.
      * >=4-char single-edit respelling  -- one groq generation respelled
        Font->Front (mx14). A >=4-char span reappearing within edit distance 1 is
        a benign typo-fix, not a loss. Kept deliberately narrow: shorter spans
        (UI->UX) and larger edits (a real substitution Grafana->Kibana, an
        outright drop, or Latin translated back to Thai) still fire.
      * ASR English repair (opt-in) -- non-protected >=4-char spans reappearing
        as a sound-alike cand span within edit distance 3 (League→leak,
        cost→cause). Only enabled when the candidate also shows Latin-gain, so
        a lone server→sorter still fires.
    """
    cand_low = cand.lower()
    cand_nows = re.sub(r"\s+", "", cand_low)
    cand_spans = _LATIN_SPAN_RE.findall(cand_low)
    lost = []
    for s in _LATIN_SPAN_RE.findall(dict_text):
        sl = s.lower()  # a span never contains whitespace
        if sl in cand_nows:
            continue
        if len(sl) >= 4 and any(_within_one_edit(sl, t) for t in cand_spans):
            continue
        if allow_asr_repair and _is_asr_english_repair(sl, cand_spans):
            continue
        lost.append(s)
    return lost


# --------------------------------------------------------------------------- #
# R2 — Thai-content divergence clamp (flag editDist->dict)
# --------------------------------------------------------------------------- #
# The token-count clamp only catches length changes; it misses same-length
# rewrites where the LLM replaces genuine Thai content -- the historical
# blanket-hallucination class (th05: "เรื่องนี้ต้องรีบตัดสินใจก่อนสิ้นสัปดาห์ ไม่งั้นจะไม่ทัน"
# -> "เราต้อง approve ก่อน deadline ไม่งั้นจะไม่ได้ deploy ก่อนสิ้นเดือน" -- same rough length,
# meaning mangled, English injected into pure Thai). Naive char Levenshtein
# false-fires on the pipeline's best work (แอคคูแลซี่->accuracy is a huge edit),
# so we anchor on real Thai *words* instead, with two signals:
#
#   (a) LOST long content -- real Thai words (pythainlp thai_words) of >= 5 code
#       points in dict_text that vanish (not even a substring) from the
#       candidate. Genuine content words are long (ตัดสินใจ, สัปดาห์, เรื่อง);
#       transliteration syllables the LLM legitimately converts to Latin are
#       short. Even naturalized loans that ARE real words and DO get
#       de-transliterated (ซิงค์->sync, ฟอนต์->font -- both 5 code points) top out
#       at 2 lost per good generation (mx14, tc04). th05 loses 3
#       (ตัดสินใจ, สัปดาห์, เรื่อง) -> fires.
#   (b) INVENTED content -- real Thai words in the candidate that are absent (not
#       even a substring) from dict_text. A pure de-transliteration only REMOVES
#       Thai; it never invents it. Good generations add <= 4 (messy
#       re-segmentation, e.g. mlx tc02); the blanket hallucinations inject >= 6.
#
# Thresholds ( >=5 length, >=3 lost, >=6 invented ) are the zero-false-positive
# frontier on the good data (good maxima observed: 2 lost, 4 invented). th05 is
# a deliberately subtle case sitting right at that frontier and is caught by (a).
# Signal (b) is defence-in-depth: R1 already fails a pure-Thai candidate that
# dropped Latin, so (b) matters for the "Latin preserved, Thai body rewritten"
# case. Order R1-before-R2 keeps the cheaper regex check first (R3).
_R2_MIN_WORD_LEN = 5
_R2_LOST_THRESH = 3
_R2_INVENT_THRESH = 6


def _real_thai_words(text: str) -> list[str]:
    """newmm tokens that contain Thai script AND are real Thai words."""
    return [t for t in word_tokenize(text, engine="newmm", keep_whitespace=False)
            if _THAI_RE.search(t) and t in _THAI_WORDS]


def _thai_divergence(dict_text: str, cand: str) -> tuple[int, int]:
    """(lost_long_content, invented_content) between dict_text and candidate."""
    cand_nows = re.sub(r"\s+", "", cand)
    lost = sum(1 for t in _real_thai_words(dict_text)
               if len(t) >= _R2_MIN_WORD_LEN and t not in cand_nows)
    dict_nows = re.sub(r"\s+", "", dict_text)
    invented = sum(1 for t in _real_thai_words(cand) if t not in dict_nows)
    return lost, invented


def _latin_letter_count(text: str) -> int:
    return sum(1 for ch in text if ("A" <= ch <= "Z") or ("a" <= ch <= "z"))


def _latin_gain(dict_text: str, cand: str) -> bool:
    """True when cand adds Latin jargon vs dict_text (de-transliteration signal).

    Dense Thai-syllable soup collapsing into a few English terms shrinks the
    newmm token count below the 0.6 clamp even when the restore is correct.
    Latin-span / letter gain is the generic signal that this is restoration,
    not content deletion. Truncations that drop English already present do
    NOT qualify (span/letter counts fall).
    """
    d_spans = _LATIN_SPAN_RE.findall(dict_text)
    c_spans = _LATIN_SPAN_RE.findall(cand)
    d_letters = _latin_letter_count(dict_text)
    c_letters = _latin_letter_count(cand)
    if len(c_spans) > len(d_spans) and c_letters > d_letters:
        return True
    # Same span count but clearly more Latin (e.g. longer restored compounds).
    return c_letters >= d_letters + 8 and len(c_spans) >= len(d_spans)


# English tokens that almost always mean the LLM translated Thai content words
# (ใช้→use, ส่ง→send). Keep this list NARROW: do NOT include tech loan targets
# the dictionary/LLM may legitimately restore (set/check/file/run/open/…).
_TRANSLATION_GLOSS = frozenset({
    "use", "send", "manage", "order", "call", "please", "company",
    "through", "instead", "will", "faster", "help", "want", "need",
    "ask", "tell", "let",
})


def _invented_translation_gloss(dict_text: str, cand: str) -> list[str]:
    """Latin tokens in cand that look like translated Thai, not restored jargon."""
    have = {s.lower() for s in _LATIN_SPAN_RE.findall(dict_text)}
    return [s for s in _LATIN_SPAN_RE.findall(cand)
            if s.lower() in _TRANSLATION_GLOSS and s.lower() not in have]


def _guardrail(dict_text: str, gen: str) -> tuple[str, str]:
    """Sanitize the raw generation; fall back to dict_text on suspicious output.

    Checks run cheapest/grossest first (W2-T2): strip -> empty -> token clamp
    (both measured against dict_text, the LLM INPUT) -> R1 protected spans ->
    R2 Thai-content divergence. Any trip returns dict_text (deterministic fixes
    survive; the LLM output is discarded).

    tooShort exception: when the candidate shows clear Latin-gain vs dict_text,
    skip the 0.6 token-count floor so legitimate multi-term de-transliteration
    is not discarded; R1/R2 still run and catch real hallucinations.

    Translation gloss: rejecting newly introduced English function/content words
    (use/send/manage/…) that were not in dict_text — classic Thai→English
    translation failures that R2 misses when the lost Thai verbs are short.
    """
    c = _strip_out(gen)
    if not c:
        return dict_text, "empty->dict"
    rt = metrics.tokenize(metrics.normalize(dict_text), "newmm")
    ct = metrics.tokenize(metrics.normalize(c), "newmm")
    if len(ct) < 0.6 * len(rt) and not _latin_gain(dict_text, c):
        return dict_text, "tooShort->dict"
    if len(ct) > 1.6 * len(rt):
        return dict_text, "tooLong->dict"
    # R1: with Latin-gain, allow ASR English near-miss repairs (League→leak);
    # without Latin-gain, keep strict protected-span survival.
    allow_repair = _latin_gain(dict_text, c)
    if _lost_spans(dict_text, c, allow_asr_repair=allow_repair):
        return dict_text, "spanLoss->dict"
    lost, invented = _thai_divergence(dict_text, c)  # R2
    if lost >= _R2_LOST_THRESH or invented >= _R2_INVENT_THRESH:
        return dict_text, "editDist->dict"
    if _invented_translation_gloss(dict_text, c):
        return dict_text, "translate->dict"
    return c, "ok"


# --------------------------------------------------------------------------- #
# Result + public API
# --------------------------------------------------------------------------- #
@dataclass
class CleanResult:
    text: str                    # final cleaned text
    raw: str                     # original input
    dict_text: str               # after apply_dictionary
    dict_hits: int               # deterministic replacements performed
    llm_ran: bool                # did the LLM pass run?
    gate_reason: str             # no-thai / clean-thai / dict-hit / suspect-tokens / dict-hit+suspect-tokens
    vocab_fired: int             # phonetic vocab corrections applied (post-dictionary)
    llm_raw_gen: str | None      # raw generation (None if LLM skipped)
    guardrail_flag: str          # ok / empty->dict / tooShort->dict / tooLong->dict / spanLoss->dict / editDist->dict / skipped
    t_dict: float                # seconds in apply_dictionary
    t_gate: float                # seconds in the gate
    t_llm: float                 # seconds in generate() (0.0 if skipped; excludes model load)
    t_total: float               # t_dict + t_gate + t_llm (excludes model load)
    suspect_tokens: list[str] = field(default_factory=list)


def clean_ex(text: str, vocab: "list[str] | None" = None) -> CleanResult:
    """Full pipeline with a per-stage trace. See module docstring.

    `vocab` (the user's custom-vocabulary terms, if any) drives a deterministic
    phonetic correction PRE-GATE: a rare term Whisper wrote as a Thai-script
    garble is snapped back to the user's own registered spelling (แคฟฟาร์->Kafka)
    before the LLM can invent a wrong one. Corrections count as dict hits so the
    gate treats the utterance as proven code-switching. See phonetic.py."""
    t0 = time.perf_counter()
    dict_text, dict_hits = apply_dictionary(text)
    vocab_fired = 0
    hints: list[str] = []
    if vocab:
        dict_text, vocab_fired, vsubs = correct_with_vocab(dict_text, vocab)
        # Only letter-changing vocab snaps prove code-switching for the gate.
        # Pure case/canonical Latin (GRPC→gRPC) must still apply to the text, but
        # must NOT force the LLM — otherwise clean English+Thai gets rewritten.
        letter_changing = sum(1 for src, dst in vsubs if src.lower() != dst.lower())
        dict_hits += letter_changing
        hints = vocab_hint(dict_text, vocab)  # mangled-but-plausible terms -> LLM hint
    t_dict = time.perf_counter() - t0

    t0 = time.perf_counter()
    run_llm, gate_reason, susp = _gate(dict_text, dict_hits)
    if hints and not run_llm:
        # a plausible mangled vocab term is present -> the LLM is worth running
        run_llm, gate_reason = True, (f"{gate_reason}+vocab-hint" if gate_reason else "vocab-hint")
    if os.environ.get("OLIV_CLEANUP_NO_LLM"):
        run_llm, gate_reason = False, "no-llm-ablation"  # eval ablation: deterministic stack only
    t_gate = time.perf_counter() - t0

    llm_raw_gen: str | None = None
    t_llm = 0.0
    if not run_llm:
        final, flag = dict_text, "skipped"
    else:
        _ensure_model()  # load OUTSIDE the timed region so LOAD_TIME is excluded
        t0 = time.perf_counter()
        llm_raw_gen = _llm_generate(dict_text, hints)
        t_llm = time.perf_counter() - t0
        final, flag = _guardrail(dict_text, llm_raw_gen)

    # Deterministic final pass: strip Pathumma's Thai word-segmentation spaces
    # on BOTH paths -- the gate-skip path (pure Thai, most affected: the LLM
    # never runs to re-flow it) and the LLM path (belt-and-suspenders for any
    # residual, e.g. mx11 "แก้ว หนึ่ง"). Whitespace-only; never alters a word.
    final = normalize_thai_spacing(final)

    # Final deterministic pass: canonical casing for known tech terms (Latin-only,
    # meaning-preserving). Runs on BOTH paths -- LLM output and the guardrail
    # fallback (dict_text) -- so a lowercase brand from either source is fixed.
    final = apply_canonical_casing(final)

    return CleanResult(
        text=final, raw=text, dict_text=dict_text, dict_hits=dict_hits,
        llm_ran=run_llm, gate_reason=gate_reason, vocab_fired=vocab_fired,
        llm_raw_gen=llm_raw_gen,
        guardrail_flag=flag, t_dict=t_dict, t_gate=t_gate, t_llm=t_llm,
        t_total=t_dict + t_gate + t_llm, suspect_tokens=susp,
    )


def clean(text: str) -> str:
    """The composed pipeline: raw ASR text -> cleaned text."""
    return clean_ex(text).text


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def _fmt_ms(sec: float) -> str:
    return f"{sec * 1000:7.1f}ms"


def _print_trace(r: CleanResult) -> None:
    print(f"  RAW  : {r.raw}")
    print(f"  DICT : {r.dict_text}    (hits={r.dict_hits})")
    gate = f"run_llm={r.llm_ran}  reason={r.gate_reason}"
    if r.suspect_tokens:
        gate += f"  suspect={r.suspect_tokens}"
    print(f"  GATE : {gate}")
    if r.llm_ran:
        print(f"  LLM  : {r.llm_raw_gen!r}")
    else:
        print(f"  LLM  : (skipped)")
    print(f"  FINAL: {r.text}    [guardrail={r.guardrail_flag}]")
    print(f"  TIME : dict={_fmt_ms(r.t_dict)}  gate={_fmt_ms(r.t_gate)}  "
          f"llm={_fmt_ms(r.t_llm)}  total={_fmt_ms(r.t_total)}")


DEMO_CASES = [
    ("pure-thai (must gate-skip + pass through byte-identical)",
     "วันนี้ประชุมทีมตอนบ่ายสองนะครับ อย่าลืมเตรียมเอกสารให้พร้อม"),
    ("pure-english (must gate-skip: no-thai)",
     "can you summarize the main points from the meeting please"),
    ("dict-hit -> LLM (deterministic fixes then a validating LLM pass)",
     "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา"),
    ("dict-hit + residual the dict missed (tc01: พอร์ต/ล็อก/หน้า stay Thai)",
     "รีสตาร์ทคิวเบอร์เน็ตพอร์ตแล้วเช็คล็อกในกราฟาหน้าแดชบอร์ดอีกที"),
    ("mixed residual #1 (naturalized loans ARE in thai_words -> safe-fail skip)",
     "เดี๋ยวซิงค์กับทีม design เรื่อง UI ก่อน แล้วค่อย implement ฟอนต์เอ็น"),
    ("mixed residual #2 (naturalized loans -> safe-fail skip)",
     "ตอนนี้ budget เหลือน้อยต้องคัดคอร์สบางอย่าง service ที่ไม่ค่อยได้ใช้"),
    ("garbled mixed (suspect-tokens -> LLM fixes what the dict couldn't)",
     "เดี๋ยว โรว์ แบ็ค ดีพอยท์ เม้นท์ ก่อน ค่อย debug ใน สเตจิ่ง"),
    ("mono-Thai, OOV name ปัณณวิชญ์ (accepted false-trigger; LLM runs, returns unchanged)",
     "นัดประชุมกับคุณปัณณวิชญ์ตอนบ่ายสอง"),
]


def _run_demo() -> None:
    print("=" * 78)
    print("PIPELINE DEMO — end-to-end (loads Gemma 4 on the first LLM-bound case)")
    print("=" * 78)
    for i, (label, text) in enumerate(DEMO_CASES, 1):
        print(f"\n[{i}] {label}")
        r = clean_ex(text)
        _print_trace(r)
        if i == 1:
            identical = r.text == text
            print(f"  CHECK: byte-identical passthrough={identical}, llm_ran={r.llm_ran}")
    print("\n" + "-" * 78)
    print(f"LOAD_TIME (model load, excluded from per-call timings): "
          f"{LOAD_TIME:.1f}s" if LOAD_TIME is not None else "LOAD_TIME: (model never loaded)")


def _run_single(text: str) -> None:
    r = clean_ex(text)
    _print_trace(r)
    if LOAD_TIME is not None:
        print(f"  (LOAD_TIME={LOAD_TIME:.1f}s, excluded from timings)")


# ---- --gate-stats : dict+gate preview over the benchmark, NO model load ---- #
_GATE_STATS_SOURCES = [
    ("pathumma", "results_local.json"),
    ("groq-large-v3", "results_groq.json"),
]
_BUCKETS = ["english_only", "mixed", "technical", "proper_nouns", "thai_only"]


def _run_gate_stats() -> None:
    import json

    print("=" * 78)
    print("GATE STATS — dict+gate only (NO model). skip = LLM would be bypassed.")
    print("Records: lang=='auto', engine in {pathumma (local), groq-large-v3 (groq)}")
    print("=" * 78)

    grand_n = grand_skip = 0
    for engine, fn in _GATE_STATS_SOURCES:
        recs = [r for r in json.load(open(fn, encoding="utf-8"))
                if r.get("engine") == engine and r.get("lang") == "auto"]
        by_bucket: dict[str, list[int]] = {}  # bucket -> [n, skipped]
        eng_n = eng_skip = 0
        for r in recs:
            dict_text, dict_hits = apply_dictionary(r["hypothesis"])
            run_llm, _reason, _susp = _gate(dict_text, dict_hits)
            skipped = 0 if run_llm else 1
            b = r.get("bucket", "?")
            by_bucket.setdefault(b, [0, 0])
            by_bucket[b][0] += 1
            by_bucket[b][1] += skipped
            eng_n += 1
            eng_skip += skipped
        grand_n += eng_n
        grand_skip += eng_skip

        print(f"\nengine: {engine}   ({fn}, lang=auto)   n={eng_n}")
        print(f"  {'bucket':<14}{'n':>4}{'skipped':>9}{'skip%':>8}")
        for b in _BUCKETS:
            if b not in by_bucket:
                continue
            n, sk = by_bucket[b]
            print(f"  {b:<14}{n:>4}{sk:>9}{(100.0 * sk / n if n else 0):>7.1f}%")
        for b in by_bucket:  # any bucket not in the canonical list
            if b in _BUCKETS:
                continue
            n, sk = by_bucket[b]
            print(f"  {b:<14}{n:>4}{sk:>9}{(100.0 * sk / n if n else 0):>7.1f}%")
        print(f"  {'ALL':<14}{eng_n:>4}{eng_skip:>9}"
              f"{(100.0 * eng_skip / eng_n if eng_n else 0):>7.1f}%")

    print(f"\nOVERALL (both engines): n={grand_n}  skipped={grand_skip}  "
          f"skip%={100.0 * grand_skip / grand_n if grand_n else 0:.1f}%")


def _main(argv: list[str]) -> None:
    if not argv:
        print("usage:")
        print('  python pipeline.py "ข้อความ"     # trace one utterance through the pipeline')
        print("  python pipeline.py --demo         # built-in end-to-end demo (loads the model)")
        print("  python pipeline.py --gate-stats   # dict+gate skip-rate preview (no model)")
        return
    if argv[0] == "--demo":
        _run_demo()
    elif argv[0] == "--gate-stats":
        _run_gate_stats()
    else:
        _run_single(" ".join(argv))


if __name__ == "__main__":
    _main(sys.argv[1:])
