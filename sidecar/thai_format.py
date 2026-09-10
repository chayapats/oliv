"""Deterministic Thai-formatting post-pass for OLIV dictation cleanup.

Two transforms applied to the FINAL cleaned text, in this order (D6 -- reduplication
FIRST, so a numeral-double is not turned into ``ๆ`` before the number pass sees it):

  (A) Reduplication -- adjacent identical real Thai-word tokens collapse to
      ``word + "ๆ"``:  มากมาก -> มากๆ ; ตลอดตลอด -> ตลอดๆ ; runs of 3+ collapse to a
      single ``ๆ`` (มากมากมาก -> มากๆ).  A token only collapses when it is a REAL Thai
      word (in ``pythainlp`` ``thai_words()``) so garbles are left alone, and a small
      stoplist of grammatical particles is excluded so a stutter is not made into ``ๆ``
      (ไม่ไม่ / ที่ที่ stay untouched).

  (B) Numbers -> Arabic -- MAXIMAL runs of numeral tokens are ``words_to_num``-ed and
      converted ONLY when the value is >= 10, so lone 1-9 words stay Thai (ขอสองแก้ว,
      ครั้งหนึ่ง, บ่ายสอง stay natural):  สี่สิบห้า -> 45 ; เก้าสิบเก้า -> 99.  A run with
      one or more ``จุด`` flanked by numerals is a decimal/version expression -- an
      integer numeral run followed by ``(จุด, numeral-run)`` groups.  The integer part
      is a CARDINAL (สี่สิบห้า -> 45); each ``จุด``-group renders per its OWN tokens --
      bare unit words (0-9, incl. ศูนย์) go DIGIT-BY-DIGIT with zeros preserved, but a
      group carrying a place-value word (สิบ/ร้อย/..) is a spoken CARDINAL -- and the
      whole expression is threshold-exempt:  สองจุดห้า -> 2.5 ; สองจุดสี่ห้า -> 2.45 ;
      สองจุดสี่สิบห้า -> 2.45 ; สองจุดยี่สิบ -> 2.20 ; หนึ่งจุดศูนย์ศูนย์หนึ่ง -> 1.001 ;
      สองจุดสี่จุดหนึ่ง -> 2.4.1 ; สี่สิบห้าจุดห้า -> 45.5.
      Hidden numeral syllables (สามารถ / เก้าอี้ / ห้าม) are untouched because
      ``words_to_num`` fails on the token.  The pass is TOTAL: a pathological numeral
      run (STT loop) is left verbatim rather than raising / dropping the transcript.

Public API::

    apply_thai_format(text: str) -> tuple[str, int]

Returns ``(formatted_text, n_changes)`` where ``n_changes`` is the number of
reduplication collapses plus the number of converted number runs.  Returns
``(text, 0)`` on the Thai-presence short-circuit.

Known limitation (accepted -- see the pinned test): a decimal whose leading digit-word
is glued by newmm into a preceding Thai word (e.g. ``ที่สอง|จุด|ห้า``) is missed.  The
common clean form (``เวอร์ชัน|สอง|จุด|สี่|จุด|หนึ่ง``) tokenizes correctly and works.

Latency posture (every rule enforced here):
  1. Toggle OFF => zero work -- the server never calls this module.
  2. Thai-presence short-circuit -- a module-level precompiled regex for [฀-๿]; no
     match => return ``(text, 0)`` BEFORE any tokenize.
  3. Single tokenization -- ``word_tokenize(text, engine="newmm", keep_whitespace=True)``
     runs EXACTLY ONCE per call; the token list is shared by both sub-passes.
  4. Module-level constants built at import -- precompiled regex, one cached
     ``frozenset(thai_words())``, the stoplist frozenset, and a numeral char superset
     used as a cheap pre-check so ``words_to_num``'s try/except is only attempted on
     plausible numeral tokens.  No per-call imports anywhere.
  5. Rebuild by pure concatenation so whitespace and "\\n" separators (from format
     commands) are preserved byte-for-byte.
"""

