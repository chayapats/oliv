"""Hermetic tests for the text passes -- NO models, NO server spawn.

All passes are pure (or pipeline-injectable) functions, so they are tested here
directly; the server-level protocol checks live in test_sidecar.py, which reuses
the warmed models. Run from anywhere:

    sidecar/.venv/bin/python sidecar/test_text_passes.py

Coverage:
  W4-T1 Feature B (filler removal)   -- `sidecar_server.remove_fillers`
  W4-T1 Feature A (user replacements)-- `dictionary.apply_dictionary(text, table)`
  B3  (custom vocabulary)            -- `_build_initial_prompt` (vocab -> prompt)
  B4  (spoken formatting commands)   -- `_split_format_commands` / `_join_format`
                                        / `apply_format_commands`, plus the
                                        multi-segment `_clean_and_replace_segments`
                                        aggregation tested against a FAKE pipeline
                                        (so the split-clean-join is verified with
                                        no models).

Imported with OLIV_SIDECAR_IMPORT_ONLY=1 so the module's protocol fd-split does
not hijack this test's stdout (the serve loop never sets it; see sidecar_server).
"""

from __future__ import annotations

import os
import sys
import threading
import time
import types
from pathlib import Path

# Import the sidecar for its pure helper WITHOUT letting its protocol setup
# redirect our stdout (the serve loop never sets this env; see sidecar_server).
os.environ["OLIV_SIDECAR_IMPORT_ONLY"] = "1"

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "sidecar"))
sys.path.insert(0, str(_ROOT / "benchmark"))

from sidecar_server import (  # noqa: E402
    remove_fillers,
    apply_format_commands,
    _split_format_commands,
    _join_format,
    _build_initial_prompt,
    _clean_and_replace_segments,
    _MAX_PROMPT_CHARS,
    _is_silent,
    _strip_cjk,
    _no_speech_reply,
    _SILENCE_RMS,
)
import numpy as np  # noqa: E402
from dictionary import apply_dictionary     # noqa: E402
from thai_format import (                    # noqa: E402
    apply_thai_format,
    _collapse_reduplication,
    _convert_numbers,
    _num,
)

PASSED: list[str] = []
FAILED: list[tuple[str, str]] = []
CASES: list = []


def register(name: str):
    def deco(fn):
        def run():
            try:
                fn()
            except AssertionError as e:
                FAILED.append((name, str(e) or "assert failed"))
                print(f"FAIL  {name}: {e}")
            else:
                PASSED.append(name)
                print(f"PASS  {name}")
        CASES.append(run)
        return fn
    return deco


# --------------------------------------------------------------------------- #
# Feature B: filler removal (standalone-only, no-op-safe, count correct)
# --------------------------------------------------------------------------- #
@register("filler_standalone_thai_removed")
def _():
    out, n = remove_fillers("พูด เอ่อ ประชุม")
    assert out == "พูด ประชุม", repr(out)
    assert n == 1, n


@register("filler_glued_thai_kept")
def _():
    # เอ่อ glued directly onto สวัสดี -> a genuine word edge; consciously LEFT.
    out, n = remove_fillers("เอ่อสวัสดีครับ")
    assert (out, n) == ("เอ่อสวัสดีครับ", 0), (out, n)
    # อืม glued inside อืมมาก likewise stays (never split a real run).
    assert remove_fillers("อืมมาก") == ("อืมมาก", 0)


@register("filler_english_standalone_removed_glued_kept")
def _():
    assert remove_fillers("I uh think so") == ("I think so", 1)
    # "er" inside server/error and "um" inside album must NOT fire.
    assert remove_fillers("server error here") == ("server error here", 0)
    assert remove_fillers("albums are uhh great") == ("albums are great", 1)


@register("filler_punctuation_adjacent_english")
def _():
    # A comma/period counts as a boundary (not glue), so the filler is standalone.
    out, n = remove_fillers("uh, okay")
    assert out == ", okay" and n == 1, (out, n)
    out2, n2 = remove_fillers("Um... right")
    assert out2 == "... right" and n2 == 1, (out2, n2)


@register("filler_multiple_and_all_thai_variants")
def _():
    out, n = remove_fillers("um เอ่อ hmm สวัสดี")
    assert out == "สวัสดี" and n == 3, (out, n)
    out2, n2 = remove_fillers("เอิ่ม อ่า อ่าา หืม เอ้อ อืมม จบ")
    assert out2 == "จบ" and n2 == 6, (out2, n2)


@register("filler_noop_byte_identical_and_case_insensitive")
def _():
    # No filler -> byte-identical passthrough, 0 removed (the never-perturb rule).
    assert remove_fillers("no fillers at all") == ("no fillers at all", 0)
    assert remove_fillers("ประชุมทีมบ่ายสอง") == ("ประชุมทีมบ่ายสอง", 0)
    # English matching is case-insensitive.
    assert remove_fillers("ER, well") == (", well", 1)


# --------------------------------------------------------------------------- #
# Feature A: user replacements via apply_dictionary(text, table)
# --------------------------------------------------------------------------- #
@register("replacement_whole_phrase_fires")
def _():
    table = {"อีเมลของผม": "me@example.com"}
    out, n = apply_dictionary("ส่งอีเมลของผมไปให้ทีม", table)
    assert out == "ส่ง me@example.com ไปให้ทีม", repr(out)
    assert n == 1, n
    assert "  " not in out, f"double space: {out!r}"


@register("replacement_longest_key_first")
def _():
    # Both a prefix key and the full phrase are present; the LONGER key wins.
    table = {"อีเมล": "EMAIL", "อีเมลของผม": "me@example.com"}
    out, n = apply_dictionary("อีเมลของผมคือ", table)
    assert out == "me@example.com คือ", repr(out)
    assert n == 1, n
    assert "EMAIL" not in out, out


@register("replacement_refuses_mid_thai_word")
def _():
    # Adversarial (mirrors test_dictionary): the key กา (crow) is a substring of
    # the real Thai word กาแฟ (coffee). The newmm real-word boundary guard must
    # REFUSE to fire inside กาแฟ ...
    table = {"กา": "CROW"}
    out, n = apply_dictionary("ชงกาแฟให้หน่อย", table)
    assert (out, n) == ("ชงกาแฟให้หน่อย", 0), (out, n)
    # ... yet the SAME key still fires when it stands alone.
    assert apply_dictionary("กา", table) == ("CROW", 1)


@register("replacement_empty_or_unmatched_table_is_passthrough")
def _():
    assert apply_dictionary("อีเมลของผม", {}) == ("อีเมลของผม", 0)
    assert apply_dictionary("สวัสดีครับ", {"xyz": "Z"}) == ("สวัสดีครับ", 0)


@register("replacement_default_table_unchanged")
def _():
    # The refactor must leave the built-in TRANSLIT path byte-identical: calling
    # with no table === calling with TRANSLIT (a known dict-hit clip).
    default_out, default_n = apply_dictionary("รีสตาร์ทเซิร์ฟเวอร์")
    assert default_n == 2 and "restart" in default_out and "server" in default_out, default_out


# --------------------------------------------------------------------------- #
# B3: custom vocabulary -> Whisper initial_prompt builder
# --------------------------------------------------------------------------- #
@register("vocab_prompt_none_when_empty")
def _():
    assert _build_initial_prompt({}) is None
    assert _build_initial_prompt({"vocabulary": []}) is None
    assert _build_initial_prompt({"vocabulary": ["", "   "]}) is None


