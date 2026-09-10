#!/usr/bin/env python3
"""Build docs/oliv-vs-wispr.html — interactive head-to-head report.

Reads the full 264-clip OLIV + Wispr eval JSONs and _semantic.json, embeds
everything into a self-contained page (filters, examples, insights).

    benchmark/.venv/bin/python benchmark/build_h2h.py
"""
from __future__ import annotations

import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RES = ROOT / "eval_results"
OUT = ROOT.parent / "docs" / "oliv-vs-wispr.html"

OLIV_KEY = "oliv_full_jargonrescue_20260810_160131"
WISPR_KEY = "wispr_full_20260810_072859"

BUCKETS = {
    "th": ("Everyday Thai", "ไทยทั่วไป"),
    "en": ("English only", "อังกฤษล้วน"),
    "mx": ("Thai + English", "ไทยปนอังกฤษ"),
    "tc": ("Tech talk", "ศัพท์เทค"),
    "pn": ("Names & brands", "ชื่อ/แบรนด์"),
    "nm": ("Numbers & dates", "ตัวเลข/วันที่"),
    "nu": ("Tricky Thai names", "ชื่อไทยยาก"),
    "hx": ("Heavy tech mixing", "ปนเทคหนัก"),
    "vb": ("Rare jargon", "ศัพท์หายาก"),
    "fl": ("Filler removal", "ตัดคำเติม"),
    "fm": ("Voice commands", "คำสั่งเสียง"),
    "lf": ("Long messages", "ข้อความยาว"),
    "xg": ("Extra / edge", "เคสพิเศษ"),
}

THRESH = 0.80

# Curated example ids for the story sections (must exist in the run).
EX_WISPR = ["vb09", "hx96", "hx202", "hx206", "hx13"]
EX_OLIV = ["nm03", "nm14", "fm07", "fm93", "lf05"]


def load() -> dict:
    oliv = json.loads((RES / f"{OLIV_KEY}.json").read_text(encoding="utf-8"))
    wispr = json.loads((RES / f"{WISPR_KEY}.json").read_text(encoding="utf-8"))
    sem = json.loads((RES / "_semantic.json").read_text(encoding="utf-8"))
    so = sem["configs"][OLIV_KEY]
    sw = sem["configs"][WISPR_KEY]
    oc = {c["id"]: c for c in oliv["clips"]}
    wc = {c["id"]: c for c in wispr["clips"]}
    osim = {c["id"]: c["sim"] for c in so["clips"]}
    wsim = {c["id"]: c["sim"] for c in sw["clips"]}

    clips = []
    for cid in sorted(set(oc) & set(wc)):
        o, w = oc[cid], wc[cid]
        o_s, w_s = osim[cid], wsim[cid]
        if o_s >= THRESH and w_s >= THRESH:
            winner = "tie"
        elif w_s > o_s:
            winner = "wispr"
        elif o_s > w_s:
            winner = "oliv"
        else:
            winner = "tie"
        clips.append({
            "id": cid,
            "bucket": o.get("bucket") or cid[:2],
            "ref": o["reference"],
            "oliv": o["final"],
            "wispr": w["final"],
            "o_sim": round(o_s, 4),
            "w_sim": round(w_s, 4),
            "delta": round(w_s - o_s, 4),
            "o_wer": o.get("wer"),
            "w_wer": w.get("wer"),
            "o_lat": o.get("latency_s"),
            "w_lat": w.get("latency_s"),
            "o_ok": o_s >= THRESH,
            "w_ok": w_s >= THRESH,
            "winner": winner,
        })

    by_bucket = {}
    for b in sorted({c["bucket"] for c in clips}):
        xs = [c for c in clips if c["bucket"] == b]
        by_bucket[b] = {
            "n": len(xs),
            "oliv_match": round(100 * sum(c["o_ok"] for c in xs) / len(xs), 1),
            "wispr_match": round(100 * sum(c["w_ok"] for c in xs) / len(xs), 1),
            "oliv_wer": round(sum(c["o_wer"] or 0 for c in xs) / len(xs), 3),
            "wispr_wer": round(sum(c["w_wer"] or 0 for c in xs) / len(xs), 3),
            "oliv_lat": round(sum(c["o_lat"] or 0 for c in xs) / len(xs), 2),
            "wispr_lat": round(sum(c["w_lat"] or 0 for c in xs) / len(xs), 2),
            "label_en": BUCKETS.get(b, (b, b))[0],
            "label_th": BUCKETS.get(b, (b, b))[1],
        }

    both_ok = sum(1 for c in clips if c["o_ok"] and c["w_ok"])
    only_o = sum(1 for c in clips if c["o_ok"] and not c["w_ok"])
    only_w = sum(1 for c in clips if not c["o_ok"] and c["w_ok"])
    both_bad = sum(1 for c in clips if not c["o_ok"] and not c["w_ok"])

    def pick(ids):
        out = []
        by_id = {c["id"]: c for c in clips}
        for i in ids:
            if i in by_id:
                out.append(by_id[i])
        return out

    return {
        "meta": {
            "n": len(clips),
            "threshold": THRESH,
            "metric": "LaBSE meaning match (v2 newmm), threshold 0.80",
            "oliv_run": OLIV_KEY,
            "wispr_run": WISPR_KEY,
            "protocol": (
                "Same 264 WAVs. OLIV via file→pipeline. "
                "Wispr via BlackHole digital loopback + History capture."
            ),
            "date": "2026-08-10",
        },
        "overall": {
            "oliv": {
                "match": so["match_rate"],
                "sim": so["overall_sim"],
                "wer": oliv["overall"]["mean_wer"],
                "lat": oliv["overall"]["mean_latency_s"],
                "exact": oliv["overall"]["exact_pct"],
            },
            "wispr": {
                "match": sw["match_rate"],
                "sim": sw["overall_sim"],
                "wer": wispr["overall"]["mean_wer"],
                "lat": wispr["overall"]["mean_latency_s"],
                "exact": wispr["overall"]["exact_pct"],
            },
        },
        "matrix": {
            "both_ok": both_ok,
            "only_oliv": only_o,
            "only_wispr": only_w,
            "both_miss": both_bad,
        },
        "buckets": by_bucket,
        "examples_wispr": pick(EX_WISPR),
        "examples_oliv": pick(EX_OLIV),
        "clips": clips,
    }


