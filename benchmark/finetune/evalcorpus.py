#!/usr/bin/env python3
"""The eval corpus, loaded once and fail-closed.

Every sentence eval_models.py scores against. If one of these reaches the training set,
the holdout stops measuring anything: the score climbs while the model does not improve,
which is worse than having no score at all.

Fails closed on a MISSING manifest and on an EMPTY one. The second case is the one that
bites — several of these files are gitignored (they hold the user's own sentences), so a
fresh clone, a partial restore or a truncated write leaves a path that exists and reads
as zero references. A guard armed against an empty corpus reports success.
"""
import json
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"

MANIFESTS = ["manifest_all.jsonl", "manifest_holdout.jsonl", "manifest_d2.jsonl",
             "manifest_v2.jsonl", "manifest.jsonl"]


def load(data_dir: Path | None = None) -> list[str]:
    d = data_dir or DATA
    bad, out = [], []
    for m in MANIFESTS:
        p = d / m
        if not p.exists():
            bad.append(f"{m}: missing")
            continue
        refs = []
        for line in p.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#"):
                r = json.loads(line)
                if r.get("reference"):
                    refs.append(r["reference"])
        if not refs:
            bad.append(f"{m}: no references in it")
        out += refs
    if bad:
        raise SystemExit(
            "ABORT — the eval corpus is incomplete, so the leak guard would be a "
            "no-op:\n  " + "\n  ".join(bad) +
            "\n\n  These manifests are gitignored (they are your own recordings), so a "
            "fresh\n  checkout will not have them. Restore them first. A guard armed "
            "against a\n  partial corpus hands you a training set that only looks clean.")
    return sorted(set(out))