@register("vocab_prompt_joins_terms")
def _():
    assert _build_initial_prompt({"vocabulary": ["Grafana", "คูเบอร์เนติส"]}) == "Grafana, คูเบอร์เนติส"
    # whitespace-only entries dropped; surviving terms trimmed
    assert _build_initial_prompt({"vocabulary": [" OLIV ", "", "Xet"]}) == "OLIV, Xet"


@register("vocab_prompt_explicit_wins_and_capped")
def _():
    # an explicit initial_prompt beats the term list, and is trimmed
    assert _build_initial_prompt({"initial_prompt": "  hi  ", "vocabulary": ["Y"]}) == "hi"
    # runaway lists are bounded to the char cap (Whisper keeps ~224 tokens anyway)
    capped = _build_initial_prompt({"vocabulary": ["a" * 5000]})
    assert len(capped) == _MAX_PROMPT_CHARS


@register("vocab_prompt_seeds_format_commands")
def _():
    from sidecar_server import _FORMAT_COMMAND_PHRASES
    cmds = ", ".join(_FORMAT_COMMAND_PHRASES)
    # format_commands ON with no vocab -> the prompt IS the command phrases, so
    # STT is biased to emit them cleanly (the user need not add them by hand).
    assert _build_initial_prompt({"format_commands": True}) == cmds
    # with vocab too: user terms first, commands appended at the TAIL (Whisper
    # keeps the tail of an over-long prompt).
    assert _build_initial_prompt({"vocabulary": ["Grafana"], "format_commands": True}) \
        == "Grafana, " + cmds
    # format OFF -> no seeding (unchanged behaviour)
    assert _build_initial_prompt({"format_commands": False}) is None
    # a runaway vocab must not push the command phrases past the cap
    p = _build_initial_prompt({"vocabulary": ["x" * 5000], "format_commands": True})
    assert p.endswith(cmds) and len(p) <= _MAX_PROMPT_CHARS


# --------------------------------------------------------------------------- #
# B4: spoken formatting commands (split / join / apply, boundary-guarded)
# --------------------------------------------------------------------------- #
@register("format_split_basic_and_separators")
def _():
    segs, seps = _split_format_commands("ประชุม ขึ้นบรรทัดใหม่ พรุ่งนี้")
    assert seps == ["\n"], seps
    assert segs == ["ประชุม ", " พรุ่งนี้"], segs
    # english + bullet, case-insensitive; two commands -> two separators
    _, seps2 = _split_format_commands("todo New Line item Bullet Point x")
    assert seps2 == ["\n", "\n- "], seps2


@register("format_glued_thai_fires")
def _():
    # A Thai command GLUED to adjacent Thai now DOES fire: Thai has no word spaces
    # and STT models (typhoon) glue the command to neighbouring text, so a flank
    # guard is the wrong model for Thai. The fuzzy matcher (high-coverage fold)
    # still won't fire on ordinary Thai -- see format_apply_noop_byte_identical.
    segs, seps = _split_format_commands("ประชุมขึ้นบรรทัดใหม่พรุ่งนี้")
    assert seps == ["\n"] and segs == ["ประชุม", "พรุ่งนี้"], (segs, seps)


@register("format_longest_phrase_wins")
def _():
    # paragraph phrase (⊃ the บรรทัดใหม่ substring) matches whole -> \n\n, not \n
    _, seps = _split_format_commands("เขียนโค้ด ขึ้นย่อหน้าใหม่ ต่อ")
    assert seps == ["\n\n"], seps


@register("format_apply_noop_byte_identical")
def _():
    # no command -> byte-identical passthrough, 0 (never-perturb rule)
    assert apply_format_commands("no commands at all") == ("no commands at all", 0)
    assert apply_format_commands("ประชุมทีมบ่ายสอง") == ("ประชุมทีมบ่ายสอง", 0)


@register("format_apply_inserts_breaks_and_tidies")
def _():
    out, n = apply_format_commands("ประชุม ขึ้นบรรทัดใหม่ พรุ่งนี้")
    assert out == "ประชุม\nพรุ่งนี้" and n == 1, (repr(out), n)
    out2, n2 = apply_format_commands("a new paragraph b")
    assert out2 == "a\n\nb" and n2 == 1, (repr(out2), n2)
    out3, n3 = apply_format_commands("items bullet point milk bullet point eggs")
    assert out3 == "items\n- milk\n- eggs" and n3 == 2, (repr(out3), n3)
    # a leading command doesn't leave a stray blank line
    assert apply_format_commands("new line hello") == ("hello", 1)


@register("format_join_tidies_whitespace_and_blank_lines")
def _():
    # spaces hugging a break are trimmed; 3+ newlines collapse to one blank line
    assert _join_format(["a ", " b"], ["\n"]) == "a\nb"
    assert _join_format(["a", "", "b"], ["\n\n", "\n\n"]) == "a\n\nb"


@register("format_segments_cleaned_independently_and_rejoined")
def _():
    # the multi-segment integration: each segment is cleaned on its OWN, then
    # rejoined with the command's break — a fake pipeline stands in for models.
    class R:
        def __init__(self, text):
            self.text = text; self.llm_ran = True; self.gate_reason = ""
            self.guardrail_flag = ""; self.dict_hits = 1; self.t_llm = 0.0

    class FakePipe:
        def clean_ex(self, seg, vocab=None):
            return R("[" + seg.strip() + "]")             # visible per-segment clean
        def apply_dictionary(self, text, table):
            for k, v in (table or {}).items():
                if k in text:
                    return text.replace(k, v), 1
            return text, 0
        def normalize_thai_spacing(self, t):
            return t

    fp = FakePipe()
    segs, seps = _split_format_commands("alpha new line beta")
    info = _clean_and_replace_segments(segs, seps, cleanup_on=True, replacements=None, pipeline=fp)
    assert info["final"] == "[alpha]\n[beta]", repr(info["final"])
    assert info["dict_hits"] == 2 and info["llm_ran"] is True, info
    # single-segment path unchanged: one clean, its fields verbatim
    info2 = _clean_and_replace_segments(["just text"], [], cleanup_on=True, replacements=None, pipeline=fp)
    assert info2["final"] == "[just text]" and info2["dict_hits"] == 1, info2


@register("format_segment_cleanup_failure_keeps_transcript")
def _():
    # clean_ex raising on a segment must degrade to that segment's pre-clean text
    # (transcript never lost) and record cleanup_error.
    class BoomPipe:
        def clean_ex(self, seg, vocab=None):
            raise RuntimeError("boom")

    info = _clean_and_replace_segments(["keep me"], [], cleanup_on=True,
                                       replacements=None, pipeline=BoomPipe())
    assert info["final"] == "keep me", info["final"]
    assert info["cleanup_error"] and "boom" in info["cleanup_error"], info["cleanup_error"]


# --------------------------------------------------------------------------- #
# W7 no-speech gate: silence energy gate (A) + CJK-hallucination guard (B)
# --------------------------------------------------------------------------- #
def _tone(rms: float, seconds: float = 1.0, sr: int = 16000):
    """A constant-amplitude float32 array whose RMS equals `rms` exactly."""
    return np.full(int(sr * seconds), rms, dtype=np.float32)


@register("silence_zeros_is_silent")
def _():
    assert _is_silent(np.zeros(16000, dtype=np.float32)) is True


@register("silence_below_rms_floor_is_silent")
def _():
    assert _is_silent(_tone(0.001)) is True          # RMS 0.001 < 0.005 floor


@register("silence_speech_level_is_not_silent")
def _():
    assert _is_silent(_tone(0.05)) is False           # RMS 0.05, clearly speech


@register("silence_quiet_speech_not_cut")
def _():
    # RMS 0.01 (2x the floor) is quiet but real -- the conservative threshold
    # must NOT drop it. Guards against the gate eating soft voices.
    assert _is_silent(_tone(0.01)) is False
    assert _SILENCE_RMS < 0.01