from __future__ import annotations

import re

from pythainlp.corpus import thai_words
from pythainlp.tokenize import word_tokenize
from pythainlp.util import words_to_num

# --------------------------------------------------------------------------- #
# Module-level constants (built once at import; the sidecar already imports
# pythainlp at startup, so this adds no cold-path cost to a dictation).
# --------------------------------------------------------------------------- #

# Thai Unicode block U+0E00-U+0E7F -- used to short-circuit non-Thai text.
_THAI_RE = re.compile(r"[฀-๿]")

# The real-Thai-word gate for reduplication so garbles are never collapsed.
_THAI_WORDS = frozenset(thai_words())

# D5 stoplist: grammatical particles excluded from reduplication so a stutter of
# one of these is not turned into ``ๆ``.
_STOPLIST = frozenset({"ไม่", "ก็", "ที่", "จะ", "นะ", "ค่ะ", "ครับ", "คะ"})

# Numeral component words.  Their characters form a SUPERSET of every character
# that can appear in a ``words_to_num``-parseable token, so the char pre-check
# below never filters out a valid numeral run (no false negatives); ``_num`` stays
# the authority and resolves the rare false positive (e.g. เก้าอี้).
_NUMERAL_WORDS = (
    "ศูนย์", "หนึ่ง", "สอง", "ยี่", "สาม", "สี่", "ห้า", "หก", "เจ็ด", "แปด",
    "เก้า", "เอ็ด", "สิบ", "ร้อย", "พัน", "หมื่น", "แสน", "ล้าน",
)
_NUMERAL_CHARS = frozenset("".join(_NUMERAL_WORDS))

_DOT = "จุด"            # spoken decimal / version separator
_MAI_YAMOK = "ๆ"        # Thai repetition mark

# Totality cap for the number pass: a numeral run longer than this is left verbatim
# rather than converted. A pathological STT loop (hundreds of numeral words) would
# otherwise build a value whose str() trips Python's int->str digit limit (>4300
# digits) and RAISES -- which at the sidecar boundary would turn the whole dictate
# into ok:false and lose the utterance. A real dictated number is far under this (a
# full 9-figure cardinal is ~17 numeral tokens; a version string is a handful).
_MAX_NUM_RUN = 40


# --------------------------------------------------------------------------- #
# Pure helpers (importable for tests).
# --------------------------------------------------------------------------- #
def _num(tok: str):
    """``words_to_num(tok)`` or ``None`` if ``tok`` is not a numeral word.

    This try/except is the AUTHORITY on whether a token is a spoken number; the
    char pre-check in ``_numeral_value`` is only a fast filter in front of it.
    """
    try:
        return words_to_num(tok)
    except Exception:
        return None


def _numeral_value(tok: str):
    """Value of a numeral token, or ``None`` -- cheap char filter, then ``_num``.

    The char filter (all characters drawn from numeral words) is a strict superset
    of what ``words_to_num`` accepts, so a real numeral is never dropped here; it
    only spares ``_num`` from being attempted on obviously non-numeral tokens.
    """
    if not tok:
        return None
    for ch in tok:
        if ch not in _NUMERAL_CHARS:
            return None
    return _num(tok)


