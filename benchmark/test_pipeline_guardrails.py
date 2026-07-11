"""Tests for pipeline._guardrail — the correctness-critical fallback (W2-T2).

Plain asserts, no pytest. Run:  .venv/bin/python test_pipeline_guardrails.py
Must pass in BOTH benchmark/.venv and benchmark/.venv-gemma4.

NO model is ever loaded: guardrail cases call pipeline._guardrail directly; the
one end-to-end case monkeypatches pipeline._ensure_model (no-op) and
pipeline._llm_generate (bogus generation) so clean_ex runs without an LLM.

Guardrail contract (fallback target = dict_text, the post-dictionary LLM input):
    empty->dict / tooShort->dict / tooLong->dict   pre-existing clamps
    spanLoss->dict   R1: a Latin span the dictionary produced did not survive
    editDist->dict   R2: the candidate diverged from dict_text's Thai content
The bad-pair set + thresholds were calibrated so R1/R2 fire on ZERO of the 145
cached good generations; the full-cache sweep below is that calibration proof.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline
from pipeline import _guardrail, normalize_thai_spacing as nz

_HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(_HERE, "_clean_cache_dict.json"), encoding="utf-8") as f:
    GOOD_CACHE = json.load(f)  # {"base|clip": {dict_in, raw_gen, t_llm}} -- known good

# The real v1-era th05 hallucination (reconstructed): pure-Thai input, meaning
# mangled + English injected, same rough length -> the token clamp misses it.
TH05_DICT = "เรื่องนี้ต้องรีบตัดสินใจก่อนสิ้นสัปดาห์ ไม่งั้นจะไม่ทัน"
TH05_GEN = ("เราต้อง approve ก่อน deadline ไม่งั้นจะไม่ได้ deploy ก่อนสิ้นเดือน\n"
            "<end_of_turn><end_of_turn>")

PASSED = []
FAILED = []
CASES = []


def case(name):
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
        run.__name__ = name
        return run
    return deco


def register(name):
    def deco(fn):
        CASES.append(case(name)(fn))
        return fn
    return deco


def _fires(dict_text, gen, flag):
    """Assert _guardrail returns (dict_text, flag) -- i.e. it fell back."""
    final, got = _guardrail(dict_text, gen)
    assert got == flag, f"flag={got!r} want {flag!r}"
    assert final == dict_text, f"fallback text != dict_text: {final!r}"


def _passes(dict_text, gen):
    """Assert _guardrail accepts the (stop-stripped) generation."""
    final, got = _guardrail(dict_text, gen)
    assert got == "ok", f"flag={got!r} want 'ok'  (final={final!r})"
    return final


# ---------------------------------------------------------------------------
# Pre-existing guardrails still fire
# ---------------------------------------------------------------------------
@register("preexisting_empty")
def _():
    _fires("restart the server now", "   <end_of_turn>", "empty->dict")
    _fires("เปิด Grafana ดู log", "", "empty->dict")


@register("preexisting_tooShort")
def _():
    _fires("รีสตาร์ท server แล้วเช็ค log ในระบบ dashboard ตอนนี้เลย", "server", "tooShort->dict")


@register("preexisting_tooLong")
def _():
    _fires("เปิด Grafana", "เปิด Grafana " * 20, "tooLong->dict")


# ---------------------------------------------------------------------------
# R1 — spanLoss->dict
# ---------------------------------------------------------------------------
@register("r1_span_dropped")
def _():
    # Grafana silently deleted from the output.
    _fires("restart Grafana dashboard ครับ", "restart dashboard ครับ", "spanLoss->dict")


@register("r1_span_substituted")
def _():
    # Grafana -> Kibana : a real Latin substitution (edit distance > 1).
    _fires("เปิด Grafana ดู log ครับ", "เปิด Kibana ดู log ครับ", "spanLoss->dict")


@register("r1_latin_translated_to_thai")
def _():
    # latency re-Thai-ified back to เลเทนซี่ -- the exact regression R1 guards.
    _fires("ค่า latency เกิน threshold นะ", "ค่า เลเทนซี่ เกิน threshold นะ", "spanLoss->dict")


@register("r1_short_span_mutation_UI_UX")
def _():
    # short spans get no edit-distance slack; UI -> UX must fire.
    _fires("ทีม design เรื่อง UI ก่อน", "ทีม design เรื่อง UX ก่อน", "spanLoss->dict")


@register("r1_legit_recase_and_merge_pass")
def _():
    # re-casing and merge/split around the same letters are NOT losses.
    _passes("จาก google present วันจันทร์", "จาก Google present วันจันทร์")
    _passes("ตัว null pointer exception นะ", "ตัว NullPointerException นะ")


# ---------------------------------------------------------------------------
# R2 — editDist->dict  (same-length rewrites the token clamp misses)
# ---------------------------------------------------------------------------
@register("r2_th05_real_hallucination")
def _():
    # The canonical v1 case. No Latin in the input, so R1 has nothing to catch;
    # R2 fires on the 3 lost genuine Thai words (ตัดสินใจ, สัปดาห์, เรื่อง).
    _fires(TH05_DICT, TH05_GEN, "editDist->dict")


@register("r2_synthetic_thai_body_rewrite")
def _():
    # Pure Thai -> different pure Thai of the same length (no Latin either side):
    # R1 is silent, R2 catches the wholesale content swap.
    _fires("พรุ่งนี้ประชุมทีมเรื่องงบประมาณโครงการใหม่",
           "เมื่อวานสัมมนากลุ่มหัวข้อการตลาดสินค้าเดิม", "editDist->dict")


@register("r2_synthetic_blanket_english_injection")
def _():
    # The "A/B testing" blanket hallucination: Thai content replaced by injected
    # English + invented Thai.
    _fires("ช่วยสรุปประเด็นสำคัญของการประชุมเมื่อเช้าให้หน่อย",
           "เราจะทำ A/B testing เพื่อเพิ่ม accuracy ของโมเดล", "editDist->dict")


@register("r2_heavy_legit_detranslit_passes")
def _():
    # Heavy but LEGIT de-transliteration must pass ok -- real cached good pairs.
    # mx03: model/accuracy/fine-tune/evaluate kept; tc04: 4 Thai translit tokens
    # (โรว์ แบ็ค ดีพอยท์ เม้นท์) -> "roll back deployment".
    for key in ("pathumma|mx03", "pathumma|tc04", "pathumma|tc03"):
        v = GOOD_CACHE[key]
        _passes(v["dict_in"], v["raw_gen"])


# ---------------------------------------------------------------------------
# End-to-end: fallback text == dict_text, and the final text is spacing-normalized
# ---------------------------------------------------------------------------
@register("e2e_fallback_is_dicttext_and_spacing_normalized")
def _():
    saved_ensure, saved_gen = pipeline._ensure_model, pipeline._llm_generate
    try:
        pipeline._ensure_model = lambda: (None, None, None)   # never load a model
        pipeline._llm_generate = lambda text, hints=None: "เปิด หน้า ดู ค่า"  # drops Grafana
        r = pipeline.clean_ex("เปิด กราฟา หน้า ดู ค่า")  # กราฟา -> Grafana (dict hit)
    finally:
        pipeline._ensure_model, pipeline._llm_generate = saved_ensure, saved_gen
    assert r.llm_ran, "gate should have run the LLM (dict-hit)"
    assert r.guardrail_flag == "spanLoss->dict", r.guardrail_flag
    assert r.dict_text == "เปิด Grafana หน้า ดู ค่า", repr(r.dict_text)
    # normalize_thai_spacing runs LAST on the fallback path too: final ==
    # nz(dict_text), Thai-Thai spaces collapsed, English spacing kept.
    assert r.text == nz(r.dict_text), f"text != nz(dict_text): {r.text!r}"
    assert r.text == "เปิด Grafana หน้าดูค่า", repr(r.text)
    assert r.text != r.dict_text, "spacing was not normalized"


# ---------------------------------------------------------------------------
# Calibration proof: ZERO guardrail fires across every cached good generation.
# Runs in < 5s, no model. This is what pins R1/R2 to zero false positives.
# ---------------------------------------------------------------------------
@register("calibration_full_cache_zero_fires")
def _():
    fired = []
    for key, v in GOOD_CACHE.items():
        _final, flag = _guardrail(v["dict_in"], v["raw_gen"])
        if flag != "ok":
            fired.append((key, flag))
    assert not fired, f"guardrail fired on {len(fired)} known-good pairs: {fired[:8]}"
    assert len(GOOD_CACHE) >= 60, f"cache unexpectedly small: {len(GOOD_CACHE)}"


if __name__ == "__main__":
    print(f"running {len(CASES)} test cases\n")
    for c in CASES:
        c()
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed of {len(CASES)}")
    if FAILED:
        print("\nFailures:")
        for name, msg in FAILED:
            print(f"  {name}: {msg}")
        sys.exit(1)
    print("ALL PASS")