@register("silence_too_short_is_silent")
def _():
    # 0.0625s of loud audio is still too short to be a real utterance
    assert _is_silent(np.full(1000, 0.5, dtype=np.float32)) is True


@register("silence_empty_array_is_silent")
def _():
    assert _is_silent(np.zeros(0, dtype=np.float32)) is True


# --- The whole-clip-mean bug: a clip that CONTAINS speech must never be gated
# just because it also contains a lot of silence. A mean over the whole capture
# lets the silence outvote the speech, and the utterance is dropped in total
# silence -- the same "OLIV typed nothing and said nothing" failure the Bluetooth
# dead-lead-in produced. The energies below are MEASURED, not invented: a quiet
# room reads ~0.002 on the built-in mic, and real speech reads 0.028-0.040.


def _clip(*segments, sr: int = 16000):
    """Concatenate (rms, seconds) segments into one float32 capture."""
    return np.concatenate([_tone(rms, seconds, sr) for rms, seconds in segments])


@register("silence_short_utterance_in_a_long_hold_is_not_silent")
def _():
    # Held the key 30s (thinking, reading), then said one short thing. The speech
    # is unambiguous -- 0.03 is 6x the floor -- but averaged across 30s of room
    # tone the whole-clip mean lands at ~0.0043, under the 0.005 gate.
    clip = _clip((0.03, 0.5), (0.002, 29.5))
    mean_rms = float(np.sqrt(np.mean(np.square(clip), dtype=np.float64)))
    assert mean_rms < _SILENCE_RMS, mean_rms      # the whole-clip mean IS fooled
    assert _is_silent(clip) is False, "a clip with 0.5s of real speech is NOT silence"


@register("silence_soft_voice_short_clip_is_not_silent")
def _():
    # The everyday version: sitting back from the mic / speaking softly. 1s of
    # speech at 0.008 inside a normal 3s hold -- mean lands at ~0.0049, a hair
    # under the gate, and the whole utterance vanishes.
    clip = _clip((0.008, 1.0), (0.002, 2.0))
    mean_rms = float(np.sqrt(np.mean(np.square(clip), dtype=np.float64)))
    assert mean_rms < _SILENCE_RMS, mean_rms
    assert _is_silent(clip) is False, "a soft but real voice must not be cut"


@register("silence_lone_transient_is_still_silent")
def _():
    # The other side of the trade: going frame-wise must NOT make the gate a
    # pushover. A single loud click/pop (a Bluetooth profile switch, a key press)
    # inside an otherwise silent hold carries no speech and must still be gated --
    # otherwise it reaches Whisper and comes back as a hallucination.
    clip = _clip((0.002, 1.5), (0.5, 0.03), (0.002, 1.5))
    assert _is_silent(clip) is True, "one 30ms transient is not an utterance"


@register("silence_wav_path_never_gated")
def _():
    # benchmark clips arrive as a path, not an array -- never gate them
    assert _is_silent("/data/clips/hx19.wav") is False


@register("strip_pure_chinese_becomes_empty")
def _():
    # a pure-hallucination line collapses to empty -> handler treats as no_speech
    assert _strip_cjk("谢谢") == ""
    assert _strip_cjk("请不吝点赞订阅") == ""


@register("strip_kana_and_hangul_removed")
def _():
    assert _strip_cjk("ありがとう") == ""                      # Japanese kana
    assert _strip_cjk("감사합니다") == ""                        # Korean hangul


@register("strip_thai_and_english_untouched")
def _():
    # no CJK present -> returned byte-identical (common path, not even re-spaced)
    assert _strip_cjk("สวัสดีครับ ประชุมบ่ายสอง") == "สวัสดีครับ ประชุมบ่ายสอง"
    assert _strip_cjk("commit code แล้ว push ขึ้น repo") == "commit code แล้ว push ขึ้น repo"
    assert _strip_cjk("hello world") == "hello world"


@register("strip_mixed_keeps_real_words")
def _():
    # the whole point: a Chinese char riding along with real speech is removed,
    # the real words survive, and the leftover whitespace is tidied
    assert _strip_cjk("谢谢 ครับ") == "ครับ"                   # leading space trimmed
    assert _strip_cjk("push 谢谢 code") == "push code"         # inner gap collapsed
    assert _strip_cjk("ประชุม 会议 บ่ายสอง") == "ประชุม บ่ายสอง"


@register("strip_empty_and_digits_unchanged")
def _():
    assert _strip_cjk("") == ""
    assert _strip_cjk("2024") == "2024"                       # bare digits, no CJK


@register("no_speech_reply_shape")
def _():
    r = _no_speech_reply("req-1", "typhoon-turbo-mlx")
    assert r["ok"] is True and r["no_speech"] is True, r
    assert r["raw"] == "" and r["final"] == "", r
    assert r["id"] == "req-1" and r["engine"] == "typhoon-turbo-mlx", r
    assert r["gate_reason"] == "no_speech", r
    # parity: carries every field the client reads off a real dictate reply
    for k in ("stt_redecoded", "t_stt", "t_cleanup", "cleanup_error", "llm_ran",
              "guardrail_flag", "dict_hits", "t_llm", "fillers_removed",
              "replacements_fired", "format_commands_fired", "vocab_fired",
              "thai_format_fired"):
        assert k in r, f"missing {k}"


# End-to-end wiring through _handle("dictate", ...), all model-free: gate A short-
# circuits BEFORE any backend load; gate B + the pass-through case stub the backend
# + transcribe so no weights are touched (restored in finally).
def _pcm(arr) -> str:
    import base64
    return base64.b64encode(arr.astype(np.float32).tobytes()).decode()


@register("gate_A_handle_silent_returns_no_speech")
def _():
    import sidecar_server as ss
    rep = ss._handle({"cmd": "dictate", "id": "gA", "pcm_b64": _pcm(np.zeros(16000))})
    # reaching a no_speech reply at all proves gate A ran before _get_backend
    assert rep["no_speech"] is True and rep["raw"] == "" and rep["final"] == "", rep


@register("gate_B_handle_pure_cjk_returns_no_speech")
def _():
    # loud audio but the model emitted only Chinese -> strips to empty -> no_speech
    import sidecar_server as ss
    loud = _pcm(np.full(16000, 0.1))                 # clears gate A
    orig_b, orig_tx = ss._get_backend, ss._transcribe_maybe_redecode
    try:
        ss._get_backend = lambda engine: type("_B", (), {"seed_prompt": False})()
        ss._transcribe_maybe_redecode = lambda *a, **k: ("谢谢观看", False)
        rep = ss._handle({"cmd": "dictate", "id": "gB", "pcm_b64": loud})
    finally:
        ss._get_backend, ss._transcribe_maybe_redecode = orig_b, orig_tx
    assert rep["no_speech"] is True and rep["final"] == "", rep


@register("gate_B_handle_mixed_cjk_stripped_thai_kept")
def _():
    # a ghost Chinese char rode along with real Thai: strip the char, type the
    # Thai, do NOT gate -- and `raw` still reports the true STT output.
    import sidecar_server as ss
    loud = _pcm(np.full(16000, 0.1))
    orig_b, orig_tx = ss._get_backend, ss._transcribe_maybe_redecode
    try:
        ss._get_backend = lambda engine: type("_B", (), {"seed_prompt": False})()
        ss._transcribe_maybe_redecode = lambda *a, **k: ("谢谢 ประชุมบ่ายสอง", False)
        rep = ss._handle({"cmd": "dictate", "id": "gBm", "cleanup": False, "pcm_b64": loud})
    finally:
        ss._get_backend, ss._transcribe_maybe_redecode = orig_b, orig_tx
    assert rep.get("no_speech") is None, rep          # NOT gated -- real speech present
    assert rep["raw"] == "谢谢 ประชุมบ่ายสอง", rep       # raw stays the true STT output
    assert rep["final"] == "ประชุมบ่ายสอง", rep         # typed output is CJK-free


