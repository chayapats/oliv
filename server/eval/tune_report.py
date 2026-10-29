#!/usr/bin/env python3
"""Compare scored runs by split: match@0.80, mean sim, and clips that flipped vs the first run.
    tune_report.py base.jsonl cand1.jsonl cand2.jsonl ...
Groups: tune = main (the set prompts are tuned on); confirm = extra + validation; holdout = look once, at the end."""
import json
import sys
from collections import defaultdict
from pathlib import Path

THRESH = 0.80


def load(p):
    return {r["id"]: r for r in map(json.loads, open(p, encoding="utf-8")) if r.get("sim_final") is not None}


def ok(r):
    s = r["sim_raw"] if r.get("scored") == "stt" else r["sim_final"]
    return s is not None and s >= THRESH


def sim(r):
    return r["sim_raw"] if r.get("scored") == "stt" else r["sim_final"]


def group(r):
    return {"main": "tune", "extra": "confirm", "validation": "confirm",
            "holdout": "holdout"}.get(r["split"], "other")


def main(paths):
    runs = [(Path(p).name, load(p)) for p in paths]
    base = runs[0][1]
    ids = [i for i in base if base[i]["bucket"] != "fm" and all(i in r for _, r in runs)]
    groups = defaultdict(list)
    for i in ids:
        groups["all"].append(i)
        groups[group(base[i])].append(i)
    print(f"{'run':38} " + "  ".join(f"{g:>17}" for g in ("tune", "confirm", "holdout", "all")))
    for name, r in runs:
        cells = []
        for g in ("tune", "confirm", "holdout", "all"):
            ii = groups[g]
            n = sum(ok(r[i]) for i in ii)
            cells.append(f"{n:3}/{len(ii):<3} {100 * n / len(ii):5.1f}% {sum(sim(r[i]) for i in ii) / len(ii):.3f}")
        print(f"{name[:38]:38} " + "  ".join(f"{c:>17}" for c in cells))
    print("\nflips vs first run (+ gained, - lost):")
    for name, r in runs[1:]:
        gain = [i for i in ids if ok(r[i]) and not ok(base[i])]
        lost = [i for i in ids if ok(base[i]) and not ok(r[i])]
        print(f"  {name[:30]:30} +{len(gain)} {gain}  -{len(lost)} {lost}")


if __name__ == "__main__":
    main(sys.argv[1:])
