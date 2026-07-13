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
              "replacements_fired", "format_commands_fired", "vocab_fired"):
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