@register("gate_handle_real_speech_passes_through")
def _():
    # loud audio + a normal Thai transcript must NOT be gated -- neither A nor B
    # fires, and it flows through as an ordinary reply (no no_speech flag).
    import sidecar_server as ss
    loud = _pcm(np.full(16000, 0.1))
    orig_b, orig_tx = ss._get_backend, ss._transcribe_maybe_redecode
    try:
        ss._get_backend = lambda engine: type("_B", (), {"seed_prompt": False})()
        ss._transcribe_maybe_redecode = lambda *a, **k: ("ประชุมบ่ายสอง", False)
        rep = ss._handle({"cmd": "dictate", "id": "gC", "cleanup": False, "pcm_b64": loud})
    finally:
        ss._get_backend, ss._transcribe_maybe_redecode = orig_b, orig_tx
    assert rep.get("no_speech") is None, rep         # NOT gated
    assert rep["raw"] == "ประชุมบ่ายสอง" and rep["final"] == "ประชุมบ่ายสอง", rep


@register("thai_format_handle_flag_on_applies_pass_and_sets_counter")
def _():
    # With the request flag set, the Thai-formatting post-pass runs as the LAST
    # text pass on reply["final"] and reports its change count. cleanup:False keeps
    # this model-free (the gate-skip path the pass exists to cover).
    import sidecar_server as ss
    loud = _pcm(np.full(16000, 0.1))
    orig_b, orig_tx = ss._get_backend, ss._transcribe_maybe_redecode
    try:
        ss._get_backend = lambda engine: type("_B", (), {"seed_prompt": False})()
        ss._transcribe_maybe_redecode = lambda *a, **k: ("สี่สิบห้า", False)
        rep = ss._handle({"cmd": "dictate", "id": "tfOn", "cleanup": False,
                          "thai_format": True, "pcm_b64": loud})
    finally:
        ss._get_backend, ss._transcribe_maybe_redecode = orig_b, orig_tx
    assert rep["raw"] == "สี่สิบห้า", rep              # raw stays the true STT output
    assert rep["final"] == "45", rep                  # post-pass converted the number
    assert rep["thai_format_fired"] == 1, rep         # one converted number run


@register("thai_format_handle_flag_off_byte_identical_counter_zero")
def _():
    # With the flag absent the pass is never called: reply["final"] is byte-identical
    # to the cleaned text and the counter stays 0 (off-path passthrough contract).
    import sidecar_server as ss
    loud = _pcm(np.full(16000, 0.1))
    orig_b, orig_tx = ss._get_backend, ss._transcribe_maybe_redecode
    try:
        ss._get_backend = lambda engine: type("_B", (), {"seed_prompt": False})()
        ss._transcribe_maybe_redecode = lambda *a, **k: ("สี่สิบห้า", False)
        rep = ss._handle({"cmd": "dictate", "id": "tfOff", "cleanup": False,
                          "pcm_b64": loud})
    finally:
        ss._get_backend, ss._transcribe_maybe_redecode = orig_b, orig_tx
    assert rep["final"] == "สี่สิบห้า", rep            # untouched -- flag off
    assert rep["thai_format_fired"] == 0, rep         # counter present and zero


@register("thai_format_handle_apply_raises_keeps_transcript")
def _():
    # FIX #3b: if apply_thai_format raises at the sidecar boundary, the dictate must
    # NOT become ok:false and must NOT lose the transcript. reply["final"] stays the
    # pre-pass cleaned text and thai_format_fired is 0 (fail-safe, matching the
    # pipeline guardrail: cleanup never drops text -> the Swift client keeps typing).
    import sidecar_server as ss
    loud = _pcm(np.full(16000, 0.1))
    orig_b, orig_tx, orig_af = (ss._get_backend, ss._transcribe_maybe_redecode,
                                ss.apply_thai_format)

    def _boom(_text):
        raise RuntimeError("boom in apply_thai_format")

    try:
        ss._get_backend = lambda engine: type("_B", (), {"seed_prompt": False})()
        ss._transcribe_maybe_redecode = lambda *a, **k: ("สี่สิบห้า", False)
        ss.apply_thai_format = _boom
        rep = ss._handle({"cmd": "dictate", "id": "tfBoom", "cleanup": False,
                          "thai_format": True, "pcm_b64": loud})
    finally:
        (ss._get_backend, ss._transcribe_maybe_redecode,
         ss.apply_thai_format) = orig_b, orig_tx, orig_af
    assert rep["ok"] is True, rep                     # NOT turned into ok:false
    assert rep["final"] == "สี่สิบห้า", rep            # pre-pass transcript preserved
    assert rep["thai_format_fired"] == 0, rep         # fail-safe counter


# --------------------------------------------------------------------------- #
# Backend cache: an engine switch must evict the stale backend AND release the
# previous engine's weights BEFORE the new load (all local engines share
# mlx_whisper's single-slot ModelHolder — without the release, a switch holds
# two weight sets at peak and leaves the old buffers in MLX's cache).
# --------------------------------------------------------------------------- #
@register("engine_switch_evicts_stale_backend_and_releases_memory")
def _():
    import sidecar_server as ss
    import app.stt as stt

    built: list[str] = []
    released: list[bool] = []

    class _FakeBackend:
        def warm_up(self):
            return True

    orig_build, orig_release = stt.build_backend, ss._release_stt_memory
    orig_backends = dict(ss._BACKENDS)
    try:
        ss._BACKENDS.clear()
        stt.build_backend = lambda eng: (built.append(eng), _FakeBackend())[1]
        ss._release_stt_memory = lambda: released.append(True)

        a = ss._get_backend("eng-a")
        assert ss._get_backend("eng-a") is a, "same engine must reuse the cached backend"
        assert built == ["eng-a"], built
        assert released == [], "first load has nothing to evict — must not release"

        b = ss._get_backend("eng-b")
        assert "eng-a" not in ss._BACKENDS, "stale backend must be evicted on switch"
        assert ss._BACKENDS.get("eng-b") is b, ss._BACKENDS
        assert released == [True], "switch must release the previous engine's memory"
    finally:
        stt.build_backend = orig_build
        ss._release_stt_memory = orig_release
        ss._BACKENDS.clear()
        ss._BACKENDS.update(orig_backends)


# --------------------------------------------------------------------------- #
# Thai format pass: (A) reduplication -> ๆ  and  (B) spoken numbers -> Arabic.
# apply_thai_format(text) -> (formatted_text, n_changes). Deterministic post-pass
# that runs on BOTH the LLM path and the clean-thai gate-skip path.
# --------------------------------------------------------------------------- #
@register("thai_format_reduplication_positive")
def _():
    # adjacent identical real Thai words collapse to word+ๆ; 3+ -> a single ๆ.
    assert apply_thai_format("มากมาก") == ("มากๆ", 1)
    assert apply_thai_format("ตลอดตลอด") == ("ตลอดๆ", 1)
    assert apply_thai_format("มากมากมาก") == ("มากๆ", 1)          # 3+ collapse to one ๆ
    assert apply_thai_format("ดีดีเลย") == ("ดีๆเลย", 1)          # trailing token kept


