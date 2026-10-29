"""Pure scoring for the server eval. No LaBSE, no network.

Each result row is one `/v1/dictate` reply merged with its manifest row, plus the
LaBSE similarities `sim_final`/`sim_raw` (computed by your own runner) and `kw_hit`
(keyword recall on the scored text, None when the clip has no keywords).
"""
from __future__ import annotations

import re

THRESHOLD = 0.80  # Oliv semantic_score.THRESHOLD
EXCLUDED_BUCKETS = {"fm"}  # spoken formatting commands are not in v1
GROUPS = ("overall", "main", "holdout", "extra", "validation")
# A row's split names its group; "validation" is reported apart from overall.
SPLIT_GROUP = {g: g for g in GROUPS[1:]}
# The selection rule: the winner may not score below v2 on these buckets.
GUARD_BUCKETS = ("th", "en")


def bucket_of(cid: str) -> str:
    """Oliv's bucket_of: the id's letter prefix (mx01 -> mx, hx201 -> hx)."""
    m = re.match(r"[a-z]+", cid)
    return m.group() if m else cid


def group_of(r: dict) -> str:
    return SPLIT_GROUP[r["split"]]


def excluded(r: dict) -> bool:
    return bucket_of(r["id"]) in EXCLUDED_BUCKETS


def scored_text(r: dict) -> str:
    """`scored:"stt"` clips judge the recogniser, so they score `raw`."""
    return r["raw"] if r.get("scored") == "stt" else r["final"]


def scored_sim(r: dict) -> float:
    return r["sim_raw"] if r.get("scored") == "stt" else r["sim_final"]


def oliv_sim(r: dict) -> float:
    """Oliv's semantic_score.py always scores `final`."""
    return r["sim_final"]


def percentile(xs, p):
    """Linear interpolation, same as numpy.percentile's default."""
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def _mean(xs):
    return sum(xs) / len(xs) if xs else None


def summarize(rows: list[dict], sim=scored_sim) -> dict:
    sims = [sim(r) for r in rows]
    kws = [r["kw_hit"] for r in rows if r.get("kw_hit") is not None]
    t_stt = [r["t_stt"] for r in rows]
    t_cl = [r["t_cleanup"] for r in rows]
    total = [a + b for a, b in zip(t_stt, t_cl)]
    return {
        "n": len(rows),
        "match": 100 * sum(s >= THRESHOLD for s in sims) / len(sims) if sims else None,
        "sim": _mean(sims),
        "kw": 100 * _mean(kws) if kws else None,
        "kw_n": len(kws),
        "stt_p50": percentile(t_stt, 50), "stt_p95": percentile(t_stt, 95),
        "cleanup_p50": percentile(t_cl, 50), "cleanup_p95": percentile(t_cl, 95),
        "total_p50": percentile(total, 50), "total_p95": percentile(total, 95),
        "llm_errors": sum(1 for r in rows if r.get("cleanup_error")),
    }


def breakdown(rows: list[dict]) -> dict:
    kept = [r for r in rows if not excluded(r)]
    corpus = [r for r in kept if group_of(r) != "validation"]
    groups = {"overall": summarize(corpus)}
    for g in GROUPS[1:]:
        groups[g] = summarize([r for r in kept if group_of(r) == g])
    buckets = {}
    for r in corpus:
        buckets.setdefault(bucket_of(r["id"]), []).append(r)
    return {
        "groups": groups,
        "buckets": {b: summarize(rs) for b, rs in sorted(buckets.items())},
        "oliv_holdout": summarize([r for r in kept if group_of(r) == "holdout"], sim=oliv_sim),
        "excluded": len(rows) - len(kept),
    }


def choose(by_prompt: dict[str, dict]) -> tuple[str, dict[str, str]]:
    """Highest overall match wins, unless it scores below v2 on th/en.
    Ties go to the higher mean similarity, then to v2 (the incumbent)."""
    base = by_prompt["v2"]["buckets"]
    why = {}
    for p, b in by_prompt.items():
        worse = [k for k in GUARD_BUCKETS if b["buckets"][k]["match"] < base[k]["match"]]
        why[p] = "ok" if not worse else "ต่ำกว่า v2 ที่ " + ", ".join(worse)
    ok = [p for p in by_prompt if why[p] == "ok"]
    win = max(ok, key=lambda p: (by_prompt[p]["groups"]["overall"]["match"],
                                 by_prompt[p]["groups"]["overall"]["sim"], p == "v2"))
    return win, why


# --------------------------------------------------------------------------- #
# Markdown reports
# --------------------------------------------------------------------------- #
def _f(x, fmt="{:.1f}"):
    return "–" if x is None else fmt.format(x)


def _lat(s, k):
    return f"{_f(s[k + '_p50'], '{:.2f}')} / {_f(s[k + '_p95'], '{:.2f}')}"


def _short(s: str, n: int = 90) -> str:
    s = " ".join((s or "").split()).replace("|", "\\|")
    return s if len(s) <= n else s[: n - 1] + "…"


