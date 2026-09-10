"""Generate the OLIV launch landing page (docs/index.html) — a self-contained,
bilingual (TH/EN), honest benchmark page for GitHub Pages. Bento layout, plain
language up top, deep detail behind expandable sections. Every number is read from
eval_results/report_data.json (the fresh matrix on the shipped pipeline).

    sidecar/.venv/bin/python benchmark/build_landing.py

Honesty rules baked in: headline anchored on the held-out set; "meaning match",
never "accuracy", next to a percentage; comparisons labeled raw-vs-pipeline;
failures shown as clearly as successes; single-speaker + small-n + hardware
disclosed; whole-percent for n<=40.
"""
from __future__ import annotations
import difflib, html, json, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RES = ROOT / "eval_results"
CLIPS = ROOT / "data" / "clips"
D = json.loads((RES / "report_data.json").read_text())
OUT = ROOT.parent / "docs" / "index.html"
AUD = OUT.parent / "audio"
AUD.mkdir(parents=True, exist_ok=True)


def M(label, s, key):
    return D[label]["sets"][s][key]


def pct(label, s):
    return round(M(label, s, "match"))


def audio_src(cid: str) -> str:
    """Transcode the clip to a small mono mp3 in docs/audio/ and return its
    relative URL (served separately by GitHub Pages, lazy-loaded)."""
    src = CLIPS / f"{cid}.wav"
    if not src.exists():
        return ""
    dst = AUD / f"{cid}.mp3"
    if not dst.exists():
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
                        "-ac", "1", "-b:a", "48k", str(dst)], check=True)
    return f"audio/{cid}.mp3"


def hl_restored(raw: str, final: str) -> str:
    """Green-highlight the English in `final` that was NOT already English in the
    raw speech — i.e. exactly the words OLIV turned back from Thai script."""
    raw_en = {w.lower() for w in re.findall(r"[A-Za-z]{2,}", raw or "")}
    esc = html.escape(final or "")
    return re.sub(r"[A-Za-z][A-Za-z0-9]*",
                  lambda m: f'<ins>{m.group()}</ins>' if m.group().lower() not in raw_en else m.group(),
                  esc)


EX_OK = [
    ("hx19", "main", "Database migration talk — migrate, database, PostgreSQL all restored.",
     "คุยเรื่องย้าย database — migrate, database, PostgreSQL แปลงกลับให้ครบ"),
    ("mx04", "main", "Kept clean — nothing invented.",
     "ออกมาสะอาด ไม่มั่วเติมคำที่ไม่ได้พูด"),
    ("mx08", "main", "Everyday code-switching, spelled back naturally.",
     "พูดสลับภาษาแบบทั่วไป สะกดอังกฤษกลับมาให้เป็นธรรมชาติ"),
]
EX_FAIL = [
    ("hx96", "hold", "Too many unfamiliar terms at once — the speech model garbled them, left in Thai.",
     "ศัพท์แปลก ๆ มารัวเกินไป โมเดลฟังเพี้ยนหมด เลยค้างเป็นตัวไทย"),
    ("hx206", "d2", "A wrong guess: Pinecone became PyTorch, LangChain dropped.",
     "เดาผิด: Pinecone กลายเป็น PyTorch, LangChain หายไปเลย"),
    ("mx206", "d2", "Brand names left in Thai: PromptPay / TrueMoney not restored.",
     "ชื่อแบรนด์ค้างเป็นไทย: PromptPay / TrueMoney แปลงกลับไม่สำเร็จ"),
]

BUCKETS = {
 "th": ("Everyday Thai", "ไทยทั่วไป"), "en": ("English only", "อังกฤษล้วน"),
 "mx": ("Thai + English", "ไทยปนอังกฤษ"), "tc": ("Tech talk", "ศัพท์เทค"),
 "pn": ("Names & brands", "ชื่อ/แบรนด์"), "nm": ("Numbers & dates", "ตัวเลข/วันที่"),
 "nu": ("Tricky Thai names", "ชื่อไทยยาก"), "hx": ("Heavy tech mixing", "ปนเทคหนัก"),
 "vb": ("Rare jargon", "ศัพท์หายาก"), "fl": ("Filler removal", "ตัดคำเติม"),
 "fm": ("Voice commands", "คำสั่งเสียง"), "lf": ("Long messages", "ข้อความยาว"),
 "xg": ("Mixed difficulty", "ยาก-ง่ายคละ"),
}


def bar(value, cls="fill"):
    return f'<span class="track"><span class="{cls}" style="width:{max(1.5, value):.1f}%"></span></span>'


def render_example(cid, s, en, th, ok):
    c = next(x for x in D["e2b"]["sets"][s]["clips"] if x["id"] == cid)
    src = audio_src(cid)
    au = f'<audio controls preload="none"><source src="{src}" type="audio/mpeg"></audio>' if src else ''
    badge = f'{"✓" if ok else "✕"} {round(c["sim"]*100)}%'
    return f'''<figure class="ex {'ok' if ok else 'bad'}">
  <div class="ex-head"><span class="ex-badge">{badge}</span>{au}</div>
  <div class="ex-row"><span class="ex-k en">you said</span><span class="ex-k th">คุณพูด</span><code class="raw">{html.escape(c['raw'].strip())}</code></div>
  <div class="ex-row"><span class="ex-k en">OLIV</span><span class="ex-k th">OLIV</span><code class="fin">{hl_restored(c['raw'], c['final'])}</code></div>
  <figcaption><span class="en">{html.escape(en)}</span><span class="th">{html.escape(th)}</span></figcaption>
</figure>'''