def _render_decimal_segment(seg_tokens: list[str]):
    """Render ONE ``จุด``-delimited fractional segment -> ``str`` or ``None``.

    A segment is the numeral tokens between two ``จุด`` (or after the last one).
    How Thai disambiguates a spoken fraction decides the render mode:

      (1) EVERY token is a bare unit word -- ``_num(tok)`` is an int in 0..9 (incl.
          ศูนย์ -> 0) -- so there is no place-value word: render DIGIT-BY-DIGIT,
          zeros significant:  [สี่,ห้า] -> "45" ; [ศูนย์,ศูนย์,หนึ่ง] -> "001".
      (2) ELSE (a place-value word -- สิบ/ร้อย/.. -- is present) the segment is a
          spoken CARDINAL: value of the joined tokens as ``str`` -- [สี่,สิบห้า] ->
          _num("สี่สิบห้า")=45 -> "45" ; [ยี่สิบ] -> 20 -> "20".
      (3) ELSE (the cardinal parse fails AND the tokens are not all single-digit)
          return ``None`` so the caller leaves the WHOLE number expression unchanged.
    """
    vals = [_num(t) for t in seg_tokens]
    if all(v is not None and 0 <= v <= 9 for v in vals):
        return "".join(str(v) for v in vals)          # (1) digit-by-digit, zeros kept
    cardinal = _num("".join(seg_tokens))
    if cardinal is not None:
        return str(cardinal)                          # (2) spoken cardinal
    return None                                       # (3) unparseable -> caller verbatim


def _collapse_reduplication(tokens: list[str]) -> tuple[list[str], int]:
    """Pass A -- collapse adjacent identical real-word tokens to ``word + "ๆ"``.

    A maximal run of the SAME token string, length >= 2, whose token is a real
    Thai word, not in the stoplist, and NOT itself a numeral word, becomes a single
    ``token + "ๆ"`` (3+ still collapse to a single ``ๆ``).  Everything else --
    garbles, stoplist particles, numeral words, whitespace, lone tokens -- passes
    through unchanged.  Returns the rewritten token list and the number of collapses.

    The numeral-word exclusion (``_num(tok) is None``) is essential: reduplication
    runs FIRST (D6), so a repeated numeral word (ศูนย์ศูนย์, ห้าห้า) must NOT be turned
    into ``ๆ`` here -- it has to reach the number pass intact so a digit-by-digit
    decimal like หนึ่งจุดศูนย์ศูนย์หนึ่ง -> 1.001 can form.
    """
    out: list[str] = []
    changes = 0
    i = 0
    n = len(tokens)
    while i < n:
        tok = tokens[i]
        j = i + 1
        while j < n and tokens[j] == tok:
            j += 1
        if (j - i) >= 2 and tok in _THAI_WORDS and tok not in _STOPLIST \
                and _num(tok) is None:
            # If a literal ``ๆ`` already follows the run (STT emitted "มากมากๆ"),
            # collapse to a single bare token and let that existing mark pass
            # through, so we never double the mark ("มากๆๆ").
            if j < n and tokens[j] == _MAI_YAMOK:
                out.append(tok)
            else:
                out.append(tok + _MAI_YAMOK)
            changes += 1
        else:
            out.extend(tokens[i:j])
        i = j
    return out, changes