@register("thai_format_reduplication_negatives")
def _():
    # single token (not a repeat) untouched
    assert apply_thai_format("จริงจัง") == ("จริงจัง", 0)
    # stoplist particles never collapse -- a stutter of these is not ๆ
    assert apply_thai_format("ไม่ไม่") == ("ไม่ไม่", 0)
    assert apply_thai_format("ที่ที่") == ("ที่ที่", 0)


@register("thai_format_reduplication_garble_not_collapsed")
def _():
    # a doubled NON-word (garble) must NOT be reduplicated -- the thai_words() gate.
    # Tested at the helper with a synthetic non-word token so the assertion is
    # independent of newmm's segmentation of an arbitrary garble.
    from thai_format import _THAI_WORDS
    garble = "ฟฟฟฟ"                                              # not a real Thai word
    assert garble not in _THAI_WORDS, "test premise: garble must be a non-word"
    assert _collapse_reduplication([garble, garble]) == ([garble, garble], 0)


@register("thai_format_reduplication_existing_yamok_not_doubled")
def _():
    # Cosmetic edge: if STT already emitted a literal ๆ after a doubled word
    # ("มากมากๆ" -> ['มาก','มาก','ๆ']), collapsing must NOT double the mark
    # ("มากๆๆ"). The run collapses to a bare token and the existing ๆ passes
    # through, yielding a single mark. Change still counts (the run WAS collapsed).
    assert apply_thai_format("มากมากๆ") == ("มากๆ", 1)
    # helper-level pin, independent of newmm segmentation
    assert _collapse_reduplication(["มาก", "มาก", "ๆ"]) == (["มาก", "ๆ"], 1)
    assert _collapse_reduplication(["ตลอด", "ตลอด", "ๆ"]) == (["ตลอด", "ๆ"], 1)


@register("thai_format_numbers_cardinal_positive")
def _():
    # maximal numeral runs with value >= 10 become Arabic digits
    assert apply_thai_format("สี่สิบห้า") == ("45", 1)
    assert apply_thai_format("เก้าสิบเก้า") == ("99", 1)


@register("thai_format_numbers_lone_small_stay_words")
def _():
    # lone 1-9 stay Thai so natural phrasing survives
    assert apply_thai_format("ขอสองแก้ว") == ("ขอสองแก้ว", 0)
    assert apply_thai_format("ครั้งหนึ่ง") == ("ครั้งหนึ่ง", 0)   # one token, words_to_num fails
    assert apply_thai_format("บ่ายสอง") == ("บ่ายสอง", 0)


@register("thai_format_numbers_version_decimal")
def _():
    # จุด flanked by numerals on BOTH sides => version/decimal, threshold-exempt
    assert apply_thai_format("สองจุดสี่จุดหนึ่ง") == ("2.4.1", 1)
    assert apply_thai_format("สองจุดห้า") == ("2.5", 1)           # < 10 yet converted (จุด path)
    # the common clean form tokenizes correctly and works
    assert apply_thai_format("เวอร์ชันสองจุดสี่จุดหนึ่ง") == ("เวอร์ชัน2.4.1", 1)


@register("thai_format_hidden_numeral_syllables_untouched")
def _():
    # words that merely CONTAIN a numeral syllable -- words_to_num fails on the
    # whole token, so they are left exactly as spoken.
    assert apply_thai_format("สามารถ") == ("สามารถ", 0)
    assert apply_thai_format("เก้าอี้") == ("เก้าอี้", 0)
    assert apply_thai_format("ห้าม") == ("ห้าม", 0)


@register("thai_format_existing_digits_left_glued")
def _():
    # D4: already-Arabic digits are not a numeral token (char filter) -> untouched,
    # and digits stay glued to Thai (no spacing logic).
    assert apply_thai_format("อายุ45ปี") == ("อายุ45ปี", 0)


@register("thai_format_short_circuit_no_thai")
def _():
    # no Thai char -> returned byte-identical, 0 changes, BEFORE any tokenize
    assert apply_thai_format("hello world") == ("hello world", 0)
    assert apply_thai_format("v2.4.1 build 12") == ("v2.4.1 build 12", 0)
    assert apply_thai_format("") == ("", 0)


@register("thai_format_whitespace_and_newline_preserved")
def _():
    # D6 order + byte-for-byte rebuild: the \n from a format command and the space
    # both survive; reduplication still fires inside.
    out, n = apply_thai_format("ประชุม\nมากมาก พรุ่งนี้")
    assert out == "ประชุม\nมากๆ พรุ่งนี้" and n == 1, (repr(out), n)


@register("thai_format_both_passes_and_count")
def _():
    # reduplication FIRST then numbers, both in one utterance -> two changes.
    assert apply_thai_format("มากมากสี่สิบห้า") == ("มากๆ45", 2)


@register("thai_format_known_limitation_glued_decimal_pinned")
def _():
    # KNOWN LIMITATION (documented, xfail-style pin): a decimal whose leading
    # digit-word is glued by newmm into the preceding Thai word (ที่สอง|จุด|ห้า)
    # is missed -- the จุด is not flanked by a numeral on its left, so no run
    # forms and the text is returned unchanged (it is NOT rewritten to 2.5).
    from pythainlp.tokenize import word_tokenize
    assert word_tokenize("ที่สองจุดห้า", engine="newmm", keep_whitespace=True) \
        == ["ที่สอง", "จุด", "ห้า"], "test premise: newmm glues the leading digit-word"
    out, n = apply_thai_format("ที่สองจุดห้า")
    assert (out, n) == ("ที่สองจุดห้า", 0), (out, n)              # missed, not 2.5 -- accepted


@register("thai_format_helpers_are_pure")
def _():
    # helpers operate on token lists / single tokens, independent of tokenization
    assert _collapse_reduplication(["ดี", "ดี", "เลย"]) == (["ดีๆ", "เลย"], 1)
    assert _collapse_reduplication(["ไม่", "ไม่"]) == (["ไม่", "ไม่"], 0)  # stoplist
    assert _convert_numbers(["สี่", "สิบห้า"]) == (["45"], 1)              # newmm split run
    assert _convert_numbers(["สอง", "แก้ว"]) == (["สอง", "แก้ว"], 0)       # lone < 10 kept
    assert _convert_numbers(["สอง", "จุด", "ห้า"]) == (["2.5"], 1)         # จุด path
    assert _num("สี่สิบห้า") == 45
    assert _num("จุด") is None and _num("สามารถ") is None


# --------------------------------------------------------------------------- #
# FIX #2: reduplication must NEVER touch a numeral word. Reduplication runs FIRST
# (D6); a repeated numeral (ศูนย์ศูนย์) turned into ๆ here would corrupt the number
# pass and drop the digit-run inside a decimal (1.001).
# --------------------------------------------------------------------------- #
@register("thai_format_reduplication_numerals_not_collapsed")
def _():
    # helper-level pin: doubled numeral words are NOT collapsed (the _num guard),
    # independent of newmm segmentation.
    assert _collapse_reduplication(["ศูนย์", "ศูนย์"]) == (["ศูนย์", "ศูนย์"], 0)
    assert _collapse_reduplication(["ห้า", "ห้า"]) == (["ห้า", "ห้า"], 0)
    assert _collapse_reduplication(["หนึ่ง", "หนึ่ง"]) == (["หนึ่ง", "หนึ่ง"], 0)
    # end-to-end: the digit-run survives so the decimal forms (Codex probe #2).
    assert apply_thai_format("หนึ่งจุดศูนย์ศูนย์หนึ่ง") == ("1.001", 1)
    # a real (non-numeral) doubled word still collapses -- FIX #2 didn't over-reach.
    assert apply_thai_format("มากมาก") == ("มากๆ", 1)