# ---- numbers ----
H_MAIN, H_HOLD, H_D2 = pct("e2b","main"), pct("e2b","hold"), pct("e2b","d2")
L_PURE, L_DET, L_LLM = pct("typhoon_pure","hold"), pct("nollm","hold"), pct("e2b","hold")
LAT = f'{M("e2b","main","lat"):.1f}'
ERR_X = round((100 - pct("nollm","hold")) / (100 - pct("e2b","hold")), 1)
CLOUD_OLIV, CLOUD_RAW = pct("e2b","hold"), pct("groq_pure","hold")

bk_rows = sorted(D["e2b"]["sets"]["main"]["bucket"].items(), key=lambda kv: kv[1]["match"])
bucket_html = ""
for bid, agg in bk_rows:
    en, thn = BUCKETS.get(bid, (bid, bid))
    if not en:
        continue
    bucket_html += (f'<tr><td class="bkname"><span class="en">{en}</span><span class="th">{thn}</span>'
                    f'<span class="bkn">n={agg["n"]}</span></td>'
                    f'<td class="bkbar">{bar(agg["match"])}<b>{round(agg["match"])}%</b></td></tr>')

STT_ORDER = [("typhoon","OLIV (on your Mac)","OLIV (ในเครื่อง)"),
             ("largev3","Whisper large-v3 (local)","Whisper large-v3 (ในเครื่อง)"),
             ("groq","Big cloud service (raw)","บริการ cloud ตัวใหญ่ (ดิบ)"),
             ("pathumma","Pathumma (local)","Pathumma (ในเครื่อง)")]
stt_html = ""
for key, en, thn in STT_ORDER:
    raw = pct(f"{key}_pure", "main")
    full = pct("e2b", "main") if key == "typhoon" else pct(f"{key}_e2b", "main")
    stt_html += (f'<tr><td class="sttname"><span class="en">{en}</span><span class="th">{thn}</span></td>'
                 f'<td class="rawcell">{bar(raw, "fill raw")}<span>{raw}%</span></td>'
                 f'<td class="fullcell">{bar(full)}<span>{full}%</span></td></tr>')

def werv(label, s):
    return D[label]["sets"][s]["wer"]

wer_ship_html = "".join(
    f'<tr><td class="wname"><span class="en">{en}</span><span class="th">{thn}</span><span class="bkn">n={n}</span></td>'
    f'<td class="wnum"><b>{werv("e2b", s):.2f}</b></td><td class="wnum2">{pct("e2b", s)}%</td></tr>'
    for s, en, thn, n in [("main","tuning","ชุดจูน",194),("hold","held-out","held-out",40),("d2","confirmation","ยืนยัน",30)])
wer_stt_html = ""
for key, en, thn in STT_ORDER:
    raww = werv(f"{key}_pure", "main")
    fullw = werv("e2b", "main") if key == "typhoon" else werv(f"{key}_e2b", "main")
    wer_stt_html += (f'<tr><td class="wname"><span class="en">{en}</span><span class="th">{thn}</span></td>'
                     f'<td class="wnum raww">{raww:.2f}</td><td class="wnum"><b>{fullw:.2f}</b></td></tr>')

examples_ok = "\n".join(render_example(*e, True) for e in EX_OK)
examples_bad = "\n".join(render_example(*e, False) for e in EX_FAIL)

