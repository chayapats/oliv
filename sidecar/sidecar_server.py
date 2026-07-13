"""OLIV sidecar (W3-T3) -- the ONE Python subprocess behind the Swift app.

Runs under sidecar/.venv (the W3-T0-proven unified environment: mlx-whisper +
mlx-lm 0.31.3 + transformers 5.0.0 + pythainlp), serving BOTH pipeline stages
that must be Python:

    STT      app/stt backends (pathumma-mlx primary, mlx-large-v3 fallback)
    cleanup  benchmark/pipeline.clean_ex (dict -> gate -> Gemma4 -> guardrails
             -> Thai-spacing normalization)

The Swift app (macos/, SidecarClient) spawns

    sidecar/.venv/bin/python sidecar/sidecar_server.py

once at launch and exchanges one JSON object per line. Protocol, stdout
discipline, and error philosophy are inherited from the proven
benchmark/cleanup_worker.py (W1-T6) -- see that file for the rationale; the
short version: fd 1 is re-pointed at stderr before any heavy import so no
library chatter can corrupt the protocol stream, and one bad request never
crashes the serve loop.

Protocol (line-oriented JSON; every request may carry "id", echoed back)
------------------------------------------------------------------------
  {"cmd": "ping"}
      -> {"ok": true, "pid": <int>}

  {"cmd": "warm", "engine": "pathumma-mlx", "cleanup": true}
      -> {"ok": true, "engine": ..., "t_stt_load": s, "t_cleanup_load": s}
      Loads the STT model and (if cleanup) Gemma-4 + one priming generation,
      so the first real dictate is warm. Both loads are lazy anyway -- warm
      just front-loads them at app launch instead of the first utterance.

  {"cmd": "dictate", "engine": "pathumma-mlx", "cleanup": true,
   "pcm_b64": "<base64 of float32-LE mono 16 kHz samples>",
   "remove_fillers": false,
   "replacements": {"spoken phrase": "replacement", ...},
   "vocabulary": ["Term", "ชื่อเฉพาะ", ...],   (or "initial_prompt": "...")
   "format_commands": false}
   -- or "wav_path": "/abs/path.wav" instead of pcm_b64 (tests / CLI) --
      -> {"ok": true, "raw": ..., "final": ..., "engine": ...,
          "t_stt": s, "t_cleanup": s, "llm_ran": bool, "gate_reason": ...,
          "guardrail_flag": ..., "dict_hits": int, "cleanup_error": null|str,
          "fillers_removed": int, "replacements_fired": int,
          "format_commands_fired": int}
      THE TRANSCRIPT IS NEVER LOST: a cleanup failure of any kind degrades to
      final == the pre-cleanup text with cleanup_error set (ok stays true -- the
      utterance succeeded). Only an STT failure yields ok:false.
      B3 custom vocabulary: `vocabulary` (a term list, joined into an
      initial_prompt) and/or an explicit `initial_prompt` bias the DECODE toward
      those words/spellings -- fixes misrecognized names/jargon at the source
      (absent => byte-identical to before).
      Pipeline order (all optional, all backward-compatible defaults):
        raw -> [remove_fillers?]  filler-word strip on the RAW text, BEFORE
                                  cleanup (default OFF here -- the CLIENT flips
                                  it on from Settings). `raw` stays the true raw.
            -> [format_commands?]  B4: split the pre-cleanup text on spoken
                                  formatting commands (new line / paragraph /
                                  bullet) so each segment is cleaned on its own
                                  and rejoined with the inserted break (default
                                  OFF; no command => single segment, unchanged).
            -> [cleanup?]         dict -> gate -> LLM -> guardrails -> spacing
                                  (per segment).
            -> [replacements?]    user snippets, a boundary-guarded pass per
                                  segment (apply_dictionary + re-normalized spacing).
      fillers_removed / replacements_fired / format_commands_fired count what
      each pass did (0 = off / nothing fired). dict_hits stays the built-in
      TRANSLIT count, distinct from the user replacements_fired.

  {"cmd": "clean", "text": "..."}
      -> same shape as cleanup_worker.py's clean reply (kept for tests and
         for a future text-only re-clean affordance).

  {"cmd": "download", "repos": ["org/repo", ...]}
      -> interim (0+ per repo, BEFORE the final reply, same "id"):
             {"id": N, "event": "progress", "repo": ..., "pct": <0-100 int>}
         final: {"id": N, "ok": true, "downloaded": [repo, ...]}
      snapshot_download()s each repo into HF_HOME (the .app's Application
      Support models dir, or the dev cache). Coarse per-repo progress is
      emitted on whole-percent changes only (byte-aggregate bar). A per-repo
      failure stops there and replies ok:false with the offending repo:
             {"id": N, "ok": false, "error": ..., "failed_repo": repo,
              "downloaded": [repos that finished first]}
      This is the first-run onboarding + Settings "Download" driver (W3-T4).

  {"cmd": "shutdown"} or EOF on stdin -> exit 0.

Layout resolution: the repo layout (this file in <root>/sidecar/) is the
default; the packaged .app overrides via the OLIV_ROOT env var, which the
W3-T4 build script points at the bundled Resources tree. Model downloads honor
HF_HOME (the .app sets it to Application Support) and force
HF_HUB_DISABLE_XET=1 (xet crawled at ~100 KB/s on real networks -- see the
2026-07-07 Session Log).
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import threading
import time

# --------------------------------------------------------------------------- #
# 1. sys.path: `import app.stt` needs the project root; `import pipeline`
#    needs benchmark/ (pipeline imports dictionary/prompts/metrics top-level).
# --------------------------------------------------------------------------- #
_ROOT = os.environ.get("OLIV_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
for _p in (_ROOT, os.path.join(_ROOT, "benchmark")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

# Downloads through the sidecar must never hit the xet slow path (Session Log
# 2026-07-07); harmless if already downloaded.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

# W7 STALL FIX: load cached weights OFFLINE by default. Otherwise huggingface_hub
# does a blocking network metadata (etag) check on EVERY model load even when the
# repo is fully cached; when HF is unreachable/slow that check hangs for MINUTES,
# which the app shows as "transcribing…" forever (measured: warm hung >180s vs
# 1.2s offline). A fully-local dictation app must never need the network to load
# already-downloaded weights. The `download` command is the one operation that
# legitimately needs the network, and flips this off for its snapshot_download
# calls via _set_hf_offline() (restored afterward).
os.environ.setdefault("HF_HUB_OFFLINE", "1")

# --------------------------------------------------------------------------- #
# 2. Protocol-channel split, BEFORE heavy imports (see cleanup_worker.py).
#    OLIV_SIDECAR_IMPORT_ONLY lets a hermetic test `import sidecar_server` to
#    reach the pure text-pass helpers (remove_fillers) WITHOUT hijacking the
#    importer's stdout -- the serve loop never sets it, so a launched server
#    still splits fds first thing (byte-identical to before). See main().
# --------------------------------------------------------------------------- #
if os.environ.get("OLIV_SIDECAR_IMPORT_ONLY"):
    _PROTO = sys.stdout
else:
    _proto_fd = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    _PROTO = os.fdopen(_proto_fd, "w", encoding="utf-8", buffering=1)

# The serve loop is single-threaded, but `download` progress lines are emitted
# from snapshot_download's worker threads (byte bars updated per file/thread),
# so guard the protocol channel with a lock to keep JSON lines from interleaving.
_PROTO_LOCK = threading.Lock()


def _reply(obj: dict) -> None:
    with _PROTO_LOCK:
        _PROTO.write(json.dumps(obj, ensure_ascii=False))
        _PROTO.write("\n")
        _PROTO.flush()


def _make_progress_tqdm(rid, repo: str):
    """A tqdm subclass that emits coarse `{"event": "progress"}` protocol lines
    as `repo` downloads, for the Swift client's onboarding/Settings progress bar.

    snapshot_download drives ONE shared byte-aggregate bar (unit "B", total =
    total bytes across files, n = bytes fetched) plus an outer file-count bar;
    both are instantiated from this class. We emit ONLY from the byte bar so the
    caller gets a single smooth 0-100 per repo, and only on whole-percent
    changes (coarse is fine). `disable` is forced off so `n` still advances with
    no TTY (headless sidecar); the visible bar renders to stderr (discarded),
    never the protocol fd. A fresh subclass per repo resets `_last_pct`."""
    from huggingface_hub.utils import tqdm as _hf_tqdm

    class _ProgressTqdm(_hf_tqdm):
        _last_pct = -1

        def __init__(self, *args, **kwargs):
            kwargs["disable"] = False
            kwargs.setdefault("file", sys.stderr)
            super().__init__(*args, **kwargs)

        def _emit(self) -> None:
            if getattr(self, "unit", None) != "B":
                return  # only the byte-aggregate bar; ignore the file-count bar
            total = self.total or 0
            if total <= 0:
                return
            pct = int(self.n * 100 / total)
            pct = 0 if pct < 0 else 100 if pct > 100 else pct
            if pct != _ProgressTqdm._last_pct:
                _ProgressTqdm._last_pct = pct
                _reply({"id": rid, "event": "progress", "repo": repo, "pct": pct})

        def update(self, n=1):
            r = super().update(n)
            self._emit()
            return r

        def refresh(self, *a, **k):
            r = super().refresh(*a, **k)
            self._emit()
            return r

        def close(self):
            self._emit()
            return super().close()

    return _ProgressTqdm


# --------------------------------------------------------------------------- #
# Lazy singletons: STT backends per engine id, and the cleanup pipeline module.
# Both stay unloaded until first use so an STT-only session never pays the
# Gemma-4 load, and vice versa.
# --------------------------------------------------------------------------- #
_BACKENDS: dict[str, object] = {}
_pipeline = None

DEFAULT_ENGINE = "typhoon-turbo-mlx"  # W7-STT: Thai fine-tune of whisper-turbo,
# benchmarked ahead of Pathumma at half the size (see typhoon-turbo-mlx backend).
# pathumma-mlx stays registered as the fallback/A-B engine.

# Same dict-hit priming utterance as cleanup_worker.py: forces the LLM path so
# the first real clean is warm.
_PRIME_TEXT = "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา"


def _release_stt_memory() -> None:
    """Free the previous engine's weights BEFORE a new engine loads.

    Every local engine funnels through mlx_whisper's single-slot ModelHolder,
    so get_model() only drops the old model AFTER the new load completes — a
    switch would hold both weight sets at peak, and the old buffers would then
    linger in MLX's cache (RSS never comes back down). Empty the slot, collect
    the freed arrays, then return the cached Metal buffers to the OS.
    Best-effort throughout: a cloud backend (groq) has nothing to free, and
    mlx/mlx_whisper may be absent entirely in hermetic tests.
    """
    try:
        from mlx_whisper.transcribe import ModelHolder

        ModelHolder.model = None
        ModelHolder.model_path = None
    except Exception:
        pass
    import gc

    gc.collect()
    try:
        import mlx.core as mx

        mx.clear_cache()
    except Exception:
        pass


def _get_backend(engine: str):
    if engine not in _BACKENDS:
        # Engine switch: evict the stale backend(s) and release the previous
        # weights FIRST, so the new load never stacks on top of the old one.
        stale = [k for k in _BACKENDS if k != engine]
        if stale:
            for k in stale:
                del _BACKENDS[k]
            _release_stt_memory()
        from app.stt import build_backend

        backend = build_backend(engine)
        backend.warm_up()
        _BACKENDS[engine] = backend
    return _BACKENDS[engine]


def _get_pipeline():
    global _pipeline
    if _pipeline is None:
        import pipeline  # noqa: E402  (benchmark/ on sys.path)

        _pipeline = pipeline
    return _pipeline


# --------------------------------------------------------------------------- #
# W4-T1 Feature B: deterministic filler-word removal (pure; no models/pythainlp).
# --------------------------------------------------------------------------- #
# Runs on the RAW STT text BEFORE clean_ex, so the gate / LLM / Thai-spacing all
# see filler-free text. We remove ONLY STANDALONE filler tokens -- a candidate
# fires iff BOTH edges are a whitespace/punctuation/string-edge (i.e. NEITHER
# neighbour is a letter, digit, or Thai code point). This leans on Pathumma
# emitting Thai word-spaced tokens PRE-normalization (the same property
# normalize_thai_spacing later collapses): a real interjection lands space- or
# punctuation-bounded. A filler GLUED inside a Thai run (e.g. "อืมมาก") is
# consciously LEFT -- the safe direction (we never split a genuine word). The
# `raw` field in the dictate reply always stays the TRUE raw; only the cleanup
# INPUT is filtered. English matches are case-insensitive.
_FILLERS = [
    # Thai
    "อืมม", "อืม", "เอ่อ", "เอ้อ", "อ่าา", "อ่า", "เอิ่ม", "หืม",
    # English
    "uhh", "erm", "hmm", "um", "uh", "er",
]
# "glue" = a char that, if adjacent, means the filler is part of a longer word:
# Latin letters, ASCII digits, and the whole Thai block (consonants, vowels,
# tone marks, Thai digits: U+0E00-U+0E7F). Whitespace / punctuation / edges are
# NOT glue, so a filler beside them is standalone and removable.
_GLUE = r"A-Za-z0-9฀-๿"
# longest-first alternation so "อืมม"/"uhh" win over "อืม"/"uh" (the boundary
# lookarounds already prevent a short filler firing inside a longer one, but
# ordering keeps the match unambiguous).
_FILLER_ALT = "|".join(re.escape(f) for f in sorted(_FILLERS, key=len, reverse=True))
_FILLER_RE = re.compile(
    rf"(?<![{_GLUE}])(?:{_FILLER_ALT})(?![{_GLUE}])", re.IGNORECASE
)


def remove_fillers(text: str) -> "tuple[str, int]":
    """Strip standalone filler tokens from `text`. Returns (new_text, n_removed).

    A no-op input (no filler fired) is returned BYTE-IDENTICAL with 0 removed --
    so remove_fillers on filler-free STT never perturbs the transcript. When at
    least one filler fired, the leftover double spaces are collapsed and the
    result is stripped (a removed edge-filler must not leave dangling space).
    """
    new, n = _FILLER_RE.subn("", text)
    if n == 0:
        return text, 0
    new = re.sub(r"[ \t]{2,}", " ", new).strip()
    return new, n


# --------------------------------------------------------------------------- #
# B3 (custom vocabulary): build the STT `initial_prompt` from the request.
# --------------------------------------------------------------------------- #
# Whisper's initial_prompt biases decoding toward the words/spelling it carries
# -- the ONE lever that fixes a misrecognized name/jargon term AT THE SOURCE
# (post-hoc replacement only helps once STT already produced something close).
# The client sends a `vocabulary` list (user terms) and/or an explicit
# `initial_prompt` string; we prefer an explicit prompt, else join the terms.
# Capped so a runaway list can't blow past Whisper's prompt budget (it keeps only
# the last ~224 tokens internally anyway; the char cap is just a sane bound).
_MAX_PROMPT_CHARS = 960


def _build_initial_prompt(req: dict) -> "str | None":
    # User portion: an explicit initial_prompt wins, else the vocabulary terms.
    user = ""
    ip = req.get("initial_prompt")
    if isinstance(ip, str) and ip.strip():
        user = ip.strip()
    else:
        vocab = req.get("vocabulary")
        if isinstance(vocab, list):
            terms = [str(t).strip() for t in vocab if str(t).strip()]
            if terms:
                user = ", ".join(terms)

    # When spoken formatting commands are ON, seed the prompt with the command
    # phrases too, so STT transcribes them CONSISTENTLY enough for the matcher to
    # fire -- the user does NOT have to add them to their vocabulary by hand. (The
    # commands are matched on the pre-cleanup text and become line breaks BEFORE
    # Gemma cleanup runs, so cleanup can't distort them; this only helps STT
    # PRODUCE them cleanly.) Whisper keeps the TAIL of an over-long prompt, so the
    # command phrases go LAST and the user portion is trimmed to leave room.
    fmt = ", ".join(_FORMAT_COMMAND_PHRASES) if req.get("format_commands") else ""
    if not user and not fmt:
        return None
    if user and fmt:
        user = user[: max(0, _MAX_PROMPT_CHARS - len(fmt) - 2)]
        return (user + ", " + fmt) if user else fmt
    return (user or fmt)[:_MAX_PROMPT_CHARS]


# --------------------------------------------------------------------------- #
# B4 (spoken formatting commands): map dictated phrases to line breaks / bullets.
# --------------------------------------------------------------------------- #
# Opt-in (default OFF -- higher false-positive risk than fillers, since a command
# phrase can also be genuine content). Deterministic, no model. The set is kept
# TIGHT and unambiguous on purpose: line/paragraph breaks + a bullet, which carry
# the most value for long-form dictation while rarely appearing as literal
# content. Punctuation words ("period"/"comma") are intentionally EXCLUDED --
# they are far too common as real words to auto-convert safely.
#
# Boundary discipline mirrors the fillers: a command fires ONLY when both edges
# are whitespace/punctuation/string-edge (never glued inside a longer word/Thai
# run), using the same _GLUE class. Longest-first alternation so a phrase that
# contains a shorter one (ขึ้นบรรทัดใหม่ ⊃ บรรทัดใหม่) matches whole.
#
# Because the Thai boundary needs the WORD SPACING that cleanup's
# normalize_thai_spacing later collapses, the dictate handler applies commands by
# SPLITTING the pre-cleanup text on them, cleaning each segment independently,
# then rejoining with the separators (see _handle) -- so the inserted breaks are
# never seen (or eaten) by the LLM, and the collapse can't erase the boundaries.
_FORMAT_COMMANDS = [
    ("ขึ้นย่อหน้าใหม่", "\n\n"),
    ("ย่อหน้าใหม่", "\n\n"),
    ("new paragraph", "\n\n"),
    ("ขึ้นบรรทัดใหม่", "\n"),
    ("บรรทัดใหม่", "\n"),
    ("new line", "\n"),
    ("newline", "\n"),
    ("bullet point", "\n- "),
]
# CANONICAL, human-phrased command vocabulary above — this list ALSO seeds the STT
# initial_prompt (via _FORMAT_COMMAND_PHRASES), so it must stay clean/natural: do
# NOT add transliterated spellings here (seeding STT with "นิวไลน์" perturbs
# recognition and regressed fm05). Extra MATCH-ONLY variants live below: they
# widen what the post-STT matcher recognizes without touching what STT is primed
# to emit. The Thai-script rows are the predictable Whisper transliterations of
# OLIV's own closed command set (enumerated from Thai phonetics, ท์/ต์ +
# vowel-length axes) — feature completeness, not benchmark-term memorization.
_FORMAT_COMMAND_VARIANTS = [
    ("newparagraph", "\n\n"),
    ("นิวพารากราฟ", "\n\n"),
    ("นิวไลน์", "\n"),
    ("นิวไลน", "\n"),
    ("bulletpoint", "\n- "),
    ("บุลเล็ตพอยท์", "\n- "),
    ("บุลเล็ตพอยต์", "\n- "),
    ("บูลเล็ตพอยต์", "\n- "),
    ("บุลเลตพอยต์", "\n- "),
]
# The command phrases alone (order preserved) -- used to seed the STT
# initial_prompt when formatting commands are on, so STT emits them cleanly
# enough to match (see _build_initial_prompt). Kept distinct from _FMT_MAP so the
# prompt carries the human phrasing, not the "\n" replacements.
_FORMAT_COMMAND_PHRASES = [phrase for phrase, _ in _FORMAT_COMMANDS]  # STT seed: canonical only
_FMT_ALL = _FORMAT_COMMANDS + _FORMAT_COMMAND_VARIANTS

# Two matching regimes, because "word boundary" is a Latin concept, not a Thai one.
# ENGLISH commands ("new line", "bullet point") are real English content and keep
# the flank guard so they don't fire mid-word. THAI-script commands are matched
# FUZZILY (phonetic fold + edit distance, phonetic.fuzzy_command_spans) with NO
# flank guard, because Thai has no inter-word spaces and different STT models both
# glue the command to adjacent Thai AND spell it differently (typhoon writes
# "ขึ้นบรรทัดใหม่" as "ขึ้นมาทัดใหม่"). Enumerating exact spellings is whack-a-mole; the
# fold absorbs the drift and the variant bullet spellings for free.
_THAI_CH_RE = re.compile(r"[฀-๿]")
_FMT_EN = [(p, r) for p, r in _FMT_ALL if not _THAI_CH_RE.search(p)]
_FMT_EN_MAP = {p.lower(): r for p, r in _FMT_EN}
_FMT_EN_ALT = "|".join(re.escape(p) for p, _ in sorted(_FMT_EN, key=lambda x: len(x[0]), reverse=True))
_FMT_EN_RE = re.compile(rf"(?<![{_GLUE}])(?:{_FMT_EN_ALT})(?![{_GLUE}])", re.IGNORECASE)
# Distinct canonical THAI commands for the fuzzy matcher (variants absorbed by the fold).
_FMT_THAI_CMDS = [
    ("ขึ้นย่อหน้าใหม่", "\n\n"), ("ย่อหน้าใหม่", "\n\n"), ("นิวพารากราฟ", "\n\n"),
    ("ขึ้นบรรทัดใหม่", "\n"), ("บรรทัดใหม่", "\n"), ("นิวไลน์", "\n"),
    ("บุลเล็ตพอยต์", "\n- "),
]


def _split_format_commands(text: str) -> "tuple[list[str], list[str]]":
    """Split `text` at each spoken formatting command.

    Returns (segments, separators), len(segments) == len(separators) + 1: the text
    between commands and the line-break/bullet each maps to. English commands are
    flank-guarded; Thai commands are fuzzy-matched, boundary-free (see above)."""
    from phonetic import fuzzy_command_spans  # lazy: pulls pythainlp on first use
    spans: list[tuple[int, int, str]] = []
    for m in _FMT_EN_RE.finditer(text):
        spans.append((m.start(), m.end(), _FMT_EN_MAP[m.group(0).lower()]))
    spans.extend(fuzzy_command_spans(text, _FMT_THAI_CMDS))
    spans.sort()
    segments: list[str] = []
    separators: list[str] = []
    last = 0
    for s, e, repl in spans:
        if s < last:
            continue  # overlap (e.g. English + Thai claimed the same run) -> keep first
        segments.append(text[last:s])
        separators.append(repl)
        last = e
    segments.append(text[last:])
    return segments, separators


def _join_format(segments: "list[str]", separators: "list[str]") -> str:
    """Interleave cleaned `segments` with their `separators`, then tidy the
    whitespace around the inserted breaks: no spaces hugging a newline, at most
    one blank line, and no leading/trailing whitespace on the whole result."""
    parts: list[str] = []
    for i, seg in enumerate(segments):
        parts.append(seg)
        if i < len(separators):
            parts.append(separators[i])
    joined = "".join(parts)
    joined = re.sub(r"[ \t]*\n[ \t]*", "\n", joined)  # strip spaces hugging breaks
    joined = re.sub(r"\n{3,}", "\n\n", joined)         # cap blank lines at one
    return joined.strip()


def apply_format_commands(text: str) -> "tuple[str, int]":
    """Convert spoken formatting commands in `text` to their line breaks/bullets,
    with NO per-segment cleanup (each segment passes through stripped). Returns
    (new_text, n_commands). This is the cleanup-OFF behaviour AND the pure,
    model-free core the hermetic tests exercise; the dictate handler uses the
    same _split/_join around real cleanup when cleanup is on. A no-command input
    is returned BYTE-IDENTICAL with 0 (the never-perturb rule)."""
    segments, separators = _split_format_commands(text)
    if not separators:
        return text, 0
    return _join_format([s.strip() for s in segments], separators), len(separators)


# --------------------------------------------------------------------------- #
# Garble-triggered forced-English re-decode (STT stage, auto-language only).
# --------------------------------------------------------------------------- #
# Pathumma is a Thai fine-tune: it sometimes decodes a pure-English utterance AS
# fluent-but-wrong Thai (eval en06 "we need to cut down..." -> Thai garble). The
# tell is a LOW mean avg_logprob -- the model is unconfident (en06 auto=-0.38,
# en08=-0.58) whereas genuine Thai/code-switch is confident (hx=-0.09..-0.14). So
# when auto-decode confidence is low, decode the SAME audio again forced to
# English and keep whichever decode is MORE confident. Same model, no new weights;
# the extra decode runs only on low-confidence clips (bounded latency). The
# logprob comparison is the real safety net: on true Thai audio the forced-en
# decode scores far lower, so we keep Thai. Only active in auto-language mode and
# only on backends that surface avg_logprob (MLX Whisper); a no-op elsewhere.
_REDECODE_MIN_LOGPROB = -0.30   # trigger: attempt forced-en only below this
_REDECODE_MARGIN = 0.02         # switch only if forced-en beats auto by this


def _transcribe_maybe_redecode(backend, audio, *, language, initial_prompt):
    """Auto-decode; if unconfident, try a forced-English re-decode and keep the
    higher-confidence transcript. Returns (text, redecoded: bool)."""
    r = backend.transcribe_ex(audio, language=language, initial_prompt=initial_prompt)
    lp = r.get("avg_logprob")
    # Only in auto mode, only when the backend gave a (low) confidence signal.
    if language or lp is None or lp >= _REDECODE_MIN_LOGPROB:
        return r["text"], False
    alt = backend.transcribe_ex(audio, language="en", initial_prompt=initial_prompt)
    alp = alt.get("avg_logprob")
    if alp is not None and alp > lp + _REDECODE_MARGIN:
        return alt["text"], True
    return r["text"], False


def _clean_and_replace_segments(
    segments: "list[str]",
    separators: "list[str]",
    *,
    cleanup_on: bool,
    replacements: "dict | None",
    vocab: "list | None" = None,
    pipeline=None,
) -> dict:
    """Clean (if cleanup_on) + apply user replacements to each segment, then
    rejoin with `separators`. Returns an info dict with the joined `final` and the
    cleanup fields AGGREGATED across segments (single-segment => that segment's
    values verbatim, so the common path is unchanged). `pipeline` is injectable
    (defaults to the lazy real pipeline) so the multi-segment aggregation is
    hermetically testable with a fake. THE TRANSCRIPT IS NEVER LOST: a clean_ex
    failure degrades that segment to its pre-cleanup text + records
    cleanup_error; a bad replacements table degrades to the pre-replacement text.
    """
    pl = pipeline
    info = {
        "final": "", "t_cleanup": 0.0, "cleanup_error": None,
        "llm_ran": False, "gate_reason": "", "guardrail_flag": "",
        "dict_hits": 0, "t_llm": 0.0, "replacements_fired": 0, "vocab_fired": 0,
    }
    multi = bool(separators)
    cleaned: list[str] = []
    for seg in segments:
        seg_final = seg
        if cleanup_on and seg.strip():
            if pl is None:
                pl = _get_pipeline()
            t0 = time.perf_counter()
            try:
                r = pl.clean_ex(seg, vocab=vocab)
                seg_final = r.text
                info["llm_ran"] = info["llm_ran"] or r.llm_ran
                info["dict_hits"] += r.dict_hits
                info["vocab_fired"] += getattr(r, "vocab_fired", 0)
                info["t_llm"] += r.t_llm
                if not info["gate_reason"]:
                    info["gate_reason"] = r.gate_reason
                if not info["guardrail_flag"]:
                    info["guardrail_flag"] = r.guardrail_flag
            except Exception as exc:
                info["cleanup_error"] = f"{type(exc).__name__}: {exc}"
            info["t_cleanup"] += time.perf_counter() - t0

        if replacements and seg_final.strip():
            if pl is None:
                pl = _get_pipeline()
            try:
                new_final, n_repl = pl.apply_dictionary(seg_final, replacements)
                seg_final = pl.normalize_thai_spacing(new_final)
                info["replacements_fired"] += n_repl
            except Exception as exc:
                print(f"sidecar: replacements pass failed ({type(exc).__name__}: {exc})",
                      file=sys.stderr)
        cleaned.append(seg_final.strip() if multi else seg_final)

    info["final"] = _join_format(cleaned, separators) if multi else cleaned[0]
    return info


def _decode_audio(req: dict):
    """Return the audio payload as whatever the STT backend accepts:
    a float32 numpy array (pcm_b64) or a filesystem path (wav_path)."""
    if "pcm_b64" in req:
        import numpy as np

        raw = base64.b64decode(req["pcm_b64"])
        return np.frombuffer(raw, dtype=np.float32)
    if "wav_path" in req:
        return req["wav_path"]
    raise ValueError("dictate needs pcm_b64 or wav_path")


# --------------------------------------------------------------------------- #
# W7 no-speech gate: reject non-speech input before/after the STT model.
# --------------------------------------------------------------------------- #
# Whisper (and this Thai fine-tune) ALWAYS emit some text: given silence or faint
# room noise on a push-to-talk press with no speech, the decoder hallucinates --
# most often a few CJK characters, a well-known artifact of caption-heavy
# training data. There is no VAD upstream, so we gate here:
#   (A) drop near-silent / too-short audio BEFORE it reaches the model, and
#   (B) strip any CJK / kana / hangul from the transcript -- OLIV only ever types
#       Thai + English, so such characters are always hallucinations. A hard,
#       character-level guarantee that not one reaches the typed output; a
#       transcript that is nothing but them collapses to empty -> no_speech.
# Both checks are pure + cheap. Thresholds are deliberately conservative so
# genuinely quiet speech is not cut; raise _SILENCE_RMS only if silence still
# leaks through in practice.
_SILENCE_RMS = 0.005        # frame RMS at/above this (16k float32 in [-1,1]) => speech
_MIN_SPEECH_S = 0.15        # need at least this much speech-level audio, else no speech
_FRAME_S = 0.03             # 30 ms analysis frame -- a phoneme-scale window
_CJK_RE = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]")
def _is_silent(audio, *, sample_rate: int = 16000,
               rms_threshold: float = _SILENCE_RMS,
               min_dur_s: float = _MIN_SPEECH_S) -> bool:
    """True if `audio` carries no speech. Only float32 mic arrays are gated: a
    str/Path (the benchmark's wav_path) is never gated (returns False), so the
    eval harness is untouched.

    FRAME-WISE, deliberately. This was one RMS over the WHOLE capture, and a mean
    is the wrong statistic for "did anyone speak" -- it lets the quiet parts
    outvote the loud ones, and it is wrong in BOTH directions:

      * Real speech was DROPPED. 0.5 s of clear speech (RMS 0.03) inside a 30 s
        press averages to 0.0043 -- under the floor -- so the clip was declared
        silence and OLIV typed nothing and said nothing about it. Ditto an
        ordinary 3 s press from someone speaking softly or sitting back from the
        mic. This is what the Bluetooth dead-lead-in exposed: a clip padded with
        silence gets averaged into "no speech".
      * A lone transient was ADMITTED. One 30 ms click at 0.5 (a Bluetooth
        profile switch, a keypress) in an otherwise silent hold averages to
        0.0498 -- ten times the floor -- so pure noise reached Whisper and came
        back as a hallucination.

    So: chop into `_FRAME_S` frames, measure how much of the capture actually sits
    at speech level, and require at least `min_dur_s` of it. Silence between words
    no longer votes, and 30 ms of anything is still not an utterance.
    """
    import numpy as np

    if not isinstance(audio, np.ndarray):
        return False
    if audio.size == 0:
        return True
    if audio.size / sample_rate < min_dur_s:
        return True

    frame = max(1, int(sample_rate * _FRAME_S))
    count = audio.size // frame
    if count == 0:                      # >= min_dur_s but shorter than one frame
        frame, count = audio.size, 1
    # reshape is a view; square in float32 (one temp the size of the input) and
    # accumulate in float64 -- never materializes a float64 copy of a long capture.
    frames = audio[:count * frame].reshape(count, frame)
    frame_rms = np.sqrt(np.mean(np.square(frames), axis=1, dtype=np.float64))
    speech_s = float((frame_rms >= rms_threshold).sum()) * (frame / sample_rate)
    return speech_s < min_dur_s


def _strip_cjk(text: str) -> str:
    """Remove every CJK / kana / hangul character from `text` and tidy the
    whitespace the removal leaves behind. OLIV only ever types Thai + English, so
    these characters are always Whisper hallucinations (typically on silence) --
    this is the hard guarantee that not one reaches the typed output. Text with no
    such character is returned unchanged."""
    if not text or not _CJK_RE.search(text):
        return text
    return re.sub(r"\s{2,}", " ", _CJK_RE.sub("", text)).strip()


def _no_speech_reply(rid, engine: str, *, t_stt: float = 0.0) -> dict:
    """A dictate reply for gated non-speech: an empty transcript in the SAME shape
    as a normal reply (so the client path is unchanged), flagged `no_speech` so the
    client can simply type nothing."""
    return {
        "id": rid, "ok": True, "engine": engine, "no_speech": True,
        "raw": "", "final": "", "stt_redecoded": False,
        "t_stt": t_stt, "t_cleanup": 0.0, "cleanup_error": None,
        "llm_ran": False, "gate_reason": "no_speech", "guardrail_flag": "",
        "dict_hits": 0, "t_llm": 0.0,
        "fillers_removed": 0, "replacements_fired": 0,
        "format_commands_fired": 0, "vocab_fired": 0,
    }


def _clean_reply_fields(r) -> dict:
    return {
        "llm_ran": r.llm_ran,
        "gate_reason": r.gate_reason,
        "guardrail_flag": r.guardrail_flag,
        "dict_hits": r.dict_hits,
        "t_llm": r.t_llm,
    }


def _set_hf_offline(flag: bool) -> None:
    """Flip huggingface_hub's offline mode at runtime. hf reads HF_HUB_OFFLINE
    into module globals AT IMPORT, so setting the env var alone doesn't affect
    already-imported submodules — reassign the attr on every hf submodule that
    holds it (covers by-value `from .constants import HF_HUB_OFFLINE` captures),
    and update the env for any not-yet-imported ones. Lets `download` re-enable the
    network while the process otherwise stays offline (fast, non-blocking loads)."""
    os.environ["HF_HUB_OFFLINE"] = "1" if flag else "0"
    for _name, _mod in list(sys.modules.items()):
        if _name.startswith("huggingface_hub") and hasattr(_mod, "HF_HUB_OFFLINE"):
            try:
                setattr(_mod, "HF_HUB_OFFLINE", flag)
            except Exception:
                pass


def _handle(req: dict) -> "dict | None":
    cmd = req.get("cmd")
    rid = req.get("id")

    if cmd == "shutdown":
        return None

    if cmd == "ping":
        return {"id": rid, "ok": True, "pid": os.getpid()}

    if cmd == "warm":
        engine = req.get("engine", DEFAULT_ENGINE)
        t0 = time.time()
        _get_backend(engine)
        t_stt = time.time() - t0

        t_cleanup = 0.0
        if req.get("cleanup", True):
            t0 = time.time()
            pl = _get_pipeline()
            pl._ensure_model()
            try:
                pl.clean_ex(_PRIME_TEXT)  # prime the generate graph
            except Exception:
                pass  # best-effort: the model is loaded either way
            t_cleanup = time.time() - t0
        return {
            "id": rid, "ok": True, "engine": engine,
            "t_stt_load": t_stt, "t_cleanup_load": t_cleanup,
        }

    if cmd == "dictate":
        engine = req.get("engine", DEFAULT_ENGINE)
        audio = _decode_audio(req)

        # W7 no-speech gate (A): reject near-silent / too-short mic input BEFORE
        # the model runs -- no transcript, no CJK ghost text, zero model cost.
        if _is_silent(audio):
            return _no_speech_reply(rid, engine)

        # B3 custom vocabulary: bias the decode toward user terms (or an explicit
        # initial_prompt). None => unchanged from pre-B3. Skipped for backends that
        # repetition-loop on prompt seeding (see STTBackend.seed_prompt) -- the
        # post-STT vocab corrector / format matcher handle those cases instead.
        backend = _get_backend(engine)
        initial_prompt = _build_initial_prompt(req) if getattr(backend, "seed_prompt", True) else None

        t0 = time.perf_counter()
        raw, stt_redecoded = _transcribe_maybe_redecode(
            backend, audio,
            language=req.get("language"), initial_prompt=initial_prompt,
        )
        t_stt = time.perf_counter() - t0

        reply = {
            "id": rid, "ok": True, "engine": engine,
            "raw": raw, "final": raw, "stt_redecoded": stt_redecoded,
            "t_stt": t_stt, "t_cleanup": 0.0, "cleanup_error": None,
            "llm_ran": False, "gate_reason": "", "guardrail_flag": "",
            "dict_hits": 0, "t_llm": 0.0,
            "fillers_removed": 0, "replacements_fired": 0,
            "format_commands_fired": 0,
        }

        # W7 no-speech gate (B): OLIV only ever types Thai + English, so strip any
        # CJK / kana / hangul the model hallucinated (the classic Whisper-on-silence
        # artifact) so not one character can reach the typed output. `raw` in the
        # reply stays the TRUE STT output (debug / benchmark); only the text that
        # flows into cleanup is cleaned. If nothing survives the strip, the
        # utterance was pure hallucination -> no_speech.
        text = _strip_cjk(raw)
        if raw.strip() and not text.strip():
            return _no_speech_reply(rid, engine, t_stt=t_stt)

        # W4-T1 Feature B: strip filler words from the (CJK-clean) STT text BEFORE
        # cleanup (default OFF at the protocol level -- the client flips it on from
        # Settings). Only the text that flows into cleanup is filtered. Pure/no-model.
        if req.get("remove_fillers", False) and text.strip():
            text, reply["fillers_removed"] = remove_fillers(text)

        # Baseline final = the (filler-filtered) text -- the answer when cleanup
        # is off or bypassed, and the fallback target if clean_ex raises.
        reply["final"] = text

        # B4 spoken formatting commands (opt-in; default OFF). When on and a
        # command fires, split the pre-cleanup text on the command phrases and
        # clean each segment INDEPENDENTLY, then rejoin with the command's line
        # break/bullet. This is why the command match happens HERE, on the
        # word-spaced pre-cleanup text: cleanup's normalize_thai_spacing later
        # collapses the very Thai word boundaries the boundary guard relies on,
        # and the LLM would otherwise eat inserted newlines. With the feature off
        # or no command matched, segments == [text] and this is byte-identical to
        # the pre-B4 single-pass path.
        do_format = bool(req.get("format_commands", False)) and bool(text.strip())
        segments, separators = _split_format_commands(text) if do_format else ([text], [])
        reply["format_commands_fired"] = len(separators)

        # Clean + apply replacements per segment, then rejoin. For the common
        # single-segment path this is byte-identical to the pre-B4 single pass
        # (one clean_ex, its fields verbatim). W4-T1 Feature A (user replacements)
        # runs inside per segment. THE TRANSCRIPT IS NEVER LOST (see the helper).
        info = _clean_and_replace_segments(
            segments, separators,
            cleanup_on=req.get("cleanup", True),
            replacements=req.get("replacements"),
            vocab=req.get("vocabulary"),
        )
        reply["final"] = info["final"]
        reply["t_cleanup"] = info["t_cleanup"]
        reply["cleanup_error"] = info["cleanup_error"]
        reply["llm_ran"] = info["llm_ran"]
        reply["gate_reason"] = info["gate_reason"]
        reply["guardrail_flag"] = info["guardrail_flag"]
        reply["dict_hits"] = info["dict_hits"]
        reply["t_llm"] = info["t_llm"]
        reply["replacements_fired"] = info["replacements_fired"]
        reply["vocab_fired"] = info["vocab_fired"]
        return reply

    if cmd == "clean":
        r = _get_pipeline().clean_ex(req.get("text", ""))
        return {"id": rid, "ok": True, "text": r.text, **_clean_reply_fields(r),
                "t_total": r.t_total}

    if cmd == "download":
        # First-run onboarding + Settings model fetch (W3-T4). snapshot_download
        # honors HF_HOME (the .app points it at Application Support), so a bundled
        # sidecar downloads into the app-owned store. Progress lines are emitted by
        # _make_progress_tqdm BEFORE this final reply, sharing the id.
        #
        # The process defaults to HF_HUB_OFFLINE=1 so warm/dictate loads never block
        # on the network. For each repo we FIRST try the local cache (offline,
        # instant, never hangs) — a fully-cached repo needs no network at all. Only a
        # MISSING or INCOMPLETE repo re-enables the network to fetch it (then restores
        # offline). So an already-provisioned Mac never touches HF here.
        from huggingface_hub import snapshot_download

        repos = req.get("repos") or []
        downloaded: list[str] = []
        for repo in repos:
            try:
                snapshot_download(repo, local_files_only=True)  # cached+complete? done, no network
                downloaded.append(repo)
                continue
            except Exception:
                pass  # missing/incomplete → fetch online below
            _set_hf_offline(False)
            try:
                snapshot_download(repo, tqdm_class=_make_progress_tqdm(rid, repo))
                downloaded.append(repo)
            except Exception as exc:
                # Per-repo failure: stop, report which repo (and what already
                # finished). The process stays alive and serving.
                return {
                    "id": rid, "ok": False,
                    "error": f"{type(exc).__name__}: {exc}",
                    "failed_repo": repo, "downloaded": downloaded,
                }
            finally:
                _set_hf_offline(True)
        return {"id": rid, "ok": True, "downloaded": downloaded}

    return {"id": rid, "ok": False, "error": f"unknown cmd {cmd!r}"}


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
        except Exception as exc:
            _reply({"id": None, "ok": False, "error": f"bad request JSON: {exc}"})
            continue
        try:
            reply = _handle(req)
        except Exception as exc:
            # One bad request must never crash the sidecar: report + serve on.
            _reply({"id": rid, "ok": False, "error": f"{type(exc).__name__}: {exc}"})
            continue
        if reply is None:  # shutdown
            break
        _reply(reply)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