def _convert_numbers(tokens: list[str]) -> tuple[list[str], int]:
    """Pass B -- rewrite maximal numeral runs to Arabic digits.

    A run is a maximal contiguous slice of numeral tokens, optionally with ``จุด``
    tokens flanked by numerals on both sides.  A run WITHOUT a ``จุด`` is joined and
    ``words_to_num``-ed, converted only when the value is >= 10.  A run WITH one or
    more ``จุด`` is a decimal/version expression: an integer numeral run followed by
    one or more ``(จุด, numeral-run)`` groups.  The integer part is a CARDINAL
    (joined + ``words_to_num``-ed: สี่สิบห้า -> 45); each ``จุด``-group is rendered by
    ``_render_decimal_segment`` per its OWN tokens -- bare unit words (0-9) go
    DIGIT-BY-DIGIT with zeros preserved ([สี่,ห้า] -> "45" ; [ศูนย์,ศูนย์,หนึ่ง] ->
    "001"), while a group carrying a place-value word is a spoken CARDINAL
    ([สี่,สิบห้า] -> "45" ; [ยี่สิบ] -> "20").  Any ``จุด`` makes the whole expression
    convert (threshold-exempt); an unparseable segment leaves the run verbatim.
    Non-numeral tokens pass through verbatim.  Returns the rewritten token list and
    the number of converted runs.

    Totality (never lose the transcript): a run longer than ``_MAX_NUM_RUN`` is left
    verbatim, and every value->string rendering is wrapped so a failure (e.g. Python's
    int->str digit cap on a giant value) degrades the run to its original Thai tokens
    rather than raising.
    """
    n = len(tokens)
    values = [_numeral_value(t) for t in tokens]      # value or None, one _num per token
    is_num = [v is not None for v in values]
    is_dot = [t == _DOT for t in tokens]

    out: list[str] = []
    changes = 0
    i = 0
    while i < n:
        if not is_num[i]:
            out.append(tokens[i])
            i += 1
            continue

        # Extend a maximal run: numerals, and dots flanked by numerals on both sides.
        end = i + 1
        while end < n:
            if is_num[end]:
                end += 1
            elif is_dot[end] and (end + 1) < n and is_num[end + 1]:
                end += 1
            else:
                break

        run = tokens[i:end]

        # Totality cap: a human never dictates a numeral run this long, but STT can
        # emit a pathological one. Converting it would force a giant words_to_num
        # value whose str() can trip Python's int->str digit limit and RAISE -- which
        # would lose the whole utterance. Leave an over-long run verbatim.
        if (end - i) > _MAX_NUM_RUN:
            out.extend(run)
            i = end
            continue

        has_dot = any(is_dot[k] for k in range(i, end))

        if has_dot:
            # Split into dot-delimited segments of token INDICES; each is >= 1 numeral
            # token (a dot is only in the run when flanked by numerals on both sides).
            segments: list[list[int]] = []
            seg: list[int] = []
            for k in range(i, end):
                if is_dot[k]:
                    segments.append(seg)
                    seg = []
                else:
                    seg.append(k)
            segments.append(seg)

            int_seg, frac_segs = segments[0], segments[1:]
            int_val = _num("".join(tokens[k] for k in int_seg))   # integer = cardinal
            if int_val is not None:
                try:
                    # Each จุด-segment renders per its OWN tokens: bare unit words go
                    # digit-by-digit, a place-value segment is a spoken cardinal, and
                    # an unparseable segment (None) forces the whole run verbatim.
                    rendered = [_render_decimal_segment([tokens[k] for k in fs])
                                for fs in frac_segs]
                    if all(r is not None for r in rendered):
                        out.append(".".join([str(int_val), *rendered]))
                        changes += 1
                    else:                                         # a segment failed
                        out.extend(run)
                except Exception:                                 # never raise / drop
                    out.extend(run)
            else:                                                 # unparseable -> verbatim
                out.extend(run)
        else:
            val = _num("".join(run))
            if val is not None and val >= 10:
                try:
                    out.append(str(val))
                    changes += 1
                except Exception:                                 # int->str cap -> verbatim
                    out.extend(run)
            else:                                                 # lone 1-9 (or unparseable): keep
                out.extend(run)

        i = end
    return out, changes


# --------------------------------------------------------------------------- #
# Public API.
# --------------------------------------------------------------------------- #
def apply_thai_format(text: str) -> tuple[str, int]:
    """Apply the reduplication + number transforms to ``text``.

    Returns ``(formatted_text, n_changes)``; ``n_changes`` is reduplication
    collapses plus converted number runs.  Short-circuits to ``(text, 0)`` when
    the text contains no Thai character (no work, no tokenize).
    """
    if not text or not _THAI_RE.search(text):
        return text, 0

    # Single shared tokenization; keep_whitespace so spaces and "\n" survive.
    tokens = word_tokenize(text, engine="newmm", keep_whitespace=True)

    tokens, n_redup = _collapse_reduplication(tokens)   # A first (D6)
    tokens, n_num = _convert_numbers(tokens)            # B second

    return "".join(tokens), n_redup + n_num