# --------------------------------------------------------------------------- #
# FIX #1: full digit-by-digit decimals. A multi-digit fraction after a single จุด
# is rendered digit-by-digit (zeros preserved); the integer part stays a CARDINAL.
# --------------------------------------------------------------------------- #
@register("thai_format_multidigit_decimal_positive")
def _():
    # Codex probes #1 + #2: the previously-broken multi-digit fractions now convert.
    assert apply_thai_format("สองจุดสี่ห้า") == ("2.45", 1)
    assert apply_thai_format("หนึ่งจุดศูนย์ศูนย์หนึ่ง") == ("1.001", 1)   # zeros preserved
    # integer part is a CARDINAL, not digit-by-digit: 45.5 (not 4.5.5)
    assert apply_thai_format("สี่สิบห้าจุดห้า") == ("45.5", 1)
    # helper-level pins over explicit token lists (independent of newmm)
    assert _convert_numbers(["สอง", "จุด", "สี่", "ห้า"]) == (["2.45"], 1)
    assert _convert_numbers(["หนึ่ง", "จุด", "ศูนย์", "ศูนย์", "หนึ่ง"]) == (["1.001"], 1)


@register("thai_format_multidigit_decimal_regressions_still_work")
def _():
    # the single-digit and version forms the unified model must NOT break
    assert apply_thai_format("สองจุดห้า") == ("2.5", 1)
    assert apply_thai_format("สองจุดสี่จุดหนึ่ง") == ("2.4.1", 1)
    assert apply_thai_format("ศูนย์จุดห้า") == ("0.5", 1)
    assert apply_thai_format("สี่สิบห้า") == ("45", 1)                    # no จุด, >= 10 rule
    assert apply_thai_format("เวอร์ชันสองจุดสี่จุดหนึ่ง") == ("เวอร์ชัน2.4.1", 1)
    # known limitation still pinned: newmm glues ที่สอง, so no run forms -> unchanged
    assert apply_thai_format("ที่สองจุดห้า") == ("ที่สองจุดห้า", 0)


# --------------------------------------------------------------------------- #
# FINDING A: a จุด-segment renders per its OWN tokens. Bare unit words (0-9, zeros
# significant) go DIGIT-BY-DIGIT; a segment carrying a place-value word (สิบ/ร้อย/..)
# is a spoken CARDINAL. The bug: [สี่,สิบห้า] (4 and 15, newmm's split of "สี่สิบห้า")
# was concatenated digit-wise to "415" instead of the cardinal 45.
# --------------------------------------------------------------------------- #
@register("thai_format_decimal_segment_cardinal_vs_digitwise")
def _():
    # the two cases the fix targets (previously "2.415" and — already ok — "2.20")
    assert apply_thai_format("สองจุดสี่สิบห้า") == ("2.45", 1)     # [สี่,สิบห้า] -> cardinal 45
    assert apply_thai_format("สองจุดยี่สิบ") == ("2.20", 1)        # [ยี่สิบ] -> cardinal 20
    # the digit-by-digit forms the per-segment rule must NOT break
    assert apply_thai_format("สองจุดสี่ห้า") == ("2.45", 1)         # [สี่,ห้า] -> "45"
    assert apply_thai_format("หนึ่งจุดศูนย์ศูนย์หนึ่ง") == ("1.001", 1)  # zeros preserved
    assert apply_thai_format("สองจุดห้า") == ("2.5", 1)
    assert apply_thai_format("สองจุดสี่จุดหนึ่ง") == ("2.4.1", 1)
    assert apply_thai_format("ศูนย์จุดห้า") == ("0.5", 1)
    assert apply_thai_format("สี่สิบห้าจุดห้า") == ("45.5", 1)       # int part stays cardinal
    assert apply_thai_format("สี่สิบห้า") == ("45", 1)              # no จุด, >= 10 rule
    # known-limitation pin stays: newmm glues ที่สอง -> no run -> unchanged
    assert apply_thai_format("ที่สองจุดห้า") == ("ที่สองจุดห้า", 0)
    # helper-level pins over explicit token lists (independent of newmm segmentation)
    assert _convert_numbers(["สอง", "จุด", "สี่", "สิบห้า"]) == (["2.45"], 1)   # cardinal seg
    assert _convert_numbers(["สอง", "จุด", "ยี่สิบ"]) == (["2.20"], 1)         # cardinal seg
    assert _convert_numbers(["สอง", "จุด", "สี่", "ห้า"]) == (["2.45"], 1)      # digit-wise
    assert _convert_numbers(["หนึ่ง", "จุด", "ศูนย์", "ศูนย์", "หนึ่ง"]) == (["1.001"], 1)
    # the per-segment helper in isolation
    from thai_format import _render_decimal_segment
    assert _render_decimal_segment(["สี่", "ห้า"]) == "45"          # (1) digit-by-digit
    assert _render_decimal_segment(["ศูนย์", "ศูนย์", "หนึ่ง"]) == "001"  # zeros significant
    assert _render_decimal_segment(["สี่", "สิบห้า"]) == "45"       # (2) cardinal
    assert _render_decimal_segment(["ยี่สิบ"]) == "20"             # (2) cardinal


# --------------------------------------------------------------------------- #
# FIX #3a: the number pass is TOTAL -- a pathological numeral run must not raise
# (Python's int->str >4300-digit cap) and must never lose the transcript; it
# degrades to the original Thai tokens (the _MAX_NUM_RUN cap + str() guard).
# --------------------------------------------------------------------------- #
@register("thai_format_pathological_run_never_raises_or_drops")
def _():
    huge = "หนึ่งล้าน" * 800                  # ~1600 numeral tokens (Codex probe #3)
    out, n = apply_thai_format(huge)         # MUST NOT raise
    assert out == huge, "pathological run must degrade to verbatim, never lose text"
    assert n == 0, n                          # over the cap -> nothing converted
    # a run right below the cap still converts normally (cap didn't over-reach)
    assert _convert_numbers(["สี่", "สิบ", "ห้า"]) == (["45"], 1)


# --------------------------------------------------------------------------- #
# Option B: thread-safe Gemma load (pipeline._ensure_model double-checked lock)
# + background cleanup warm in the sidecar (STT sync, Gemma on a daemon thread).
# All model-free: the loader is a fake mlx_lm injected into sys.modules, and the
# sidecar warm is exercised with stub backend/pipeline (no real weights).
# --------------------------------------------------------------------------- #
class _FakeTok:
    """A tokenizer stub for pipeline._build_prompt (warm_load's prime step calls
    tok.apply_chat_template); returns a fixed prompt string, no real template."""

    def apply_chat_template(self, *a, **k):
        return "PRIME_PROMPT"