def summary_table(named: dict[str, dict]) -> list[str]:
    out = ["| ชุด | n | match@0.80 | sim เฉลี่ย | keyword hit | รวม p50/p95 (s) | STT p50/p95 | cleanup p50/p95 | LLM error |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for name, s in named.items():
        kw = "–" if s["kw"] is None else f"{s['kw']:.1f}% ({s['kw_n']})"
        out.append(f"| {name} | {s['n']} | {_f(s['match'])}% | {_f(s['sim'], '{:.3f}')} | {kw} | "
                   f"{_lat(s, 'total')} | {_lat(s, 'stt')} | {_lat(s, 'cleanup')} | {s['llm_errors']} |")
    return out


def render_prompt_report(prompt: str, rows: list[dict], meta: dict) -> str:
    b = breakdown(rows)
    kept = [r for r in rows if not excluded(r)]
    misses = sorted((r for r in kept if scored_sim(r) < THRESHOLD), key=scored_sim)
    o = b["oliv_holdout"]
    lines = [
        f"# Eval {meta['date']} — prompt {prompt}",
        "",
        f"`oliv-api` {meta.get('version', '?')} · STT typhoon-whisper-turbo · Gemma 4 E2B Q4_K_M · "
        f"{len(rows)} คลิป (ตัด `fm` ออก {b['excluded']})",
        "",
        "ส่งเสียง 16 kHz mono ไป `/v1/dictate` ด้วยค่าเดียวกับ client: `cleanup`, `remove_fillers`, "
        "`thai_format` เปิด, `vocabulary` = `vocab` ของคลิป (มีแค่ vb, ใช้หลัง STT เท่านั้น) · STT ทำแบบ Oliv "
        "(ไม่มี initial prompt, re-decode เป็นอังกฤษเมื่อ avg_logprob < −0.30) · meaning-match = LaBSE ตามวิธีของ "
        "`semantic_score.py` (metric v2: ตัดคำ newmm ทั้งสองฝั่ง, cosine ≥ 0.80) · คลิป `scored:\"stt\"` "
        "ให้คะแนนที่ `raw` นอกนั้นให้คะแนนที่ `final` · keyword hit = `metrics.keyword_recall` ของ Oliv "
        "เฉลี่ยเฉพาะคลิปที่มี keyword · latency มาจาก `t_stt`/`t_cleanup` ของเซิร์ฟเวอร์",
        "",
        "## ตามชุด",
        "",
        *summary_table({("รวม" if g == "overall" else g): s for g, s in b["groups"].items()}),
        "",
        "## ตาม bucket (รวม)",
        "",
        *summary_table(b["buckets"]),
        "",
        "## เทียบกับ Oliv",
        "",
        f"holdout แบบ Oliv (ให้คะแนน `final` ทุกคลิป) ได้ **{_f(o['match'])}%** ({o['n']} คลิป, "
        f"sim {_f(o['sim'], '{:.3f}')})",
        "",
        f"## คลิปที่ต่ำกว่า {THRESHOLD} ({len(misses)})",
        "",
        "| id | sim | reference | ที่ให้คะแนน | flag |",
        "|---|---:|---|---|---|",
    ]
    for r in misses:
        flag = r.get("guardrail_flag") or r.get("gate_reason") or ""
        if r.get("cleanup_error"):
            flag += " (llm error)"
        lines.append(f"| {r['id']} | {scored_sim(r):.3f} | {_short(r['reference'])} | "
                     f"{_short(scored_text(r))} | {_short(flag, 40)} |")
    return "\n".join(lines) + "\n"


def render_compare(by_prompt: dict[str, list[dict]], meta: dict) -> str:
    bds = {p: breakdown(rs) for p, rs in by_prompt.items()}
    win, why = choose(bds)
    ps = list(by_prompt)
    head = "| | " + " | ".join(ps) + " |"
    sep = "|---|" + "---:|" * len(ps)

    def cell(s):
        return f"{_f(s['match'])}% · {_f(s['sim'], '{:.3f}')}"

    lines = [f"# Eval {meta['date']} — เทียบ prompt", "",
             f"**ผู้ชนะ: {win}** (match@0.80 รวมสูงสุด โดย `th` และ `en` ต้องไม่ต่ำกว่า v2)", "",
             "รายละเอียดแต่ละ prompt อยู่ในไฟล์ `" + meta["date"] + "-<prompt>.md` · ค่าในตารางคือ match@0.80 · sim เฉลี่ย",
             "", "## ตามชุด", "", head, sep]
    for g in GROUPS:
        lines.append(f"| {'รวม' if g == 'overall' else g} | " + " | ".join(cell(bds[p]["groups"][g]) for p in ps) + " |")
    lines.append("| holdout แบบ Oliv | " + " | ".join(cell(bds[p]["oliv_holdout"]) for p in ps) + " |")
    lines.append("| keyword hit (รวม) | " + " | ".join(f"{_f(bds[p]['groups']['overall']['kw'])}%" for p in ps) + " |")
    lines.append("| cleanup p50/p95 (s) | " + " | ".join(_lat(bds[p]["groups"]["overall"], "cleanup") for p in ps) + " |")
    lines.append("| LLM error | " + " | ".join(str(bds[p]["groups"]["overall"]["llm_errors"]) for p in ps) + " |")
    lines.append("| STT re-decode เป็นอังกฤษ | " + " | ".join(
        str(sum(1 for r in by_prompt[p] if r.get("stt_redecoded"))) for p in ps) + " |")
    lines.append("| กติกาเลือก | " + " | ".join(why[p] for p in ps) + " |")
    lines += ["", "## ตาม bucket (รวม)", "", head, sep]
    for bk in bds[ps[0]]["buckets"]:
        lines.append(f"| {bk} (n={bds[ps[0]]['buckets'][bk]['n']}) | "
                     + " | ".join(cell(bds[p]["buckets"][bk]) for p in ps) + " |")
    return "\n".join(lines) + "\n"