def render(data: dict) -> str:
    payload = json.dumps(data, ensure_ascii=False)
    # Escape </script> in case any transcript contains it
    payload = payload.replace("<", "\\u003c")

    return f"""<!doctype html>
<html lang="en" data-lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OLIV vs Wispr Flow — head-to-head on 264 clips</title>
<meta name="description" content="Interactive head-to-head: OLIV local pipeline vs Wispr Flow on the same 264 Thai–English dictation clips.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Thai:wght@300;400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="icon" type="image/png" href="img/favicon.png">
<style>
:root{{
  --ink:#241f11;--ink2:#4d4530;--muted:#6a5f45;--line:#d1c39a;--paper:#eadfc4;--surf:#f6efdc;
  --olive:#57761f;--on-olive:#fff;--olive-d:#40501f;--olive-l:#e4e8c6;--sand:#dbcda6;
  --wispr:#2a5f8f;--wispr-l:#d7e6f3;--bad:#a8451f;--badbg:#f2e4cc;--tie:#6a5f45;
  --disp:"IBM Plex Sans Thai",system-ui,sans-serif;--mono:"IBM Plex Mono","IBM Plex Sans Thai",ui-monospace,monospace;
}}
@media (prefers-color-scheme:dark){{:root{{
  --ink:#ece5d4;--ink2:#c6bda6;--muted:#9a8f74;--line:#3b3423;--paper:#181410;--surf:#211c13;
  --olive:#9db24e;--on-olive:#181410;--olive-d:#c9d78d;--olive-l:#262c15;--sand:#2b2517;
  --wispr:#7eb0e0;--wispr-l:#1a2a3a;--bad:#e08a5e;--badbg:#271b12;--tie:#9a8f74;
}}}}
*{{box-sizing:border-box}}
html[data-lang="en"] .th{{display:none}} html[data-lang="th"] .en{{display:none}}
body{{margin:0;background:var(--paper);color:var(--ink);font-family:var(--disp);line-height:1.55;-webkit-font-smoothing:antialiased}}
.wrap{{max-width:1100px;margin:0 auto;padding:0 22px}}
a{{color:var(--olive-d)}}
h1,h2,h3{{line-height:1.2;letter-spacing:-.01em;font-weight:600;margin:0}}
header.top{{position:sticky;top:0;z-index:20;background:color-mix(in srgb,var(--paper) 88%,transparent);backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}}
.top .wrap{{display:flex;align-items:center;gap:12px;height:56px}}
.brand{{font-weight:700;font-size:1.05rem}} .brand span{{color:var(--muted);font-weight:400}}
.top nav{{margin-left:auto;display:flex;gap:6px;align-items:center;flex-wrap:wrap}}
.toggle{{font-family:var(--mono);font-size:.75rem;border:1px solid var(--line);background:var(--surf);color:var(--ink2);padding:6px 10px;border-radius:8px;cursor:pointer}}
.hero{{padding:42px 0 8px}}
.hero .eyebrow{{font-family:var(--mono);font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}}
.hero h1{{font-size:clamp(1.7rem,4vw,2.6rem);margin:.35rem 0 .5rem}}
.hero .sub{{color:var(--ink2);max-width:62ch;font-size:1.05rem}}
.stats{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:28px 0 8px}}
@media (max-width:800px){{.stats{{grid-template-columns:1fr 1fr}}}}
.stat{{background:var(--surf);border:1px solid var(--line);border-radius:16px;padding:18px 20px}}
.stat .k{{font-family:var(--mono);font-size:.7rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}}
.stat .v{{font-family:var(--mono);font-size:1.85rem;font-weight:600;margin-top:4px}}
.stat .s{{font-size:.85rem;color:var(--ink2);margin-top:4px}}
.stat.olive .v{{color:var(--olive-d)}}
.stat.wispr .v{{color:var(--wispr)}}
.section{{margin:42px 0}}
.section h2{{font-size:1.35rem;margin-bottom:8px}}
.section .lead{{color:var(--ink2);margin:0 0 16px;max-width:70ch}}
.insights{{display:grid;gap:12px}}
.insight{{border:1px solid var(--line);border-radius:14px;padding:16px 18px;background:var(--surf)}}
.insight h3{{font-size:1.02rem;margin-bottom:6px}}
.insight p{{margin:0;color:var(--ink2);font-size:.98rem}}
.insight .tag{{display:inline-block;font-family:var(--mono);font-size:.68rem;padding:2px 8px;border-radius:999px;margin-bottom:8px}}
.tag.w{{background:var(--wispr-l);color:var(--wispr)}}
.tag.o{{background:var(--olive-l);color:var(--olive-d)}}
.tag.n{{background:var(--sand);color:var(--ink2)}}
.matrix{{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:14px}}
@media (max-width:700px){{.matrix{{grid-template-columns:1fr 1fr}}}}
.mcell{{border:1px solid var(--line);border-radius:12px;padding:14px;background:var(--surf);text-align:center}}
.mcell .n{{font-family:var(--mono);font-size:1.6rem;font-weight:600}}
.mcell .l{{font-size:.82rem;color:var(--muted);margin-top:2px}}
.bars{{display:grid;gap:10px;margin-top:8px}}
.bar-row{{display:grid;grid-template-columns:140px 1fr 52px;gap:10px;align-items:center}}
@media (max-width:600px){{.bar-row{{grid-template-columns:90px 1fr 44px}}}}
.bar-row .name{{font-size:.88rem}}
.bar-row .name small{{display:block;color:var(--muted);font-size:.72rem}}
.track{{height:18px;background:var(--sand);border-radius:9px;overflow:hidden;display:flex;position:relative}}
.track .o{{background:var(--olive);height:100%}}
.track .w{{background:var(--wispr);height:100%;position:absolute;top:0;left:0;opacity:.45}}
@media (prefers-color-scheme:dark){{.track .w{{opacity:.65}}}}
.bar-row .delta{{font-family:var(--mono);font-size:.75rem;text-align:right}}
.delta.pos{{color:var(--wispr)}} .delta.neg{{color:var(--olive-d)}}
.examples{{display:grid;gap:14px}}
.ex{{border:1px solid var(--line);border-radius:14px;background:var(--surf);overflow:hidden}}
.ex head,.ex .hd{{display:flex;justify-content:space-between;gap:10px;padding:12px 16px;border-bottom:1px solid var(--line);align-items:center;flex-wrap:wrap}}
.ex .id{{font-family:var(--mono);font-size:.78rem;color:var(--muted)}}
.ex .body{{padding:14px 16px;display:grid;gap:10px}}
.line{{display:grid;grid-template-columns:64px 1fr;gap:10px}}
.line .lbl{{font-family:var(--mono);font-size:.68rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);padding-top:3px}}
.line .txt{{font-family:var(--mono);font-size:.92rem;white-space:pre-wrap;word-break:break-word}}
.line.oliv .txt{{border-left:3px solid var(--olive);padding-left:10px}}
.line.wispr .txt{{border-left:3px solid var(--wispr);padding-left:10px}}
.line.ref .txt{{color:var(--ink2)}}
.scores{{display:flex;gap:8px;flex-wrap:wrap}}
.pill{{font-family:var(--mono);font-size:.72rem;padding:3px 8px;border-radius:999px;border:1px solid var(--line);background:var(--paper)}}
.pill.ok{{background:var(--olive-l);border-color:transparent;color:var(--olive-d)}}
.pill.miss{{background:var(--badbg);border-color:transparent;color:var(--bad)}}
.controls{{display:flex;flex-wrap:wrap;gap:8px;margin:14px 0;align-items:center}}
.controls input,.controls select{{font-family:var(--mono);font-size:.82rem;border:1px solid var(--line);background:var(--surf);color:var(--ink);padding:8px 10px;border-radius:8px}}
.controls input{{min-width:200px;flex:1}}
.chip{{font-family:var(--mono);font-size:.72rem;padding:6px 10px;border-radius:999px;border:1px solid var(--line);background:var(--surf);cursor:pointer;color:var(--ink2)}}
.chip.on{{background:var(--olive);color:var(--on-olive);border-color:var(--olive)}}
.chip.w.on{{background:var(--wispr);border-color:var(--wispr)}}
.table-wrap{{border:1px solid var(--line);border-radius:14px;overflow:auto;background:var(--surf);max-height:640px}}
table{{width:100%;border-collapse:collapse;font-size:.86rem}}
th,td{{padding:9px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}}
th{{position:sticky;top:0;background:var(--sand);font-family:var(--mono);font-size:.7rem;letter-spacing:.04em;text-transform:uppercase;cursor:pointer;user-select:none}}
tr:hover td{{background:color-mix(in srgb,var(--olive-l) 35%,transparent)}}
tr.sel td{{background:var(--olive-l)}}
td.mono{{font-family:var(--mono);font-size:.8rem}}
.clip-preview{{margin-top:14px}}
.fine{{font-family:var(--mono);font-size:.72rem;color:var(--muted);margin-top:18px}}
footer{{border-top:1px solid var(--line);padding:28px 0 48px;margin-top:40px;color:var(--muted);font-size:.9rem}}
</style>
</head>
<body>
<header class="top"><div class="wrap">
  <div class="brand">OLIV <span>vs Wispr Flow</span></div>
  <nav>
    <button class="toggle" id="langBtn" type="button">TH / EN</button>
    <a class="toggle" href="index.html"><span class="en">OLIV landing</span><span class="th">หน้า OLIV</span></a>
  </nav>
</div></header>

<main class="wrap">
  <section class="hero">
    <div class="eyebrow">Full corpus · 264 clips · 2026-08-10</div>
    <h1>
      <span class="en">Head-to-head on the same voice</span>
      <span class="th">เทียบหัวต่อหัวบนเสียงชุดเดียวกัน</span>
    </h1>
    <p class="sub">
      <span class="en">Identical WAVs. OLIV runs the shipped local pipeline (file in). Wispr hears the same PCM through a digital BlackHole loopback. Metric: LaBSE meaning match ≥ 0.80 — not word-for-word accuracy.</span>
      <span class="th">ไฟล์เสียงชุดเดียวกันทั้งหมด OLIV รัน pipeline ในเครื่อง (อ่านไฟล์ตรง) Wispr ได้ยิน PCM เดียวกันผ่าน BlackHole แบบ digital วัดด้วย LaBSE ความหมายตรง ≥ 0.80 — ไม่ใช่ความถูกต้องทีละคำ</span>
    </p>
  </section>

  <section class="stats" id="stats"></section>

  <section class="section">
    <h2><span class="en">Insights</span><span class="th">สิ่งที่เห็นจากผล</span></h2>
    <p class="lead">
      <span class="en">OLIV leads overall meaning match on this corpus — and stays ~4× faster — while Wispr still over-formats numbers / spoken layout commands where OLIV stays literal. Heavy jargon is nearly tied.</span>
      <span class="th">OLIV นำเรื่องความหมายโดยรวมบนชุดนี้ — และเร็วกว่า ~4 เท่า — ส่วน Wispr ยัง “เก่งเกิน” กับตัวเลข/คำสั่งจัดหน้า ที่ OLIV คงรูปตามที่พูด ศัพท์เทคหนักใกล้กันมาก</span>
    </p>
    <div class="insights">
      <div class="insight">
        <span class="tag n">Near tie</span>
        <h3><span class="en">Rare / stacked English jargon</span><span class="th">ศัพท์อังกฤษหายากซ้อนกัน</span></h3>
        <p class="en">On <b>hx</b> (heavy mix) Wispr hits 100% meaning match vs OLIV 98%. A thin edge on cases like OpenTelemetry, CockroachDB, Pinecone+LangChain — not the gap it used to be.</p>
        <p class="th">ในชุด <b>hx</b> Wispr ได้ความหมายตรง 100% เทียบ OLIV 98% นำบางเคสเช่น OpenTelemetry, CockroachDB, Pinecone+LangChain — ช่องว่างแคบลงมาก</p>
      </div>
      <div class="insight">
        <span class="tag o">OLIV win</span>
        <h3><span class="en">Spoken Thai numbers & format commands</span><span class="th">ตัวเลขไทยที่พูด + คำสั่งจัดหน้า</span></h3>
        <p class="en">On <b>nm</b> OLIV 100% vs Wispr 65% — Wispr collapses “ศูนย์แปดหนึ่ง…” into digits and sometimes truncates. On <b>fm</b> OLIV keeps newlines; Wispr often leaves the command words or emits HTML lists.</p>
        <p class="th">ชุด <b>nm</b> OLIV 100% vs Wispr 65% — Wispr ยุบ “ศูนย์แปดหนึ่ง…” เป็นตัวเลขและบางทีตัดท้าย ชุด <b>fm</b> OLIV คงบรรทัด; Wispr มักเหลือคำสั่ง หรือทำเป็น HTML list</p>
      </div>
      <div class="insight">
        <span class="tag n">Trade-off</span>
        <h3><span class="en">Latency is not close</span><span class="th">ความเร็วห่างกันชัด</span></h3>
        <p class="en">OLIV mean ~2.2s/clip on-device. Wispr mean ~8.2s (cloud round-trip + polish). For push-to-talk UX, that gap is product-defining.</p>
        <p class="th">OLIV เฉลี่ย ~2.2 วินาที/คลิปในเครื่อง Wispr ~8.2 วินาที (cloud + polish) สำหรับ UX กดพูด ช่องว่างนี้คือจุดขายของผลิตภัณฑ์</p>
      </div>
      <div class="insight">
        <span class="tag n">Agreement</span>
        <h3><span class="en">Most clips both pass</span><span class="th">ส่วนใหญ่ทั้งคู่ผ่าน</span></h3>
        <p class="en" id="matrixLeadEn"></p>
        <p class="th" id="matrixLeadTh"></p>
      </div>
    </div>
    <div class="matrix" id="matrix"></div>
  </section>

  <section class="section">
    <h2><span class="en">By bucket</span><span class="th">แยกตามชุด</span></h2>
    <p class="lead">
      <span class="en">Bars: olive = OLIV match%, blue overlay = Wispr match%. Click a row to filter the explorer.</span>
      <span class="th">แถบ: เขียวมะกอก = OLIV ผ่าน%, ฟ้าทับ = Wispr ผ่าน% คลิกแถวเพื่อกรองตารางด้านล่าง</span>
    </p>
    <div class="bars" id="bars"></div>
  </section>

  <section class="section">
    <h2><span class="en">Where Wispr pulls ahead</span><span class="th">ตัวอย่างที่ Wispr นำ</span></h2>
    <p class="lead"><span class="en">Same audio — OLIV left transliterations; Wispr restored the English terms.</span><span class="th">เสียงเดียวกัน — OLIV ค้างทับศัพท์ Wispr คืนคำอังกฤษ</span></p>
    <div class="examples" id="exWispr"></div>
  </section>

  <section class="section">
    <h2><span class="en">Where OLIV stays truer</span><span class="th">ตัวอย่างที่ OLIV ตรงกว่า</span></h2>
    <p class="lead"><span class="en">Wispr “helps” by rewriting — which moves meaning or layout away from the spoken reference.</span><span class="th">Wispr “ช่วย” ด้วยการเขียนใหม่ — ทำให้ความหมายหรือเลย์เอาต์เลื่อนจากสิ่งที่พูด</span></p>
    <div class="examples" id="exOliv"></div>
  </section>

  <section class="section">
    <h2><span class="en">Clip explorer</span><span class="th">สำรวจทีละคลิป</span></h2>
    <p class="lead"><span class="en">Filter, sort, click a row for the full side-by-side.</span><span class="th">กรอง เรียง คลิกแถวเพื่อดูเทียบเต็ม</span></p>
    <div class="controls">
      <input id="q" type="search" placeholder="search id / text…">
      <select id="bucket"></select>
      <button type="button" class="chip on" data-win="all">all</button>
      <button type="button" class="chip" data-win="wispr">Wispr ↑</button>
      <button type="button" class="chip" data-win="oliv">OLIV ↑</button>
      <button type="button" class="chip" data-win="disagree">disagree</button>
      <button type="button" class="chip" data-win="both_miss">both miss</button>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th data-sort="id">id</th>
            <th data-sort="bucket">bucket</th>
            <th data-sort="o_sim">OLIV sim</th>
            <th data-sort="w_sim">Wispr sim</th>
            <th data-sort="delta">Δ</th>
            <th data-sort="o_lat">OLIV s</th>
            <th data-sort="w_lat">Wispr s</th>
            <th>reference</th>
          </tr>
        </thead>
        <tbody id="tbody"></tbody>
      </table>
    </div>
    <div class="clip-preview" id="preview"></div>
  </section>

  <p class="fine" id="metaFine"></p>
</main>

<footer><div class="wrap">
  <span class="en">Single-speaker corpus (developer voice). Wispr settings: AI formatting on, Auto-detect→BlackHole, en+th. Not a claim about other accents or noisy rooms.</span>
  <span class="th">คอร์ปัสเสียงผู้พูดคนเดียว (ผู้พัฒนา) ตั้งค่า Wispr: AI formatting เปิด, Auto-detect→BlackHole, en+th ไม่ได้ทดสอบสำเนียงอื่นหรือห้องเสียงรบกวน</span>
</div></footer>

<script id="DATA" type="application/json">{payload}</script>
<script>
const DATA = JSON.parse(document.getElementById('DATA').textContent);
const TH = DATA.meta.threshold;
let winFilter = 'all';
let sortKey = 'delta';
let sortDir = -1;
let selected = null;

const langBtn = document.getElementById('langBtn');
langBtn.onclick = () => {{
  const cur = document.documentElement.getAttribute('data-lang') === 'th' ? 'en' : 'th';
  document.documentElement.setAttribute('data-lang', cur);
}};

function pct(n) {{ return (Math.round(n * 10) / 10).toFixed(1); }}
function esc(s) {{
  return String(s ?? '').replace(/[&<>"']/g, c => ({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
}}

function renderStats() {{
  const o = DATA.overall.oliv, w = DATA.overall.wispr;
  document.getElementById('stats').innerHTML = `
    <div class="stat olive"><div class="k">OLIV meaning match</div><div class="v">${{pct(o.match)}}%</div><div class="s">sim ${{o.sim.toFixed(3)}} · WER ${{o.wer}}</div></div>
    <div class="stat wispr"><div class="k">Wispr meaning match</div><div class="v">${{pct(w.match)}}%</div><div class="s">sim ${{w.sim.toFixed(3)}} · WER ${{w.wer}}</div></div>
    <div class="stat olive"><div class="k">OLIV latency</div><div class="v">${{o.lat.toFixed(1)}}s</div><div class="s"><span class="en">on-device pipeline</span><span class="th">pipeline ในเครื่อง</span></div></div>
    <div class="stat wispr"><div class="k">Wispr latency</div><div class="v">${{w.lat.toFixed(1)}}s</div><div class="s"><span class="en">cloud + polish</span><span class="th">cloud + polish</span></div></div>`;
}}

function renderMatrix() {{
  const m = DATA.matrix;
  document.getElementById('matrixLeadEn').innerHTML =
    `<b>${{m.both_ok}}</b> both pass · <b>${{m.only_wispr}}</b> Wispr-only · <b>${{m.only_oliv}}</b> OLIV-only · <b>${{m.both_miss}}</b> both miss (n=${{DATA.meta.n}}).`;
  document.getElementById('matrixLeadTh').innerHTML =
    `ผ่านทั้งคู่ <b>${{m.both_ok}}</b> · เฉพาะ Wispr <b>${{m.only_wispr}}</b> · เฉพาะ OLIV <b>${{m.only_oliv}}</b> · พลาดทั้งคู่ <b>${{m.both_miss}}</b> (n=${{DATA.meta.n}})`;
  document.getElementById('matrix').innerHTML = `
    <div class="mcell"><div class="n">${{m.both_ok}}</div><div class="l">both pass</div></div>
    <div class="mcell"><div class="n" style="color:var(--wispr)">${{m.only_wispr}}</div><div class="l">Wispr only</div></div>
    <div class="mcell"><div class="n" style="color:var(--olive-d)">${{m.only_oliv}}</div><div class="l">OLIV only</div></div>
    <div class="mcell"><div class="n" style="color:var(--bad)">${{m.both_miss}}</div><div class="l">both miss</div></div>`;
}}

function renderBars() {{
  const entries = Object.entries(DATA.buckets).sort((a,b) => (b[1].wispr_match - b[1].oliv_match) - (a[1].wispr_match - a[1].oliv_match) || a[0].localeCompare(b[0]));
  document.getElementById('bars').innerHTML = entries.map(([b, v]) => {{
    const d = v.wispr_match - v.oliv_match;
    const cls = d > 0.5 ? 'pos' : d < -0.5 ? 'neg' : '';
    return `<div class="bar-row" data-b="${{b}}" style="cursor:pointer" title="filter ${{b}}">
      <div class="name">${{esc(v.label_en)}}<small>${{b}} · n=${{v.n}}</small></div>
      <div class="track"><div class="o" style="width:${{v.oliv_match}}%"></div><div class="w" style="width:${{v.wispr_match}}%"></div></div>
      <div class="delta ${{cls}}">${{d>0?'+':''}}${{d.toFixed(0)}}</div>
    </div>`;
  }}).join('');
  document.querySelectorAll('.bar-row').forEach(el => el.onclick = () => {{
    document.getElementById('bucket').value = el.dataset.b;
    renderTable();
    document.getElementById('tbody').scrollIntoView({{behavior:'smooth', block:'start'}});
  }});
}}

function exampleCard(c, favor) {{
  const why = favor === 'wispr'
    ? (document.documentElement.getAttribute('data-lang') === 'th'
        ? 'Wispr คืนศัพท์อังกฤษได้ดีกว่า'
        : 'Wispr restores the English jargon')
    : (document.documentElement.getAttribute('data-lang') === 'th'
        ? 'OLIV คงรูปที่พูดได้ใกล้ reference กว่า'
        : 'OLIV stays closer to the spoken reference');
  return `<article class="ex">
    <div class="hd">
      <div><span class="id">${{esc(c.id)}} · ${{esc(c.bucket)}}</span>
      <div class="scores" style="margin-top:6px">
        <span class="pill ${{c.o_ok?'ok':'miss'}}">OLIV ${{c.o_sim.toFixed(2)}}</span>
        <span class="pill ${{c.w_ok?'ok':'miss'}}">Wispr ${{c.w_sim.toFixed(2)}}</span>
        <span class="pill">Δ ${{c.delta>0?'+':''}}${{c.delta.toFixed(2)}}</span>
      </div></div>
    </div>
    <div class="body">
      <div class="line ref"><div class="lbl">ref</div><div class="txt">${{esc(c.ref)}}</div></div>
      <div class="line oliv"><div class="lbl">OLIV</div><div class="txt">${{esc(c.oliv)}}</div></div>
      <div class="line wispr"><div class="lbl">Wispr</div><div class="txt">${{esc(c.wispr)}}</div></div>
    </div>
  </article>`;
}}

function renderExamples() {{
  document.getElementById('exWispr').innerHTML = DATA.examples_wispr.map(c => exampleCard(c,'wispr')).join('');
  document.getElementById('exOliv').innerHTML = DATA.examples_oliv.map(c => exampleCard(c,'oliv')).join('');
}}

function fillBucketSelect() {{
  const sel = document.getElementById('bucket');
  sel.innerHTML = `<option value="">all buckets</option>` +
    Object.entries(DATA.buckets).map(([b,v]) => `<option value="${{b}}">${{b}} — ${{esc(v.label_en)}}</option>`).join('');
}}

function filtered() {{
  const q = document.getElementById('q').value.trim().toLowerCase();
  const b = document.getElementById('bucket').value;
  return DATA.clips.filter(c => {{
    if (b && c.bucket !== b) return false;
    if (winFilter === 'wispr' && !(c.delta > 0.05 && c.w_sim >= c.o_sim)) return false;
    if (winFilter === 'oliv' && !(c.delta < -0.05 && c.o_sim >= c.w_sim)) return false;
    if (winFilter === 'disagree' && !((c.o_ok && !c.w_ok) || (!c.o_ok && c.w_ok))) return false;
    if (winFilter === 'both_miss' && !(!c.o_ok && !c.w_ok)) return false;
    if (q) {{
      const blob = (c.id + ' ' + c.bucket + ' ' + c.ref + ' ' + c.oliv + ' ' + c.wispr).toLowerCase();
      if (!blob.includes(q)) return false;
    }}
    return true;
  }}).sort((a,b) => {{
    const av = a[sortKey], bv = b[sortKey];
    if (typeof av === 'string') return sortDir * av.localeCompare(bv);
    return sortDir * ((av ?? 0) - (bv ?? 0));
  }});
}}

function renderTable() {{
  const rows = filtered();
  document.getElementById('tbody').innerHTML = rows.map(c => `
    <tr data-id="${{esc(c.id)}}" class="${{selected===c.id?'sel':''}}">
      <td class="mono">${{esc(c.id)}}</td>
      <td class="mono">${{esc(c.bucket)}}</td>
      <td class="mono">${{c.o_sim.toFixed(2)}}${{c.o_ok?'':' ·'}}</td>
      <td class="mono">${{c.w_sim.toFixed(2)}}${{c.w_ok?'':' ·'}}</td>
      <td class="mono" style="color:${{c.delta>0.05?'var(--wispr)':c.delta<-0.05?'var(--olive-d)':'inherit'}}">${{c.delta>0?'+':''}}${{c.delta.toFixed(2)}}</td>
      <td class="mono">${{c.o_lat?.toFixed?.(1) ?? '—'}}</td>
      <td class="mono">${{c.w_lat?.toFixed?.(1) ?? '—'}}</td>
      <td>${{esc(c.ref).slice(0,80)}}${{c.ref.length>80?'…':''}}</td>
    </tr>`).join('');
  document.querySelectorAll('#tbody tr').forEach(tr => tr.onclick = () => {{
    selected = tr.dataset.id;
    renderTable();
    showPreview(selected);
  }});
}}

function showPreview(id) {{
  const c = DATA.clips.find(x => x.id === id);
  if (!c) {{ document.getElementById('preview').innerHTML = ''; return; }}
  document.getElementById('preview').innerHTML = exampleCard(c, c.delta >= 0 ? 'wispr' : 'oliv');
}}

document.getElementById('q').oninput = renderTable;
document.getElementById('bucket').onchange = renderTable;
document.querySelectorAll('.chip[data-win]').forEach(btn => btn.onclick = () => {{
  document.querySelectorAll('.chip[data-win]').forEach(b => b.classList.remove('on'));
  btn.classList.add('on');
  winFilter = btn.dataset.win;
  renderTable();
}});
document.querySelectorAll('th[data-sort]').forEach(th => th.onclick = () => {{
  const k = th.dataset.sort;
  if (sortKey === k) sortDir *= -1; else {{ sortKey = k; sortDir = (k === 'id' || k === 'bucket') ? 1 : -1; }}
  renderTable();
}});

document.getElementById('metaFine').textContent =
  `${{DATA.meta.protocol}} · ${{DATA.meta.metric}} · runs: ${{DATA.meta.oliv_run}} / ${{DATA.meta.wispr_run}}`;

renderStats();
renderMatrix();
renderBars();
renderExamples();
fillBucketSelect();
renderTable();
</script>
</body>
</html>
"""


def main() -> int:
    data = load()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(render(data), encoding="utf-8")
    print(f"wrote {OUT}  ({data['meta']['n']} clips)")
    print(
        f"OLIV {data['overall']['oliv']['match']}%  "
        f"Wispr {data['overall']['wispr']['match']}%  "
        f"matrix {data['matrix']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