class _FakeMLX:
    """Install a fake `mlx_lm` (+ mlx_lm.sample_utils) into sys.modules so
    pipeline._ensure_model / warm_load's inner `from mlx_lm import load, generate` /
    `from mlx_lm.sample_utils import make_sampler` resolve to counted, slow stubs --
    exercising the double-checked lock (and the load+prime-under-lock in warm_load)
    without loading real weights. Restores the prior sys.modules entries on exit."""

    def __init__(self, load_sleep: float = 0.2, generate_sleep: float = 0.0,
                 generate_entered=None, generate_release=None, generate_boom: bool = False):
        self.load_sleep = load_sleep
        self.generate_sleep = generate_sleep
        # Optional prime (generate) controls for the publish-order tests:
        #   generate_entered -- Event set the instant the prime generate is entered.
        #   generate_release -- Event the prime generate blocks on before returning.
        #   generate_boom    -- raise inside the prime generate (simulates a prime failure).
        self.generate_entered = generate_entered
        self.generate_release = generate_release
        self.generate_boom = generate_boom
        self.load_calls = 0
        self.generate_calls = 0
        self._saved = {}

    def __enter__(self):
        for k in ("mlx_lm", "mlx_lm.sample_utils"):
            self._saved[k] = sys.modules.get(k)
        fake = types.ModuleType("mlx_lm")

        def _load(model_id):
            time.sleep(self.load_sleep)
            self.load_calls += 1
            return object(), _FakeTok()   # (model, tok)

        def _generate(model, tok, **k):
            if self.generate_entered is not None:
                self.generate_entered.set()   # signal: the prime is in progress
            if self.generate_boom:
                raise RuntimeError("prime boom")   # simulate a prime failure (before any count)
            if self.generate_release is not None:
                self.generate_release.wait(5.0)    # hold the prime open until the test releases it
            time.sleep(self.generate_sleep)
            self.generate_calls += 1
            return "OUT"

        fake.load = _load
        fake.generate = _generate
        sample = types.ModuleType("mlx_lm.sample_utils")
        sample.make_sampler = lambda temp=0.0: object()
        fake.sample_utils = sample
        sys.modules["mlx_lm"] = fake
        sys.modules["mlx_lm.sample_utils"] = sample
        return self

    def __exit__(self, *exc):
        for k, v in self._saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
        return False


def _reset_pipeline_model(pipeline):
    pipeline._MODEL = None
    pipeline._TOK = None
    pipeline._SAMPLER = None
    pipeline.LOAD_TIME = None


@register("pipeline_ensure_model_loads_once_under_concurrency")
def _():
    import pipeline
    saved = (pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME)
    try:
        _reset_pipeline_model(pipeline)
        with _FakeMLX(load_sleep=0.2) as fake:
            results: list = []
            barrier = threading.Barrier(2)

            def worker():
                barrier.wait()   # maximize overlap on the load window
                results.append(pipeline._ensure_model())

            threads = [threading.Thread(target=worker) for _ in range(2)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=5)

            assert fake.load_calls == 1, f"load body ran {fake.load_calls}x, expected exactly 1"
            assert len(results) == 2, results
            m0, tok0, s0 = results[0]
            for m, tok, s in results:
                assert m is m0 and tok is tok0 and s is s0, "callers must get the SAME triple"
                assert m is not None and tok is not None and s is not None, "no None in triple"
            assert pipeline.LOAD_TIME is not None, "LOAD_TIME must be recorded"
    finally:
        pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME = saved


@register("pipeline_ensure_model_publishes_model_last")
def _():
    # While the (slow) load runs, a hammer thread reading the globals must NEVER
    # see _MODEL non-None beside a None _TOK / _SAMPLER -- the publish-last order.
    import pipeline
    saved = (pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME)
    try:
        _reset_pipeline_model(pipeline)
        with _FakeMLX(load_sleep=0.3):
            observed_bad: list = []
            stop = threading.Event()

            def hammer():
                while not stop.is_set():
                    m = pipeline._MODEL
                    if m is not None and (pipeline._TOK is None or pipeline._SAMPLER is None):
                        observed_bad.append((pipeline._TOK, pipeline._SAMPLER))
                        return

            h = threading.Thread(target=hammer)
            h.start()
            pipeline._ensure_model()
            stop.set()
            h.join(timeout=5)
            assert not observed_bad, f"half-initialized triple observed: {observed_bad}"
            assert pipeline._MODEL is not None and pipeline._TOK is not None
    finally:
        pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME = saved


@register("pipeline_warm_load_loads_primes_and_publishes_last")
def _():
    # warm_load loads AND primes (one generate) under the lock, publishing _MODEL
    # last; idempotent.
    import pipeline
    saved = (pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME)
    try:
        _reset_pipeline_model(pipeline)
        with _FakeMLX(load_sleep=0.1) as fake:
            pipeline.warm_load()
            assert fake.load_calls == 1, fake.load_calls
            assert fake.generate_calls == 1, "warm_load must PRIME (one generate)"
            assert pipeline._MODEL is not None, "model published"
            assert pipeline._TOK is not None and pipeline._SAMPLER is not None
            assert pipeline.LOAD_TIME is not None
            # idempotent: a second call neither reloads nor re-primes
            pipeline.warm_load()
            assert fake.load_calls == 1 and fake.generate_calls == 1
    finally:
        pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME = saved


@register("pipeline_warm_load_and_ensure_model_coordinate_one_load")
def _():
    # warm_load holds _MODEL_LOCK across load+prime; a concurrent _ensure_model
    # (a code-switched dictate lazy-load) must BLOCK on the lock and NOT trigger a
    # second load -- exactly one load, both see the same published model.
    import pipeline
    saved = (pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME)
    try:
        _reset_pipeline_model(pipeline)
        with _FakeMLX(load_sleep=0.3, generate_sleep=0.2) as fake:
            got: list = []

            def dictator():
                time.sleep(0.05)   # let warm_load grab the lock first
                got.append(pipeline._ensure_model())

            t = threading.Thread(target=dictator)
            t.start()
            pipeline.warm_load()
            t.join(timeout=5)
            assert fake.load_calls == 1, f"expected one load, got {fake.load_calls}"
            assert got and got[0][0] is pipeline._MODEL, "dictate got the published model"
            assert pipeline._MODEL is not None
    finally:
        pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME = saved


@register("pipeline_warm_load_keeps_model_unpublished_during_prime")
def _():
    # THE crash-sensitive invariant (second-eye): _MODEL must stay UNPUBLISHED for
    # the whole priming generate. If _MODEL were published BEFORE the prime, a dictate
    # arriving mid-prime would take the lock-free fast path and run a SECOND MLX
    # generate concurrent with the prime -- the documented "Stream(gpu,N)" crash. This
    # test blocks INSIDE the prime and proves (a) _MODEL is still None and (b) a
    # concurrent _ensure_model stays blocked until the prime is released. Move
    # `_MODEL = model` above the prime generate in pipeline.warm_load and this FAILS.
    import pipeline
    saved = (pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME)
    entered, release = threading.Event(), threading.Event()
    try:
        _reset_pipeline_model(pipeline)
        with _FakeMLX(load_sleep=0.0, generate_entered=entered,
                      generate_release=release) as fake:
            errs: list = []

            def warmer():
                try:
                    pipeline.warm_load()
                except Exception as e:            # pragma: no cover - failure path
                    errs.append(e)

            wt = threading.Thread(target=warmer)
            wt.start()
            assert entered.wait(3.0), "prime generate never started"
            # DURING the prime: nothing may be published yet.
            assert pipeline._MODEL is None, "MODEL published BEFORE the prime finished"
            # A concurrent dictate lazy-load must be BLOCKED on _MODEL_LOCK (its fast
            # path cannot fire while _MODEL is None), not fast-path onto a half-ready model.
            got: list = []
            dt = threading.Thread(target=lambda: got.append(pipeline._ensure_model()))
            dt.start()
            time.sleep(0.15)
            assert not got, "_ensure_model returned mid-prime (fast-pathed on an early publish!)"
            assert pipeline._MODEL is None
            # Release the prime -> warm_load publishes _MODEL last -> both proceed.
            release.set()
            wt.join(3.0)
            dt.join(3.0)
            assert not errs, errs
            assert pipeline._MODEL is not None and pipeline._TOK is not None \
                and pipeline._SAMPLER is not None, "publish incomplete after prime"
            assert got and got[0][0] is pipeline._MODEL, "dictate got the published model"
            assert fake.load_calls == 1 and fake.generate_calls == 1, (fake.load_calls, fake.generate_calls)
    finally:
        release.set()   # never wedge a thread if an assertion fired mid-prime
        pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME = saved


