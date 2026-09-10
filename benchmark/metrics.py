"""Thai-aware STT metrics for the OLIV Phase 0 benchmark.

Why not raw WER? Thai has no spaces between words, so splitting on whitespace
(the usual WER tokenization) is meaningless. This module therefore reports:

  - CER            : character error rate on the space-stripped, normalized text
  - WER (newmm)    : token error rate after PyThaiNLP `newmm` word segmentation
  - WER (deepcut)  : same, using `deepcut` — the tokenizer Thonburian reports with
                     (optional: only runs if the `deepcut` package is importable)
  - keyword recall : fraction of expected proper-nouns / technical terms present

Everything is scored *after* a fixed normalization pass
so casing/punctuation/spacing noise doesn't distort the numbers.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass


# --------------------------------------------------------------------------- #
# Normalization
# --------------------------------------------------------------------------- #
def normalize(text: str, *, lower: bool = True) -> str:
    """NFC + optional lowercase + strip punctuation/symbols + collapse spaces.

    Thai letters, tone marks and digits are preserved; Unicode punctuation (P*)
    and symbols (S*) are replaced with a space so they never count as errors.
    """
    text = unicodedata.normalize("NFC", text or "")
    if lower:
        text = text.lower()
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        out.append(" " if cat[0] in ("P", "S") else ch)
    text = "".join(out)
    return re.sub(r"\s+", " ", text).strip()


def _nospace(text: str) -> str:
    return re.sub(r"\s+", "", text)


# --------------------------------------------------------------------------- #
# Edit distance (pure Python — no jiwer/Levenshtein dependency to break)
# --------------------------------------------------------------------------- #
def _levenshtein(a: list, b: list) -> int:
    n, m = len(a), len(b)
    if n == 0:
        return m
    if m == 0:
        return n
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        ai = a[i - 1]
        for j in range(1, m + 1):
            cost = 0 if ai == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        prev = cur
    return prev[m]


# --------------------------------------------------------------------------- #
# Tokenization
# --------------------------------------------------------------------------- #
_DEEPCUT_OK: bool | None = None


def _deepcut_available() -> bool:
    global _DEEPCUT_OK
    if _DEEPCUT_OK is None:
        try:
            import deepcut  # noqa: F401

            _DEEPCUT_OK = True
        except Exception:
            _DEEPCUT_OK = False
    return _DEEPCUT_OK


def tokenize(text: str, engine: str) -> list[str]:
    """Word-segment mixed Thai/English text with a PyThaiNLP engine.

    `newmm` ships with PyThaiNLP (no extra install). `deepcut` needs the
    `deepcut` package (TensorFlow) — callers should gate on `deepcut_available`.
    English runs are kept as whole tokens by both engines.
    """
    from pythainlp.tokenize import word_tokenize

    toks = word_tokenize(text, engine=engine, keep_whitespace=False)
    return [t for t in toks if t.strip()]


# --------------------------------------------------------------------------- #
# Scoring
# --------------------------------------------------------------------------- #
@dataclass
class Score:
    cer: float
    wer_newmm: float
    wer_deepcut: float | None      # None when deepcut isn't installed
    keyword_recall: float | None   # None when the clip declares no keywords
    ref_chars: int
    ref_tokens: int


def keyword_recall(hyp: str, keywords: list[str]) -> float | None:
    if not keywords:
        return None
    h = _nospace(normalize(hyp))
    hit = sum(1 for k in keywords if _nospace(normalize(k)) in h)
    return hit / len(keywords)


def score(reference: str, hypothesis: str, keywords: list[str] | None = None) -> Score:
    ref_n, hyp_n = normalize(reference), normalize(hypothesis)

    # CER — character level on space-stripped text (standard for Thai)
    rc, hc = list(_nospace(ref_n)), list(_nospace(hyp_n))
    cer = _levenshtein(rc, hc) / max(1, len(rc))

    # WER (newmm)
    rt, ht = tokenize(ref_n, "newmm"), tokenize(hyp_n, "newmm")
    wer_newmm = _levenshtein(rt, ht) / max(1, len(rt))

    # WER (deepcut) — optional
    wer_deepcut = None
    if _deepcut_available():
        rtd, htd = tokenize(ref_n, "deepcut"), tokenize(hyp_n, "deepcut")
        wer_deepcut = _levenshtein(rtd, htd) / max(1, len(rtd))

    return Score(
        cer=cer,
        wer_newmm=wer_newmm,
        wer_deepcut=wer_deepcut,
        keyword_recall=keyword_recall(hypothesis, keywords or []),
        ref_chars=len(rc),
        ref_tokens=len(rt),
    )


def deepcut_available() -> bool:
    return _deepcut_available()
