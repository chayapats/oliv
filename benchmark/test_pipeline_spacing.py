"""Tests for pipeline.normalize_thai_spacing (CLN spacing fix).

Pure-function tests — no model load. Run with either venv's python.
Proves: Pathumma's Thai word-segmentation spaces are collapsed, spaces around
embedded English/digits are preserved, pure-English is untouched, and the pass
is idempotent.
"""
from pipeline import normalize_thai_spacing as nz

CASES = [
    # (input, expected)  -- expected=None means "assert unchanged"
    # Thai-Thai spaces collapse
    ("งาน ชิ้น นี้ ยาก กว่า ที่ คิด", "งานชิ้นนี้ยากกว่าที่คิด"),
    ("ขอ เลื่อน นัด หมาย", "ขอเลื่อนนัดหมาย"),
    # spaces around English are PRESERVED (both sides)
    ("ค่า latency ต้อง optimize query ที่ database",
     "ค่า latency ต้อง optimize query ที่ database"),
    # mixed: Thai runs collapse, English spacing kept
    ("สั่งกาแฟ latte ร้อน แก้ว หนึ่ง ที่ Starbucks สาขา สยาม",
     "สั่งกาแฟ latte ร้อนแก้วหนึ่งที่ Starbucks สาขาสยาม"),
    # a space touching a Latin letter on ONE side is kept
    ("เปิด Grafana หน้า ดู ค่า", "เปิด Grafana หน้าดูค่า"),
    # Arabic digit is non-Thai -> its flanking spaces are kept
    ("เที่ยว 9 โมง เช้า", "เที่ยว 9 โมงเช้า"),
    # trailing Thai tone/thanthakhat chars are in-range -> collapse
    ("แบรนด์ เม นท ์", "แบรนด์เมนท์"),
    # glued Thai<->English boundaries get a space inserted (house style)
    ("ตั้งalert เข้าnew relic ด้วย", "ตั้ง alert เข้า new relic ด้วย"),
    ("ระบบAuth ใช้keycloakเป็นidentity provider",
     "ระบบ Auth ใช้ keycloak เป็น identity provider"),
    ("deployเสร็จแล้ว", "deploy เสร็จแล้ว"),   # Latin->Thai direction too
    # already-correct Thai/English spacing is preserved (idempotent on good input)
    ("ตั้ง alert บน Grafana", None),
    # pure-Thai with no spaces is untouched (no Latin boundary to split)
    ("ทำงานหนักมาก", None),
    # pure English unchanged
    ("can you summarize the main points", None),
    ("pull request", None),
    # multiple consecutive spaces between Thai collapse fully
    ("งาน   ชิ้น", "งานชิ้น"),
    # empty / trivial
    ("", None),
    ("ก", None),
]


def run() -> int:
    fails = 0
    for inp, want in CASES:
        out = nz(inp)
        exp = inp if want is None else want
        ok = out == exp
        idem = nz(out) == out
        if not ok or not idem:
            fails += 1
            print(f"  [FAIL] {inp!r}\n    got  {out!r}\n    want {exp!r}  idempotent={idem}")
        else:
            print(f"  [PASS] {inp!r} -> {out!r}")
    print(f"\n{'ALL PASS' if not fails else f'{fails} FAILED'} ({len(CASES)} cases)")
    return 1 if fails else 0


if __name__ == "__main__":
    import sys
    sys.exit(run())