@register("pipeline_warm_load_prime_failure_leaves_all_unpublished")
def _():
    # If the prime raises, warm_load must leave _MODEL / _TOK / _SAMPLER ALL unpublished
    # (None) so the request loop's own _ensure_model reloads cleanly on-thread. Guards
    # the rollback path second-eye flagged as untested.
    import pipeline
    saved = (pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME)
    try:
        _reset_pipeline_model(pipeline)
        with _FakeMLX(load_sleep=0.0, generate_boom=True) as fake:
            raised = False
            try:
                pipeline.warm_load()
            except RuntimeError:
                raised = True
            assert raised, "warm_load must propagate the prime failure"
            assert pipeline._MODEL is None and pipeline._TOK is None \
                and pipeline._SAMPLER is None, "prime failure left a partial publish"
            assert fake.load_calls == 1 and fake.generate_calls == 0, (fake.load_calls, fake.generate_calls)
        # Lazy path reloads cleanly afterwards (fresh fake, prime OK).
        with _FakeMLX(load_sleep=0.0) as fake2:
            m, tok, samp = pipeline._ensure_model()
            assert m is not None and pipeline._MODEL is m and tok is not None and samp is not None
            assert fake2.load_calls == 1, f"lazy reload should load once, got {fake2.load_calls}"
    finally:
        pipeline._MODEL, pipeline._TOK, pipeline._SAMPLER, pipeline.LOAD_TIME = saved


class _StubPipe:
    """A pipeline stand-in for the sidecar warm tests. The ASYNC bg path calls
    warm_load (slow + counted; `boom` makes it raise a bg-failure); the SYNC path
    calls _ensure_model (slow) + clean_ex (no-op)."""

    def __init__(self, sleep: float = 0.4, boom: bool = False):
        self.sleep = sleep
        self.boom = boom
        self.ensure_calls = 0
        self.warm_calls = 0

    def warm_load(self):
        if self.boom:
            raise RuntimeError("no model files")
        time.sleep(self.sleep)
        self.warm_calls += 1

    def _ensure_model(self):
        time.sleep(self.sleep)
        self.ensure_calls += 1

    def clean_ex(self, text, vocab=None):
        return None


def _with_stub_sidecar(stub, fn):
    """Run fn() with ss._get_backend / ss._get_pipeline stubbed and the one-shot
    _BG_WARM_STARTED reset; restore everything in finally."""
    import sidecar_server as ss
    orig_b, orig_p = ss._get_backend, ss._get_pipeline
    ss._BG_WARM_STARTED = False
    try:
        ss._get_backend = lambda engine: object()
        ss._get_pipeline = lambda: stub
        return fn(ss)
    finally:
        ss._get_backend, ss._get_pipeline = orig_b, orig_p
        ss._BG_WARM_STARTED = False


@register("warm_background_cleanup_returns_promptly_loads_once")
def _():
    stub = _StubPipe(sleep=0.5)

    def body(ss):
        t0 = time.perf_counter()
        rep = ss._handle({"cmd": "warm", "id": "w1", "cleanup": True,
                          "background_cleanup": True})
        elapsed = time.perf_counter() - t0
        # Returned WITHOUT blocking on the 0.5s Gemma load.
        assert elapsed < 0.3, f"async warm blocked {elapsed:.2f}s on the load"
        assert rep["ok"] is True, rep
        assert rep["t_cleanup_load"] == 0.0, rep
        assert rep["cleanup_warming"] is True, rep
        assert "t_stt_load" in rep, rep
        # The loader thread runs warm_load exactly once, in the background.
        dl = time.time() + 5
        while stub.warm_calls < 1 and time.time() < dl:
            time.sleep(0.02)
        assert stub.warm_calls == 1, f"loader ran {stub.warm_calls}x, expected 1"

    _with_stub_sidecar(stub, body)


@register("warm_background_cleanup_duplicate_guard")
def _():
    stub = _StubPipe(sleep=0.4)

    def body(ss):
        r1 = ss._handle({"cmd": "warm", "id": "w1", "cleanup": True,
                         "background_cleanup": True})
        # Immediately a second warm with the flag: the one-shot guard must NOT
        # spawn a second loader (it returns promptly, still reports warming).
        r2 = ss._handle({"cmd": "warm", "id": "w2", "cleanup": True,
                         "background_cleanup": True})
        assert r1["cleanup_warming"] is True and r2["cleanup_warming"] is True, (r1, r2)
        dl = time.time() + 5
        while stub.warm_calls < 1 and time.time() < dl:
            time.sleep(0.02)
        time.sleep(0.4)   # give any erroneous second loader time to also increment
        assert stub.warm_calls == 1, f"expected exactly one loader, got {stub.warm_calls}"

    _with_stub_sidecar(stub, body)


@register("warm_sync_path_unchanged_and_blocks")
def _():
    stub = _StubPipe(sleep=0.3)

    def body(ss):
        # No flag: sync warm BLOCKS on the load and the reply is byte-identical to
        # today (exact key set, t_cleanup_load timed, NO cleanup_warming).
        t0 = time.perf_counter()
        rep = ss._handle({"cmd": "warm", "id": "ws", "cleanup": True})
        elapsed = time.perf_counter() - t0
        assert elapsed >= 0.3, f"sync warm did not block on the load ({elapsed:.2f}s)"
        assert set(rep.keys()) == {"id", "ok", "engine", "t_stt_load", "t_cleanup_load"}, rep
        assert rep["t_cleanup_load"] > 0, rep
        assert "cleanup_warming" not in rep, rep
        # cleanup:false -> t_cleanup_load 0.0, no new key (unchanged from today).
        rep2 = ss._handle({"cmd": "warm", "id": "wf", "cleanup": False})
        assert set(rep2.keys()) == {"id", "ok", "engine", "t_stt_load", "t_cleanup_load"}, rep2
        assert rep2["t_cleanup_load"] == 0.0 and "cleanup_warming" not in rep2, rep2
        # background_cleanup WITH cleanup:false is ignored -> sync path, no Gemma,
        # byte-identical reply (no cleanup_warming, no loader spawned).
        rep3 = ss._handle({"cmd": "warm", "id": "wbf", "cleanup": False,
                           "background_cleanup": True})
        assert set(rep3.keys()) == {"id", "ok", "engine", "t_stt_load", "t_cleanup_load"}, rep3
        assert rep3["t_cleanup_load"] == 0.0 and "cleanup_warming" not in rep3, rep3
        assert ss._BG_WARM_STARTED is False, "cleanup:false must not start a loader"

    _with_stub_sidecar(stub, body)


@register("warm_background_cleanup_failure_is_nonfatal")
def _():
    stub = _StubPipe(boom=True)

    def body(ss):
        rep = ss._handle({"cmd": "warm", "id": "wb", "cleanup": True,
                          "background_cleanup": True})
        # A failing bg load must NOT fail the warm: it still returns ok + warming.
        assert rep["ok"] is True and rep["cleanup_warming"] is True, rep
        time.sleep(0.3)   # let the bg thread run, raise, and log to stderr
        # The request loop keeps working afterward (the bg thread can't crash it).
        pong = ss._handle({"cmd": "ping", "id": "pg"})
        assert pong["ok"] is True and "pid" in pong, pong

    _with_stub_sidecar(stub, body)


if __name__ == "__main__":
    print(f"running {len(CASES)} hermetic text-pass cases\n")
    for c in CASES:
        c()
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed of {len(CASES)}")
    if FAILED:
        print("\nFailures:")
        for name, msg in FAILED:
            print(f"  {name}: {msg}")
        sys.exit(1)
    print("ALL PASS")
