"""Assemble the comprehensive OLIV benchmark into one report_data.json + print the
key honest tables. Consumes benchmark/eval_results/full_*.json (fresh matrix, one
protocol) + _semantic.json (LaBSE meaning). Adds deterministic SURFACE metrics
(Thai<->Latin glue, Latin casing-mismatch vs reference) that the meaning metric
is blind to. Every number here is from the same fresh run of the shipped pipeline.
"""
from __future__ import annotations
import json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RES = ROOT / "eval_results"
SEM = json.loads((RES / "_semantic.json").read_text())["configs"]

GLUE = re.compile(r"[฀-๿][A-Za-z]|[A-Za-z][฀-๿]")
LATIN = re.compile(r"[A-Za-z][A-Za-z0-9]*")

def surface(final: str, ref: str):
    glue = len(GLUE.findall(final or ""))
    fmap = {}
    for t in LATIN.findall(final or ""): fmap.setdefault(t.lower(), t)
    rmap = {}
    for t in LATIN.findall(ref or ""): rmap.setdefault(t.lower(), t)
    # Only REAL casing losses: reference capitalized a proper noun/acronym and the
    # final lowercased it (under-casing, e.g. New Relic->new relic). Do NOT count the
    # reverse — the model capitalizing a sentence start where the (lazily-lowercase)
    # reference doesn't is not a defect; that would inflate the number and mislead.
    case = sum(1 for k, v in fmap.items()
               if k in rmap and rmap[k][0].isupper() and v[0].islower())
    return glue, case

# label -> (human, group, note)
CFG = {
 "e2b":      ("OLIV shipped — Typhoon STT + Gemma-E2B cleanup", "cleanup", "shipped"),
 "e4b":      ("Typhoon + Gemma-E4B (bigger cleanup)", "cleanup", ""),
 "nollm":    ("Typhoon + deterministic cleanup only (LLM off)", "cleanup", "ablation"),
 "tphgemma": ("Typhoon + Typhoon2.1-Gemma-4B (rejected)", "cleanup", ""),
 "v3prompt": ("Typhoon + E2B, V3 prompt (experimental)", "cleanup", "experimental"),
 "typhoon_pure":  ("Typhoon — raw STT, no cleanup", "stt", "pure"),
 "pathumma_e2b":  ("Pathumma STT + E2B cleanup", "stt", ""),
 "pathumma_pure": ("Pathumma — raw STT, no cleanup", "stt", "pure"),
 "largev3_e2b":   ("Whisper large-v3 + E2B cleanup", "stt", ""),
 "largev3_pure":  ("Whisper large-v3 — raw STT, no cleanup", "stt", "pure"),
 "groq_e2b":  ("Groq cloud (large-v3) + our E2B cleanup", "cloud", "cloud"),
 "groq_pure": ("Groq cloud (large-v3) — raw STT", "cloud", "cloud,pure"),
 "novocab":   ("OLIV without custom-vocabulary biasing", "ablation", ""),
}
SETS = ["main", "hold", "d2"]

def load(label, s):
    p = RES / f"full_{label}_{s}.json"
    if not p.exists(): return None
    d = json.loads(p.read_text())
    key = f"full_{label}_{s}"
    sem = SEM.get(key, {})
    simmap = {c["id"]: c["sim"] for c in sem.get("clips", [])}
    clips = []
    gl = cs = 0
    lat = []
    for c in d["clips"]:
        g, k = surface(c["final"], c["reference"])
        gl += g; cs += k; lat.append(c["latency_s"])
        clips.append({"id": c["id"], "bucket": c["bucket"], "sim": simmap.get(c["id"]),
                      "wer": c["wer"], "lat": c["latency_s"], "raw": c["raw"],
                      "final": c["final"], "ref": c["reference"], "gate": c.get("gate_reason"),
                      "glue": g, "case": k, "llm": c.get("llm_ran")})
    return {"n": len(clips), "sim": sem.get("overall_sim"), "match": sem.get("match_rate"),
            "wer": round(sum(x["wer"] for x in d["clips"])/len(d["clips"]), 3),
            "lat": round(sum(lat)/len(lat), 2), "glue": gl, "case": cs,
            "bucket": sem.get("aggregate", {}), "clips": clips}

data = {}
for label in CFG:
    data[label] = {"meta": CFG[label], "sets": {s: load(label, s) for s in SETS}}

(RES / "report_data.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

def row(label, s):
    r = data[label]["sets"].get(s)
    if not r: return None
    return r

print("="*92)
print("SHIPPED CONFIG (Typhoon + E2B + fixes) — the OLIV numbers")
print(f"{'set':8} {'n':>4} {'meaning-sim':>12} {'match@0.80':>11} {'WER':>6} {'latency':>8} {'glue':>5} {'case':>5}")
for s in SETS:
    r = row("e2b", s)
    if r: print(f"{s:8} {r['n']:>4} {r['sim']:>12.3f} {r['match']:>10}% {r['wer']:>6.3f} {r['lat']:>7}s {r['glue']:>5} {r['case']:>5}")

print("\n" + "="*92)
print("CLEANUP AXIS (STT=Typhoon) — sim / match% ; glue/case are surface flaws (lower=better)")
print(f"{'cleanup':40} {'main':>16} {'hold':>16} {'d2':>16} {'glueM':>6} {'caseM':>6}")
for label in ["e2b","e4b","nollm","tphgemma","v3prompt"]:
    def cell(s):
        r=row(label,s); return f"{r['sim']:.3f}/{r['match']:.0f}%" if r else "-"
    rm=row(label,"main")
    print(f"{CFG[label][0][:40]:40} {cell('main'):>16} {cell('hold'):>16} {cell('d2'):>16} {rm['glue']:>6} {rm['case']:>6}")

print("\n" + "="*92)
print("STT AXIS — raw STT vs +E2B cleanup (main | hold), sim/match%")
for label in ["typhoon_pure","pathumma_pure","largev3_pure","groq_pure","pathumma_e2b","largev3_e2b","groq_e2b"]:
    def cell(s):
        r=row(label,s); return f"{r['sim']:.3f}/{r['match']:.0f}%" if r else "-"
    print(f"  {CFG[label][0]:44} main {cell('main'):>14}   hold {cell('hold'):>14}")

print("\n" + "="*92)
print("ABLATION — custom vocab on/off (main | hold)")
for label in ["e2b","novocab"]:
    def cell(s):
        r=row(label,s); return f"{r['sim']:.3f}/{r['match']:.0f}%" if r else "-"
    print(f"  {CFG[label][0]:44} main {cell('main'):>14}   hold {cell('hold'):>14}")

print(f"\nwrote {RES/'report_data.json'}")
