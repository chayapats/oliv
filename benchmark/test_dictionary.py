"""Tests for dictionary.apply_dictionary — precision-first boundary safety.

Plain asserts, no pytest. Run:  .venv/bin/python test_dictionary.py
Positive cases use real Pathumma hypotheses loaded from results_local.json.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dictionary import apply_dictionary

_RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results_local.json")
with open(_RESULTS, encoding="utf-8") as f:
    _DATA = json.load(f)
HYP = {d["id"]: d["hypothesis"] for d in _DATA if d["engine"] == "pathumma" and d["lang"] == "auto"}
HYP_TH = {d["id"]: d["hypothesis"] for d in _DATA if d["engine"] == "pathumma" and d["lang"] == "th"}

PASSED = []
FAILED = []


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


CASES = []


def register(name):
    def deco(fn):
        CASES.append(case(name)(fn))
        return fn
    return deco


def _no_double_space(out):
    assert "  " not in out, f"double space in: {out!r}"


# ---------------------------------------------------------------------------
# Positive: real Pathumma hypotheses get fixed
# ---------------------------------------------------------------------------

@register("pos_mx02_meeting_sharescreen_present")
def _():
    out, hits = apply_dictionary(HYP["mx02"])
    for en in ("meeting", "share screen", "present"):
        assert en in out, f"{en!r} missing: {out}"
    for th in ("มีตติ้ง", "แชร์สกรีน", "พรีเซนต์"):
        assert th not in out, f"{th!r} still present: {out}"
    # Thai run must stay glued (no space inserted between Thai runs)
    assert "บ่ายสองเลื่อนเป็นบ่ายสามได้ไหม" in out, out
    assert hits == 3, hits
    _no_double_space(out)


@register("pos_mx15_budget")
def _():
    out, hits = apply_dictionary(HYP["mx15"])
    assert "budget" in out and "บัดเจ็ต" not in out, out
    assert "service" in out and "เซอร์วิส" not in out, out
    assert "คัดคอร์ส" in out, f"garbled คัดคอร์ส must stay for LLM: {out}"
    assert hits == 2, hits
    _no_double_space(out)


@register("pos_tc03_endpoint")
def _():
    out, hits = apply_dictionary(HYP["tc03"])
    for en in ("API", "endpoint", "return", "status", "exception"):
        assert en in out, f"{en!r} missing: {out}"
    assert "เอ็นพอยต์" not in out, out
    assert "นูพอยเตอร์" in out, f"garbled นูพอยเตอร์ must stay for LLM: {out}"
    assert hits == 5, hits
    _no_double_space(out)


@register("pos_mx20_stakeholder")
def _():
    out, hits = apply_dictionary(HYP["mx20"])
    for en in ("demo", "stakeholder", "approve", "launch"):
        assert en in out, f"{en!r} missing: {out}"
    assert "สเต็กโฮเดอร์" not in out, out
    assert "โพเตอร์ไทย" in out, f"โพเตอร์ไทย (contains ไทย) must stay: {out}"
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_tc10_feature_flag_not_fax")
def _():
    out, hits = apply_dictionary(HYP["tc10"])
    assert "feature flag" in out, out
    assert "แฟ็กซ์" not in out and "fax" not in out.lower(), out
    for en in ("user", "segment", "A/B testing"):
        assert en in out, f"{en!r} missing: {out}"
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_tc01_kubernetes_but_port_stays")
def _():
    out, hits = apply_dictionary(HYP["tc01"])
    assert "Kubernetes" in out and "คิวเบอร์เน็ต" not in out, out
    assert "พอร์ต" in out, f"พอร์ต must survive adjacent to Kubernetes: {out}"
    assert "pod" not in out, f"พอร์ต must never become pod: {out}"
    assert "ล็อก" in out, f"ล็อก stays for LLM: {out}"
    assert "หน้า" in out, f"หน้า is keep-Thai: {out}"
    for en in ("restart", "Grafana", "dashboard"):
        assert en in out, f"{en!r} missing: {out}"
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_mx09_restart_server_lok_stays")
def _():
    out, hits = apply_dictionary(HYP["mx09"])
    for en in ("restart", "server", "Grafana", "memory leak"):
        assert en in out, f"{en!r} missing: {out}"
    assert "หลอก" in out, f"หลอก (real word) must never become log: {out}"
    assert "log" not in out, out
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_mx05_work_from_home")
def _():
    out, hits = apply_dictionary(HYP["mx05"])
    for en in ("traffic", "work from home", "standup"):
        assert en in out, f"{en!r} missing: {out}"
    assert "ซูม" in out, f"ซูม (short/ambiguous) stays for LLM: {out}"
    assert hits == 3, hits
    _no_double_space(out)


@register("pos_tc11_containerize_app")
def _():
    out, hits = apply_dictionary(HYP["tc11"])
    for en in ("containerize", "app", "Docker", "deploy", "Kubernetes", "cluster"):
        assert en in out, f"{en!r} missing: {out}"
    assert hits == 6, hits
    _no_double_space(out)


@register("pos_mx07_threshold_query_database")
def _():
    out, hits = apply_dictionary(HYP["mx07"])
    for en in ("threshold", "optimize", "query", "database"):
        assert en in out, f"{en!r} missing: {out}"
    assert "พีเก้าเก้า" in out, f"พีเก้าเก้า stays for LLM: {out}"
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_tc09_config_twice")
def _():
    out, hits = apply_dictionary(HYP["tc09"])
    assert out.count("config") == 2, out
    for en in ("merge", "resolve"):
        assert en in out, f"{en!r} missing: {out}"
    assert "พุช" in out, f"พุช (short/ambiguous) stays for LLM: {out}"
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_mx12_export_pdf_share_stays_thai")
def _():
    out, hits = apply_dictionary(HYP["mx12"])
    for en in ("export", "PDF", "upload", "Google Drive"):
        assert en in out, f"{en!r} missing: {out}"
    assert "แชร์" in out, f"แชร์ is naturalized (ref writes Thai): {out}"
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_mx16_bug_but_sapfik_stays")
def _():
    out, hits = apply_dictionary(HYP["mx16"])
    for en in ("bug", "reproduce", "production"):
        assert en in out, f"{en!r} missing: {out}"
    assert "ทรัพย์ฟิก" in out, f"ทรัพย์ฟิก (contains ทรัพย์) must stay: {out}"
    assert hits == 3, hits
    _no_double_space(out)


@register("pos_mx17_bangkok_singapore_stays")
def _():
    out, hits = apply_dictionary(HYP["mx17"])
    assert "Bangkok" in out and "แบงคอก" not in out, out
    assert "สิงคโปร์" in out, f"สิงคโปร์ is keep-Thai: {out}"
    assert hits == 1, hits
    _no_double_space(out)


@register("pos_pn08_gaysorn_stays")
def _():
    out, hits = apply_dictionary(HYP["pn08"])
    assert "marketing" in out and "Facebook" in out, out
    assert "เกสร" in out, f"เกสร is keep-Thai (user decision): {out}"
    assert hits == 2, hits
    _no_double_space(out)


@register("pos_mx13_glued_performance")
def _():
    # เพอร์ฟอร์แมนต์บน is glued by the ASR; the guard still allows this split
    # because the leftover chunk is not a real dict word.
    out, hits = apply_dictionary(HYP["mx13"])
    for en in ("feature", "user", "feedback", "performance"):
        assert en in out, f"{en!r} missing: {out}"
    assert "performance บนมือถือ" in out, out
    assert "อิมพูล" in out, f"garbled อิมพูล stays for LLM: {out}"
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_tc02_spaced_syllables_stay")
def _():
    out, hits = apply_dictionary(HYP["tc02"])
    for en in ("latency", "threshold", "query", "database"):
        assert en in out, f"{en!r} missing: {out}"
    assert "ออป ติ ไมซ์" in out, f"spaced syllables must NOT be matched: {out}"
    assert hits == 4, hits
    _no_double_space(out)


@register("pos_mx19_lead_stays_ticket_fixed")
def _():
    out, hits = apply_dictionary(HYP["mx19"])
    assert "ticket" in out and "customer" in out, out
    assert "ลีด" in out, f"ลีด (short/ambiguous) stays for LLM: {out}"
    assert hits == 2, hits
    _no_double_space(out)


@register("pos_pathumma_mlx_spelling_variants")
def _():
    # pathumma-mlx / fp16-gen decode-path spellings observed in the
    # 2026-07-07 latency spike (same model, different runtime => new
    # transliteration variants of already-mapped terms).
    out, _h = apply_dictionary("เมมอรี่ยูเซตพุ่งสูง สงสัยมีเมมอรีลีกในเซอร์วิส")
    assert "memory " in out and "memory leak" in out, out
    assert "เมมอรี" not in out, out
    _no_double_space(out)
    # แอร์เวย์ส must be replaced whole: the shorter pre-existing แอร์เวย์
    # entry firing inside it would leave a dangling "Airways ส".
    out2, _h = apply_dictionary("เที่ยวบินไทย แอร์เวย์ส ดีเลย์สองชั่วโมง")
    assert "Airways" in out2 and "แอร์เวย์ส" not in out2, out2
    assert "Airways ส" not in out2, f"dangling ส from short-key over-fire: {out2}"
    _no_double_space(out2)


# ---------------------------------------------------------------------------
# Negative: no over-fire inside longer Thai words / keep-Thai words
# ---------------------------------------------------------------------------

@register("pos_marketing_groq_variant")
def _():
    # CLN-T3: groq spells "marketing" as มาร์เกตติ้ง (no ็). The variant is NOT a
    # real thai_word, so it must map; the real-word spelling มาร์เก็ตติ้ง maps too.
    out, hits = apply_dictionary("ทีมมาร์เกตติ้งนัดประชุมกับ Facebook ที่ตึกเกศร")
    assert "marketing" in out and "มาร์เกตติ้ง" not in out, out
    assert "เกศร" in out, f"เกศร (Gaysorn variant) stays Thai: {out}"
    assert hits == 1, hits
    _no_double_space(out)
    out2, hits2 = apply_dictionary("วางแผนมาร์เก็ตติ้งใหม่")  # real-word spelling still maps
    assert "marketing" in out2 and hits2 == 1, (out2, hits2)


@register("neg_jaidee_ploy_never_deploy")
def _():
    t = "ใจดีพลอยเลยยิ้ม"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_apple_never_app")
def _():
    t = "ซื้อแอปเปิ้ลที่ตลาดสองลูก"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_application_never_app")
def _():
    t = "เปิดแอปพลิเคชั่นนี้ให้หน่อย"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_democrat_never_demo")
def _():
    t = "พรรคเดโมแครตชนะเลือกตั้ง"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_bacteria_never_bug")
def _():
    t = "เชื้อบัคเตรีในน้ำดื่ม"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_starbucks_final_s_guarded")
def _():
    t = "ร้านสตาร์บัคส์สาขาใหม่"  # สตาร์บัคส์ is the dict word; สตาร์บัค must not split it
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_preview_never_review")
def _():
    t = "ดูพรีวิวหนังก่อนตัดสินใจ"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_designer_never_design")
def _():
    t = "ดีไซน์เนอร์คนนี้เก่งมาก"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_modelling_never_model")
def _():
    t = "เธอทำงานโมเดลลิ่งถ่ายแบบ"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_email_variant_spelling_guarded")
def _():
    t = "ส่งอีเมล์ไปหาเขาแล้ว"  # อีเมล์ (with ์) is the dict word; อีเมล must not split it
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_memory_card_thai_spelling_guarded")
def _():
    t = "เมมโมรี่ของกล้องเต็มแล้ว"  # เมมโมรี่ dict word; เมมโมรี must not split it
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_microscope_never_scope")
def _():
    t = "ส่องสเปกโทรสโคปดูดาว"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_index_living_mall_guarded")
def _():
    t = "อินเด็กซ์ลิฟวิ่งมอลล์ขายเฟอร์นิเจอร์"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_thaiticketmajor_guarded")
def _():
    t = "ซื้อบัตรที่ไทยทิกเก็ตเมเจอร์"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_lok_never_log")
def _():
    t = "เขาหลอกฉันเรื่องเงิน"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_bank_of_thailand")
def _():
    t = "แบงก์ชาติปรับดอกเบี้ย"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_gaysorn_alone")
def _():
    t = "นัดเจอกันที่ตึกเกสร"
    out, hits = apply_dictionary(t)
    assert out == t and hits == 0, f"{out!r} hits={hits}"


@register("neg_pure_thai_byte_identical")
def _():
    for t in (
        "เรื่องนี้ต้องรีบตัดสินใจก่อนสิ้นสัปดาห์ไม่งั้นจะไม่ทัน",
        HYP["th01"], HYP["th05"], HYP["th09"], HYP["th12"],
    ):
        out, hits = apply_dictionary(t)
        assert out == t, f"changed: {t!r} -> {out!r}"
        assert hits == 0, f"hits={hits} for {t!r}"


@register("neg_pure_english_unchanged")
def _():
    for t in (
        "Please review my changes and let me know if anything looks wrong.",
        "We need to cut down the loading time on the dashboard page.",
        HYP["en02"], HYP["en06"], HYP["en09"],
    ):
        out, hits = apply_dictionary(t)
        assert out == t, f"changed: {t!r} -> {out!r}"
        assert hits == 0, f"hits={hits} for {t!r}"


@register("neg_all_thai_only_records_zero_hits")
def _():
    for i in range(1, 13):
        t = HYP[f"th{i:02d}"]
        out, hits = apply_dictionary(t)
        assert out == t and hits == 0, f"th{i:02d}: {out!r} hits={hits}"


# ---------------------------------------------------------------------------
# Hits counting + spacing mechanics
# ---------------------------------------------------------------------------

@register("hits_two_translits")
def _():
    out, hits = apply_dictionary("รีสตาร์ทเซิร์ฟเวอร์ด่วนเลย")
    assert hits == 2, f"hits={hits}: {out}"
    assert "restart" in out and "server" in out, out


@register("hits_preexisting_english_not_counted")
def _():
    out, hits = apply_dictionary("restart แล้วค่อยรีสตาร์ทอีกที")
    assert hits == 1, f"hits={hits}: {out}"
    assert out.count("restart") == 2, out


@register("hits_same_key_twice")
def _():
    out, hits = apply_dictionary("คอนฟิกเก่ากับคอนฟิกใหม่")
    assert hits == 2, f"hits={hits}: {out}"
    assert out.count("config") == 2, out


@register("spacing_adjacent_translits")
def _():
    out, hits = apply_dictionary("เปิดกราฟาแดชบอร์ดดู")
    assert hits == 2, f"hits={hits}: {out}"
    assert "Grafana dashboard" in out, out
    _no_double_space(out)


@register("spacing_key_at_string_edges")
def _():
    out, hits = apply_dictionary("มีตติ้งเลื่อนไปเป็นพรุ่งนี้แทนนะโอเคมั้ยบัดเจ็ต")
    assert out.startswith("meeting ") and out.endswith(" budget"), out
    assert hits == 2, hits
    _no_double_space(out)


@register("spacing_existing_spaces_respected")
def _():
    out, hits = apply_dictionary("ประชุม มีตติ้ง บ่ายนี้")
    assert out == "ประชุม meeting บ่ายนี้", repr(out)
    assert hits == 1, hits


@register("empty_and_trivial_inputs")
def _():
    assert apply_dictionary("") == ("", 0)
    assert apply_dictionary("   ") == ("   ", 0)
    assert apply_dictionary("ok") == ("ok", 0)


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