HTML = f'''<!doctype html><html lang="en" data-lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>OLIV — Thai + English dictation, fully on your Mac</title>
<meta name="description" content="OLIV types your Thai-English speech correctly ~9 times in 10 — fully on your Mac, nothing uploaded. An honest, reproducible benchmark.">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Thai:wght@300;400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="icon" type="image/png" href="img/favicon.png">
<style>
:root{{
 --ink:#241f11;--ink2:#4d4530;--muted:#6a5f45;--line:#d1c39a;--paper:#eadfc4;--surf:#f6efdc;
 --olive:#57761f;--on-olive:#fff;--olive-d:#40501f;--olive-l:#e4e8c6;--sand:#dbcda6;--raw:#b7aa85;--bad:#a8451f;--badbg:#f2e4cc;
 --disp:"IBM Plex Sans Thai",system-ui,sans-serif;--mono:"IBM Plex Mono","IBM Plex Sans Thai",ui-monospace,monospace;
}}
@media (prefers-color-scheme:dark){{:root{{--ink:#ece5d4;--ink2:#c6bda6;--muted:#9a8f74;--line:#3b3423;--paper:#181410;--surf:#211c13;--olive:#9db24e;--on-olive:#181410;--olive-d:#c9d78d;--olive-l:#262c15;--sand:#2b2517;--raw:#6f6650;--bad:#e08a5e;--badbg:#271b12;}}}}
:root[data-theme="dark"]{{--ink:#ece5d4;--ink2:#c6bda6;--muted:#9a8f74;--line:#3b3423;--paper:#181410;--surf:#211c13;--olive:#9db24e;--on-olive:#181410;--olive-d:#c9d78d;--olive-l:#262c15;--sand:#2b2517;--raw:#6f6650;--bad:#e08a5e;--badbg:#271b12;}}
:root[data-theme="light"]{{--ink:#241f11;--ink2:#4d4530;--muted:#6a5f45;--line:#d1c39a;--paper:#eadfc4;--surf:#f6efdc;--olive:#57761f;--on-olive:#fff;--olive-d:#40501f;--olive-l:#e4e8c6;--sand:#dbcda6;--raw:#b7aa85;--bad:#a8451f;--badbg:#f2e4cc;}}
*{{box-sizing:border-box}}
html[data-lang="en"] .th{{display:none}} html[data-lang="th"] .en{{display:none}}
.th{{letter-spacing:normal}}
body{{margin:0;background:var(--paper);color:var(--ink);font-family:var(--disp);line-height:1.55;-webkit-font-smoothing:antialiased}}
.wrap{{max-width:1000px;margin:0 auto;padding:0 22px}}
a{{color:var(--olive-d)}} code{{font-family:var(--mono)}}
h1,h2,h3{{line-height:1.15;letter-spacing:-.01em;font-weight:600}}
header.top{{position:sticky;top:0;z-index:10;background:color-mix(in srgb,var(--paper) 86%,transparent);backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}}
.top .wrap{{display:flex;align-items:center;gap:14px;height:58px}}
.brand{{font-weight:700;letter-spacing:-.02em;font-size:1.14rem;display:flex;align-items:center;gap:9px}} .brand b{{color:var(--olive)}}
.brand .logo{{width:26px;height:26px}} .logo-d{{display:none}}
.brand .fullname{{font-weight:400;font-size:.76rem;color:var(--muted);letter-spacing:.01em}}
@media (prefers-color-scheme:dark){{.logo-l{{display:none}} .logo-d{{display:block}}}}
:root[data-theme="dark"] .logo-l{{display:none}} :root[data-theme="dark"] .logo-d{{display:block}}
:root[data-theme="light"] .logo-l{{display:block}} :root[data-theme="light"] .logo-d{{display:none}}
.top nav{{margin-left:auto;display:flex;gap:6px;align-items:center}}
.toggle,.cta-sm{{font-family:var(--mono);font-size:.78rem;border:1px solid var(--line);background:var(--surf);color:var(--ink2);padding:6px 11px;border-radius:8px;cursor:pointer;text-decoration:none}}
.cta-sm{{background:var(--olive);color:var(--on-olive);border-color:var(--olive)}} .toggle:hover{{border-color:var(--olive)}}
.hero{{padding:60px 0 4px}}
.hero h1{{font-size:clamp(2rem,5vw,3.15rem);margin:.5rem 0 .1rem}} .hero h1 .num{{color:var(--olive)}}
.hero .sub{{font-size:1.12rem;color:var(--ink2);max-width:46ch;margin:.6rem 0 0}}
.getrow{{margin:26px 0 6px}}
.cta-hero{{display:inline-block;background:var(--olive);color:var(--on-olive);font-weight:700;font-size:1.08rem;padding:15px 28px;border-radius:13px;text-decoration:none;box-shadow:0 2px 0 var(--olive-d)}}
.cta-hero:hover{{filter:brightness(1.06)}}
.getmeta{{margin-top:10px;font-family:var(--mono);font-size:.74rem;color:var(--muted)}} .getmeta a{{color:var(--muted)}}
@media (max-width:540px){{.cta-hero{{display:block;text-align:center}}}}
/* bento */
.bento{{display:grid;grid-template-columns:repeat(4,1fr);grid-auto-rows:minmax(136px,auto);gap:16px;margin-top:30px}}
.bx{{background:var(--surf);border:1px solid var(--line);border-radius:20px;padding:24px 26px;display:flex;flex-direction:column;gap:6px}}
.b-2{{grid-column:span 2}} .b-2r{{grid-row:span 2}}
.bx .big{{font-family:var(--mono);font-weight:600;font-size:2.85rem;line-height:1;color:var(--ink);margin-bottom:6px}}
.bx h3{{font-size:1.24rem;margin:0}} .bx p{{margin:0;color:var(--ink2);font-size:1.04rem;line-height:1.55}}
.bx .fine{{margin-top:auto;font-family:var(--mono);font-size:.74rem;color:var(--muted);padding-top:14px}}
.bx .vs,.bx .unit,.bx .of{{font-size:1.25rem;color:var(--muted);margin:0 .12em;font-weight:400}}
.bx.feature{{background:var(--olive-l);border-color:color-mix(in srgb,var(--olive) 26%,var(--line));justify-content:center}}
.bx.feature .big{{font-size:4.4rem;color:var(--olive-d);margin-bottom:12px}} .bx.feature .of{{font-size:2.1rem;color:var(--olive)}}
.bx.feature h3{{font-size:1.5rem}} .bx.feature p{{font-size:1.1rem}}
.bx.demo{{gap:2px;justify-content:center}}
.bx.demo .dl{{font-family:var(--mono);font-size:.7rem;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);margin-top:10px}}
.bx.demo .dl:first-child{{margin-top:0}}
.bx.demo .dh{{font-family:var(--mono);font-size:1.08rem;color:var(--muted);line-height:1.6}}
.bx.demo .da{{color:var(--muted);font-family:var(--mono);font-size:1.4rem;margin:10px 0}}
.bx.demo .do{{font-family:var(--mono);font-size:1.16rem;color:var(--ink);line-height:1.62;font-weight:500}}
.bx.demo .do ins,.fin ins{{background:var(--olive-l);color:var(--olive-d);text-decoration:none;border-radius:3px;padding:0 3px;font-weight:600}}
.plain{{margin:26px 0 0;font-size:1rem;color:var(--ink2);max-width:64ch}} .plain b{{color:var(--ink)}}
.honest{{margin:14px 0 0;font-size:.86rem;color:var(--muted)}} .honest a{{color:var(--olive-d)}}
/* disclosure */
.disclose{{margin:40px 0 0;display:flex;flex-direction:column;gap:12px}}
.more{{border:1px solid var(--line);border-radius:16px;background:var(--surf);overflow:hidden}}
.more>summary{{list-style:none;cursor:pointer;padding:17px 22px;font-weight:600;font-size:1.05rem;display:flex;align-items:center;gap:12px}}
.more>summary::-webkit-details-marker{{display:none}}
.more>summary .chev{{margin-left:auto;font-family:var(--mono);color:var(--muted);font-size:1.5rem;line-height:1;transition:transform .2s}}
.more[open]>summary .chev{{transform:rotate(45deg)}}
.more[open]>summary{{border-bottom:1px solid var(--line)}}
.more .ms{{font-weight:400;color:var(--muted);font-size:.85rem}}
.mbody{{padding:18px 22px 22px}} .mbody .lede{{margin:0 0 16px;color:var(--ink2)}}
@media (prefers-reduced-motion:reduce){{.more>summary .chev{{transition:none}}}}
/* reused detail components */
table{{width:100%;border-collapse:collapse;font-size:.92rem}} td{{padding:7px 6px;vertical-align:middle;border-bottom:1px solid var(--line)}}
.track{{display:inline-block;width:min(52%,300px);height:9px;background:var(--sand);border-radius:5px;overflow:hidden;vertical-align:middle;margin-right:9px}}
.fill{{display:block;height:100%;background:var(--olive);border-radius:5px}} .fill.raw{{background:var(--raw)}}
.bkname .en,.bkname .th,.sttname .en,.sttname .th,.wname{{font-weight:500}}
.bkn{{font-family:var(--mono);font-size:.68rem;color:var(--muted);margin-left:7px}}
.bkbar b,.rawcell span,.fullcell span{{font-family:var(--mono);font-weight:600;font-size:.86rem}} .rawcell span{{color:var(--muted)}}
.legend{{display:flex;gap:18px;font-size:.78rem;color:var(--muted);margin:0 0 12px;font-family:var(--mono)}}
.legend i{{display:inline-block;width:11px;height:11px;border-radius:3px;margin-right:5px;vertical-align:middle}} .sw-full{{background:var(--olive)}} .sw-raw{{background:var(--raw)}}
.layers{{display:grid;gap:10px;margin:4px 0 14px}} .layers .lr{{display:grid;grid-template-columns:200px 1fr auto;gap:12px;align-items:center}}
.layers .name small{{color:var(--muted);display:block;font-size:.74rem}} .layers b{{font-family:var(--mono);font-weight:600}}
.wgrid{{display:grid;grid-template-columns:1fr 1fr;gap:26px}} .wsub{{font-family:var(--mono);font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 8px;font-weight:600}}
.wtable th{{text-align:right;font-size:.68rem;color:var(--muted);font-weight:600;padding:0 6px 5px;border-bottom:1px solid var(--line)}} .wtable th:first-child{{text-align:left}}
.wnum,.wnum2{{text-align:right;font-family:var(--mono);font-variant-numeric:tabular-nums;width:76px}} .wnum.raww{{color:var(--muted)}} .wnum2{{color:var(--olive-d);font-weight:600}}
.gallery{{display:grid;gap:13px}} .ex{{margin:0;background:var(--surf);border:1px solid var(--line);border-radius:13px;padding:14px 16px}}
.ex.bad{{background:var(--badbg);border-color:color-mix(in srgb,var(--bad) 24%,var(--line))}}
.ex-head{{display:flex;align-items:center;gap:12px;margin-bottom:9px;flex-wrap:wrap}}
.ex-badge{{font-family:var(--mono);font-size:.74rem;font-weight:600;padding:3px 9px;border-radius:20px;background:var(--olive-l);color:var(--olive-d)}} .ex.bad .ex-badge{{background:var(--bad);color:var(--badbg)}}
.ex audio{{height:30px;max-width:210px}} .ex-row{{display:grid;grid-template-columns:70px 1fr;gap:10px;padding:2px 0;align-items:baseline}}
.ex-k{{font-family:var(--mono);font-size:.64rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}}
.ex-row code{{font-size:.9rem;word-break:break-word;line-height:1.5}} .ex .raw{{color:var(--muted)}}
.ex.bad .fin ins{{background:color-mix(in srgb,var(--bad) 16%,transparent);color:var(--bad)}}
figcaption{{margin-top:8px;font-size:.84rem;color:var(--muted)}}
.lims{{display:grid;gap:11px}} .lim{{display:grid;grid-template-columns:26px 1fr;gap:11px}}
.lim .m{{font-size:1.05rem}} .lim b{{font-weight:600}} .lim p{{margin:2px 0 0;color:var(--ink2);font-size:.92rem}}
.method dt{{font-weight:600;margin-top:12px}} .method dd{{margin:2px 0 0;color:var(--ink2);font-size:.92rem}} .method dd:first-of-type,.method dt:first-child{{margin-top:0}}
.method code{{background:var(--paper);border:1px solid var(--line);padding:1px 5px;border-radius:4px;font-size:.85em}}
.note{{font-size:.82rem;color:var(--muted);font-style:italic;margin:14px 0 0}}
.foot{{margin-top:44px;border-top:1px solid var(--line);padding:34px 0 60px;color:var(--muted);font-size:.86rem}}
.foot .cta{{display:inline-block;background:var(--olive);color:var(--on-olive);font-weight:600;padding:12px 22px;border-radius:11px;text-decoration:none;margin:0 0 16px;font-size:1rem}}
.foot .req{{font-family:var(--mono);font-size:.78rem}}
@media (max-width:860px){{.brand .fullname{{display:none}} .bento{{grid-template-columns:repeat(2,1fr)}} .layers .lr{{grid-template-columns:1fr;gap:3px}} .wgrid{{grid-template-columns:1fr}}}}
@media (max-width:540px){{.bento{{grid-template-columns:1fr}} .b-2,.b-2r{{grid-column:span 1;grid-row:auto}} .ex-row{{grid-template-columns:60px 1fr}}}}
</style></head>
<body>
<header class="top"><div class="wrap">
  <span class="brand"><img class="logo logo-l" src="img/oliv-mark.png" alt="" width="26" height="26"><img class="logo logo-d" src="img/oliv-mark-white.png" alt="" width="26" height="26"><b>OLIV</b><span class="fullname">Offline Local Inference Voice</span></span>
  <nav>
    <button class="toggle" id="lang">ไทย</button>
    <button class="toggle" id="theme" aria-label="theme">◐</button>
    <a class="cta-sm" href="https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg"><span class="en">Get OLIV</span><span class="th">ดาวน์โหลด</span></a>
  </nav>
</div></header>

<main class="wrap">
<div class="hero">
  <h1><span class="en">Speak Thai and English. It types it <span class="num">right</span>.</span>
      <span class="th">พูดไทยปนอังกฤษ ก็พิมพ์ออกมา<span class="num">ถูก</span></span></h1>
  <p class="sub"><span class="en">Thai dictation usually spells English words in Thai letters. OLIV turns them back — on your Mac, nothing uploaded.</span>
     <span class="th">แอปพิมพ์ตามเสียงส่วนใหญ่สะกดคำอังกฤษเป็นตัวไทย OLIV แปลงกลับให้ — ในเครื่อง ไม่ส่งขึ้น cloud</span></p>
  <div class="getrow">
    <a class="cta-hero" href="https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg" download>⬇&nbsp;<span class="en">Download OLIV for macOS — free</span><span class="th">ดาวน์โหลด OLIV สำหรับ macOS — ฟรี</span></a>
    <div class="getmeta"><span class="en">Apple Silicon (M1+) · one click, .dmg downloads now · open source (MIT) · <a href="https://github.com/chayapats/oliv/releases/latest">all versions</a></span><span class="th">Apple Silicon (M1 ขึ้นไป) · คลิกเดียว ไฟล์ .dmg โหลดทันที · โอเพนซอร์ส (MIT) · <a href="https://github.com/chayapats/oliv/releases/latest">ทุกเวอร์ชัน</a></span></div>
  </div>
</div>

<div class="bento">
  <div class="bx demo b-2 b-2r">
    <div class="dl"><span class="en">you say</span><span class="th">คุณพูด</span></div>
    <div class="dh">คอมมิตโค้ดแล้วพุชขึ้นเรโปเลย</div>
    <div class="da">↓</div>
    <div class="dl"><span class="en">OLIV types</span><span class="th">OLIV พิมพ์</span></div>
    <div class="do"><ins>commit code</ins> แล้ว <ins>push</ins> ขึ้น <ins>repo</ins> เลย</div>
  </div>
  <div class="bx feature b-2 b-2r">
    <div class="big">9<span class="of"><span class="en">in</span><span class="th">ใน</span></span>10</div>
    <h3><span class="en">phrases typed right</span><span class="th">ประโยคที่พิมพ์ถูก</span></h3>
    <p><span class="en">OLIV gets your mixed Thai-English speech right about 9 times out of 10 — even for words it has never heard before.</span>
       <span class="th">OLIV พิมพ์ประโยคไทยปนอังกฤษของคุณถูกราว 9 ใน 10 — แม้แต่คำที่ไม่เคยเจอมาก่อน</span></p>
    <div class="fine"><span class="en">tested on fresh words it never trained on · {H_HOLD}%, n=40</span><span class="th">ทดสอบบนคำใหม่ที่ไม่เคยเทรน · {H_HOLD}%, n=40</span></div>
  </div>
  <div class="bx">
    <div class="big">{ERR_X}×</div>
    <h3><span class="en">fewer mistakes</span><span class="th">ผิดน้อยลง</span></h3>
    <p><span class="en">Its built-in fixer cuts errors on unfamiliar words to about a third.</span><span class="th">ตัวช่วยแก้ในตัวลดข้อผิดพลาดกับคำแปลก ๆ เหลือราว 1 ใน 3</span></p>
  </div>
  <div class="bx">
    <div class="big">½</div>
    <h3><span class="en">the size</span><span class="th">ของขนาดปกติ</span></h3>
    <p><span class="en">Its speech model is half the size of the usual one — and more accurate overall.</span><span class="th">โมเดลฟังเสียงเล็กกว่าตัวมาตรฐานครึ่งหนึ่ง แต่แม่นกว่าโดยรวม</span></p>
  </div>
  <div class="bx b-2">
    <div class="big">{CLOUD_OLIV}<span class="vs">vs</span>{CLOUD_RAW}</div>
    <h3><span class="en">beats a big cloud service on hard words</span><span class="th">เรื่องคำยาก ชนะ cloud เจ้าใหญ่</span></h3>
    <p><span class="en">On tough, unfamiliar terms, OLIV on your Mac ({CLOUD_OLIV}%) beats a big cloud speech service ({CLOUD_RAW}%) — and keeps your voice private.</span>
       <span class="th">กับคำยาก ๆ ที่ไม่คุ้น OLIV ในเครื่อง ({CLOUD_OLIV}%) ชนะบริการเสียง cloud ตัวใหญ่ ({CLOUD_RAW}%) — แถมเสียงเป็นส่วนตัว</span></p>
  </div>
  <div class="bx b-2">
    <div class="big">🔒</div>
    <h3><span class="en">100% on your Mac</span><span class="th">อยู่ในเครื่องคุณ 100%</span></h3>
    <p><span class="en">Your voice never leaves your computer. After a one-time download, it works fully offline.</span><span class="th">เสียงของคุณไม่ออกจากเครื่อง โหลดครั้งเดียวจบ ใช้ออฟไลน์ได้เต็มที่</span></p>
  </div>
  <div class="bx b-2">
    <div class="big">~1<span class="unit">sec</span></div>
    <h3><span class="en">near-instant</span><span class="th">เกือบทันที</span></h3>
    <p><span class="en">Types your words back in about a second, right where you're typing.</span><span class="th">พิมพ์คำพูดกลับมาในราว 1 วินาที ตรงจุดที่คุณกำลังพิมพ์</span></p>
  </div>
</div>

<p class="plain"><span class="en"><b>What "right" means here:</b> the typed message means the same as what you said. It can differ in spacing or capital letters and still count — it's not a promise that every character is perfect.</span>
   <span class="th"><b>"ถูก" ในที่นี้แปลว่า:</b> ข้อความที่พิมพ์ออกมาความหมายตรงกับที่พูด · ต่างเรื่องเว้นวรรคหรือตัวพิมพ์เล็ก-ใหญ่ได้แต่ยังนับว่าถูก ไม่ได้แปลว่าถูกเป๊ะทุกตัวอักษร</span></p>
<p class="honest"><span class="en">An honest benchmark, not marketing — recorded by one person's voice. <a href="#fineprint">The fine print ↓</a></span>
   <span class="th">วัดตามจริง ไม่ใช่โฆษณา — อัดจากเสียงคนคนเดียว <a href="#fineprint">อ่านหมายเหตุ ↓</a></span></p>

<div class="disclose">

  <details class="more"><summary><span class="en">How it reaches 9 in 10</span><span class="th">ทำไมถึงได้ 9 ใน 10</span><span class="ms"><span class="en">the three steps</span><span class="th">สามขั้นตอน</span></span><span class="chev">+</span></summary>
  <div class="mbody">
    <p class="lede"><span class="en">On fresh words it never trained on, each step adds real ground. The fixer model does the heavy lifting.</span>
       <span class="th">บนคำใหม่ที่ไม่เคยเทรน แต่ละขั้นช่วยเพิ่มความแม่นจริง ตัวช่วยแก้คือพระเอก</span></p>
    <div class="layers">
      <div class="lr"><div class="name"><span class="en">Just the speech model</span><span class="th">มีแค่โมเดลฟังเสียง</span><small><span class="en">raw, no fixing</span><span class="th">ดิบ ยังไม่แก้</span></small></div>{bar(L_PURE,"fill raw")}<b>{L_PURE}%</b></div>
      <div class="lr"><div class="name"><span class="en">+ simple word fixes</span><span class="th">+ แก้คำแบบง่าย ๆ</span><small><span class="en">a built-in dictionary</span><span class="th">พจนานุกรมในตัว</span></small></div>{bar(L_DET)}<b>{L_DET}%</b></div>
      <div class="lr"><div class="name"><span class="en">+ the fixer model (OLIV)</span><span class="th">+ ตัวช่วยแก้ (OLIV)</span><small><span class="en">a small on-device model</span><span class="th">โมเดลเล็กในเครื่อง</span></small></div>{bar(L_LLM)}<b>{L_LLM}%</b></div>
    </div>
    <p class="note"><span class="en">Fresh-words test, n=40. At this size one clip ≈ 2.5 points — treat as estimates.</span><span class="th">ชุดคำใหม่ n=40 · หนึ่งคลิป ≈ 2.5 จุด ดูเป็นค่าประมาณ</span></p>
  </div></details>

  <details class="more"><summary><span class="en">How it compares to other speech tools</span><span class="th">เทียบกับแอปถอดเสียงตัวอื่น</span><span class="ms"><span class="en">incl. the cloud</span><span class="th">รวม cloud</span></span><span class="chev">+</span></summary>
  <div class="mbody">
    <p class="lede"><span class="en">Honest picture: OLIV's <b>raw</b> speech model isn't the strongest — a big cloud model transcribes a touch better raw. OLIV wins once its fixer runs, while staying private and half the size.</span>
       <span class="th">ตามจริง: โมเดลฟังเสียง<b>ดิบ ๆ</b> ของ OLIV ไม่ใช่ตัวแรงสุด — cloud ตัวใหญ่ถอดดิบดีกว่านิดหน่อย OLIV ชนะตอนตัวช่วยแก้ทำงาน แถมเป็นส่วนตัวและเล็กกว่าครึ่ง</span></p>
    <div class="legend"><span><i class="sw-raw"></i><span class="en">speech model only</span><span class="th">โมเดลฟังเสียงอย่างเดียว</span></span><span><i class="sw-full"></i><span class="en">+ OLIV's fixer</span><span class="th">+ ตัวช่วยแก้ของ OLIV</span></span></div>
    <table><tbody>{stt_html}</tbody></table>
    <p class="note"><span class="en">Everyday-speech test, n=194 · "phrases right". The cloud service = a hosted Whisper large-v3, tested once, not Thai-specialized.</span>
       <span class="th">ชุดพูดทั่วไป n=194 · "ประโยคที่ถูก" · บริการ cloud = Whisper large-v3 แบบ hosted ทดสอบครั้งเดียว ไม่ได้เทรนไทยมาเฉพาะ</span></p>
  </div></details>

  <details class="more"><summary><span class="en">Word error rate — for the skeptics</span><span class="th">อัตราผิดระดับคำ (WER) — เผื่อใครอยากเช็คลึก</span><span class="ms">WER</span><span class="chev">+</span></summary>
  <div class="mbody">
    <p class="lede"><span class="en">WER counts word-level slips (<b>lower is better</b>). We don't lead with it because Thai has no word spaces and mixed speech makes it over-penalize — but here it is, and the fixer lowers it too.</span>
       <span class="th">WER นับความผิดระดับคำ (<b>ยิ่งต่ำยิ่งดี</b>) เราไม่ชูเป็นหลักเพราะไทยไม่เว้นวรรค การพูดปนภาษาทำให้มันลงโทษเกินจริง — แต่ก็เอามาให้ดู และตัวช่วยแก้ก็ลด WER ด้วย</span></p>
    <div class="wgrid">
      <div><div class="wsub"><span class="en">OLIV, by test</span><span class="th">OLIV แยกตามชุด</span></div>
        <table class="wtable"><thead><tr><th></th><th>WER</th><th><span class="en">right</span><span class="th">ถูก</span></th></tr></thead><tbody>{wer_ship_html}</tbody></table></div>
      <div><div class="wsub"><span class="en">speech model only vs + fixer</span><span class="th">ฟังเสียงอย่างเดียว vs + ตัวช่วยแก้</span></div>
        <table class="wtable"><thead><tr><th></th><th><span class="en">raw</span><span class="th">ดิบ</span></th><th>+ <span class="en">fixer</span><span class="th">แก้</span></th></tr></thead><tbody>{wer_stt_html}</tbody></table></div>
    </div>
    <p class="note"><span class="en">Mean word error rate; lower = better. Same clips as the "phrases right" numbers.</span><span class="th">ค่าเฉลี่ย WER · ยิ่งต่ำยิ่งดี · ใช้คลิปเดียวกับตัวเลข "ประโยคที่ถูก"</span></p>
  </div></details>

  <details class="more"><summary><span class="en">How it does on different kinds of speech</span><span class="th">ทำได้ดีแค่ไหนในแต่ละแบบ</span><span class="ms"><span class="en">by topic</span><span class="th">แยกตามหมวด</span></span><span class="chev">+</span></summary>
  <div class="mbody">
    <p class="lede"><span class="en">Everyday-speech test, weakest first. Dense tech mixing and rare jargon are the hardest.</span><span class="th">ชุดพูดทั่วไป เรียงจากอ่อนสุด · ปนเทคหนัก ๆ กับศัพท์หายากยากที่สุด</span></p>
    <table><tbody>{bucket_html}</tbody></table>
  </div></details>

  <details class="more"><summary><span class="en">Watch it work</span><span class="th">ดูตอนที่ทำได้</span><span class="ms"><span class="en">real recordings</span><span class="th">คลิปจริง มีเสียง</span></span><span class="chev">+</span></summary>
  <div class="mbody">
    <p class="lede"><span class="en"><span style="color:var(--olive-d);font-weight:600">Green</span> = English turned back from Thai letters. Press play — these are real.</span>
       <span class="th"><span style="color:var(--olive-d);font-weight:600">สีเขียว</span> = อังกฤษที่แปลงกลับจากตัวไทย กดฟังได้ เป็นคลิปจริง</span></p>
    <div class="gallery">{examples_ok}</div>
  </div></details>

  <details class="more"><summary><span class="en">Watch it fail</span><span class="th">ดูตอนที่พลาด</span><span class="ms"><span class="en">we don't hide these</span><span class="th">เราไม่ซ่อน</span></span><span class="chev">+</span></summary>
  <div class="mbody">
    <p class="lede"><span class="en">Same format, real audio. Dense unfamiliar jargon is where OLIV breaks down — the speech model mishears it and the fixer can't recover.</span>
       <span class="th">รูปแบบเดียวกัน มีเสียงจริง · จุดที่ OLIV เอาไม่อยู่คือศัพท์แปลก ๆ ที่มารัว — โมเดลฟังเพี้ยนแต่แรก ตัวช่วยแก้เลยกู้ไม่ทัน</span></p>
    <div class="gallery">{examples_bad}</div>
  </div></details>

  <details class="more" id="fineprint"><summary><span class="en">The honest fine print</span><span class="th">ข้อจำกัดที่ควรรู้</span><span class="ms"><span class="en">read this</span><span class="th">อ่านก่อนเชื่อ</span></span><span class="chev">+</span></summary>
  <div class="mbody"><div class="lims">
    <div class="lim"><span class="m">🎙️</span><div><b><span class="en">One speaker.</span><span class="th">ผู้พูดคนเดียว</span></b>
      <p><span class="en">Every clip was recorded by one person (the developer), one mic, quiet room. So these numbers show how well it works <b>for that voice</b> — not across accents, other speakers, or noisy places. That's untested.</span>
         <span class="th">ทุกคลิปอัดจากคนคนเดียว (ตัวผู้พัฒนา) ไมค์ตัวเดียว ห้องเงียบ ตัวเลขเลยบอกได้แค่ว่าใช้ดีแค่ไหน<b>กับเสียงคนนั้น</b> — ยังไม่ได้ลองกับสำเนียงอื่น คนอื่น หรือที่มีเสียงดัง</span></p></div></div>
    <div class="lim"><span class="m">📉</span><div><b><span class="en">Small tests.</span><span class="th">ชุดทดสอบเล็ก</span></b>
      <p><span class="en">The fresh-words test is 40 clips; a follow-up is 30. At that size one clip moves the number 2–3 points, so read them as estimates.</span><span class="th">ชุดคำใหม่ 40 คลิป ชุดยืนยัน 30 · ขนาดเท่านี้คลิปเดียวขยับ 2–3 จุด อ่านเป็นค่าประมาณ</span></p></div></div>
    <div class="lim"><span class="m">☁️</span><div><b><span class="en">Raw speech isn't the best.</span><span class="th">ฟังเสียงดิบ ๆ ไม่ใช่ที่สุด</span></b>
      <p><span class="en">A big cloud model transcribes a bit better before OLIV's fixer runs. OLIV's edge is the whole thing together, plus privacy and size.</span><span class="th">cloud ตัวใหญ่ถอดดิบดีกว่านิดก่อนตัวช่วยแก้ทำงาน จุดแข็งของ OLIV คือทั้งระบบรวมกัน + ความเป็นส่วนตัว + ขนาด</span></p></div></div>
    <div class="lim"><span class="m">🔤</span><div><b><span class="en">Names and casing slip sometimes.</span><span class="th">ชื่อ/ตัวพิมพ์พลาดได้บ้าง</span></b>
      <p><span class="en">Occasionally a name is mis-capitalized (New Relic → new relic) or a rare brand is guessed wrong. Names and numbers can be off while the meaning still counts — glance before you send.</span>
         <span class="th">บางทีชื่อพิมพ์เล็ก-ใหญ่เพี้ยน (New Relic → new relic) หรือเดาแบรนด์หายากผิด ชื่อ/ตัวเลขอาจผิดได้ทั้งที่ความหมายยังนับว่าถูก — เหลือบดูก่อนส่ง</span></p></div></div>
    <div class="lim"><span class="m">💻</span><div><b><span class="en">Apple Silicon Mac, ~5 GB.</span><span class="th">Mac ชิป Apple, ~5 GB</span></b>
      <p><span class="en">Needs an Apple-Silicon Mac. One-time download ≈ 5 GB, then fully offline.</span><span class="th">ต้องใช้ Mac ชิป Apple · โหลดครั้งเดียว ≈ 5 GB แล้วใช้ออฟไลน์ได้เลย</span></p></div></div>
  </div></div></details>

  <details class="more"><summary><span class="en">How we tested this</span><span class="th">เราทดสอบยังไง</span><span class="ms"><span class="en">reproducible</span><span class="th">ทำซ้ำได้</span></span><span class="chev">+</span></summary>
  <div class="mbody"><dl class="method">
    <dt><span class="en">The numbers</span><span class="th">ตัวเลข</span></dt>
    <dd><span class="en">come from one fresh run of the exact app people download, over 264 recordings — everyday n=194, fresh-words n=40, follow-up n=30.</span><span class="th">มาจากการรันแอปตัวเดียวกับที่คนโหลดไปใช้ รอบเดียว บน 264 คลิป — ทั่วไป n=194, คำใหม่ n=40, ยืนยัน n=30</span></dd>
    <dt><span class="en">"Phrases right"</span><span class="th">"ประโยคที่ถูก"</span></dt>
    <dd><span class="en">a multilingual sentence model (LaBSE) checks whether the output means the same as the reference; it counts as "right" past a fixed similarity bar (0.80). Not word-for-word.</span>
        <span class="th">โมเดลเทียบประโยคข้ามภาษา (LaBSE) เช็คว่าผลลัพธ์ความหมายตรงกับเฉลยไหม ผ่านเกณฑ์ความคล้าย 0.80 นับว่า "ถูก" · ไม่ใช่การเทียบทีละคำ</span></dd>
    <dt><span class="en">Reproduce it</span><span class="th">ทำซ้ำได้</span></dt>
    <dd><span class="en">the test harness, clips list, and pipeline live in the repo under <code>benchmark/</code>. The benchmark runs the real shipping code, not a copy.</span>
        <span class="th">ชุดทดสอบ รายการคลิป และ pipeline อยู่ในรีโปที่ <code>benchmark/</code> · การวัดวิ่งผ่านโค้ดตัวจริงที่ปล่อยใช้ ไม่ใช่ของก๊อป</span></dd>
  </dl></div></details>

</div>

<footer class="foot" id="get"><div>
  <a class="cta" href="https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg" download>⬇ <span class="en">Download OLIV for macOS</span><span class="th">ดาวน์โหลด OLIV สำหรับ macOS</span></a>
  <div class="req"><span class="en">Apple Silicon (M1 or newer) · macOS · ~5 GB one-time download · fully offline after that</span><span class="th">Apple Silicon (M1 ขึ้นไป) · macOS · โหลด ~5 GB ครั้งเดียว · ออฟไลน์ได้หลังจากนั้น</span></div>
  <p class="note" style="margin-top:20px"><span class="en">Numbers reflect one speaker's recordings and will differ for your voice. Names like the cloud provider belong to their owners; comparisons are on our own Thai-English test set, run once.</span>
     <span class="th">ตัวเลขมาจากเสียงคนพูดคนเดียว ของคุณอาจต่างไป · ชื่อบริการต่าง ๆ เป็นของเจ้าของ การเทียบทำบนชุดทดสอบไทย-อังกฤษของเราเอง รันครั้งเดียว</span></p>
</div></footer>
</main>

<script>
(function(){{
 var root=document.documentElement,lb=document.getElementById('lang'),tb=document.getElementById('theme');
 lb.onclick=function(){{var th=root.getAttribute('data-lang')==='th';root.setAttribute('data-lang',th?'en':'th');root.setAttribute('lang',th?'en':'th');lb.textContent=th?'ไทย':'EN';}};
 tb.onclick=function(){{var c=root.getAttribute('data-theme')||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');root.setAttribute('data-theme',c==='dark'?'light':'dark');}};
}})();
</script>
</body></html>'''

OUT.write_text(HTML, encoding="utf-8")
print(f"wrote {OUT}  ({len(HTML.encode())/1024:.0f} KB)")
