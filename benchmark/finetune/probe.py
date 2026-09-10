"""The forgetting probe: eval clips containing NO term the finetune trains on.

WHY THIS EXISTS
---------------
The pilot's decision rule is "the holdout must not regress", used as a catastrophic-
forgetting detector. That only works if the holdout measures something the finetune is not
targeting — and it no longer does. 30 of its 40 clips carry terms that are in script.jsonl
(see build_terms.FROZEN_RULERS for how they got there). Finetune-driven term gains on those
clips push the score UP while forgetting pushes it DOWN, so a flat holdout number is
indistinguishable from "large gains masking real degradation" — the failure the corpus spec
already names: "the score climbs while the model does not improve, which is worse than
having no score."

These clips can detect it. Gains here are generalisation; losses are forgetting.

BOTH HALVES ARE CLEAN, and neither is luck:
  * their SENTENCES are not training labels — matching.is_eval_leak() forbids it, enforced
    at build, at the recorder's edit endpoint, and again at export;
  * their KEYWORDS are absent from script.jsonl — enforced here.

The complement (clips that DO carry a trained term) is not waste — it is the sharpest test
available of whether term learning GENERALISES: seen terms, unseen sentences. partition()
returns both halves for exactly that reason.

FROZEN AGAINST A SCRIPT SHA
---------------------------
The term review will grow script.jsonl. When it does, a clip whose keyword becomes trained
must be DROPPED from the probe and the base re-scored — never silently reinterpreted. A
probe that drifts under the model is not a ruler. Hence the sha in the manifest header.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import matching

FT = Path(__file__).resolve().parent
DATA = FT.parent / "data"
SOURCES = ("manifest_all.jsonl", "manifest_holdout.jsonl")
OUT = DATA / "manifest_ft_probe.jsonl"


def _rows(p: Path):
    for line in p.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            yield json.loads(line)


def script_texts() -> list[str]:
    return [json.loads(l)["text"]
            for l in (FT / "script.jsonl").read_text().splitlines() if l.strip()]


def read_script():
    """Parse script.jsonl ONCE. Deriving terms and the sha from a single read is load-bearing:
    two separate reads race — if the script changes between them, the manifest can keep a
    newly-trained term while recording the NEW script's sha, defeating both the contamination
    invariant and the pin meant to detect it (a second-eye finding)."""
    return [json.loads(l) for l in (FT / "script.jsonl").read_text().splitlines() if l.strip()]


def terms_of(rows) -> list[str]:
    terms: set[str] = set()
    for r in rows:
        terms.update(r.get("terms") or [])
    return sorted(terms)


def trained_terms() -> list[str]:
    """The terms the corpus deliberately teaches — the per-sentence `terms` annotations in
    script.jsonl (the corpus's own canonical notion of a term, ~281 of them)."""
    return terms_of(read_script())


def fingerprint(rows) -> str:
    """Hash EVERY field that determines probe membership. Since partition() keys on the trained
    `terms`, hashing only `text` would let an annotation-only edit silently change which clips are
    in the probe while the pin stayed identical — a changed ruler masquerading as the old baseline
    (a second-eye finding). Canonical: each row as {text, sorted terms}, in file order."""
    canon = [json.dumps({"text": r.get("text", ""), "terms": sorted(r.get("terms") or [])},
                        ensure_ascii=False, sort_keys=True) for r in rows]
    return hashlib.sha256("\n".join(canon).encode()).hexdigest()


def script_sha() -> str:
    return fingerprint(read_script())


def partition(clips, terms):
    """(trained_term, clean) by whether a clip's REFERENCE TEXT speaks any trained term.

    The reference, NOT the `keywords` annotation. Testing keywords was a real leak: those
    lists are absent or partial on whole buckets (every en* clip has keywords=None), so 16 of
    69 keyword-'clean' clips actually speak a trained term — main, report, deployment, deploy,
    milk... A finetune that memorises those would lift the clip's score, re-contaminating the
    forgetting signal by the very same door the mined holdout was contaminated through. The
    probe exists to escape that; testing the incomplete annotation walked straight back into it.

    `clips` may be manifest rows or results-JSON clip records; both carry `reference`. Uses
    matching.has_term — the ONE matcher (inventing a second regex is how `app` once matched
    `mapping`)."""
    trained, clean = [], []
    for c in clips:
        ref = c.get("reference") or c.get("ref") or ""
        (trained if any(matching.has_term(ref, t) for t in terms) else clean).append(c)
    return trained, clean


def select(script_rows, manifests):
    """Derive BOTH the trained terms and the pin sha from `script_rows` — one read, so a script
    edit mid-run cannot leave the manifest keying on one version while pinning another (#2)."""
    # Fail closed per SOURCE, not only on an empty combined result. manifest_all is private and
    # gitignored, so a fresh checkout or a truncated file could leave it empty while the holdout
    # rows keep the total non-empty — and freeze() would then publish a silently incomplete ruler.
    # Same discipline as evalcorpus.py ("fails closed on a missing OR empty manifest").
    empty = [n for n, rows in manifests.items() if not rows]
    if empty:
        raise SystemExit(f"REFUSING: source manifest(s) empty or missing: {empty}. The probe would "
                         f"be silently incomplete. (manifest_all is gitignored — is it present?)")
    terms = terms_of(script_rows)
    keep = []
    for name, rows in manifests.items():
        _, clean = partition(rows, terms)
        keep += [{**r, "_from": name} for r in clean]
    return keep, fingerprint(script_rows)


def select_from_disk():
    return select(read_script(), {n: list(_rows(DATA / n)) for n in SOURCES})


def freeze() -> None:
    rows, sha = select_from_disk()
    if not rows:
        raise SystemExit("REFUSING: the probe is empty — every eval clip carries a trained "
                         "term. There is no forgetting gate left; record a fresh one.")
    hdr = [
        "# OLIV finetune FORGETTING PROBE — generated by finetune/probe.py. Do not hand-edit.",
        "# Clips whose keywords appear NOWHERE in script.jsonl, so a score change here is",
        "# forgetting (down) or generalisation (up) — never memorisation of a trained term.",
        f"# script_sha256: {sha}",
        "# REGENERATE + RE-BASELINE whenever script.jsonl changes. A clip whose keyword becomes",
        "# trained must be DROPPED and the base re-scored, never silently reinterpreted.",
    ]
    OUT.write_text("\n".join(hdr + [json.dumps(r, ensure_ascii=False) for r in rows]) + "\n")
    src = {}
    for r in rows:
        src[r["_from"]] = src.get(r["_from"], 0) + 1
    print(f"{len(rows)} probe clips -> {OUT}")
    print("  by source:", ", ".join(f"{k}: {v}" for k, v in sorted(src.items())))
    print(f"  script_sha256: {sha}")


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def _clips_by_id(path):
    clips = json.loads(Path(path).read_text())["clips"]
    by_id = {}
    dupes = set()
    for c in clips:
        cid = c.get("id")
        if cid in by_id:
            dupes.add(cid)
        by_id[cid] = c
    if dupes:
        raise SystemExit(f"REFUSING: {path} has duplicate clip ids {sorted(dupes)} — the delta "
                         f"would average ambiguous rows.")
    return by_id


SEMANTIC = DATA.parent / "eval_results" / "_semantic.json"
MEANING_THRESHOLD = 0.80        # matches semantic_score.THRESHOLD


def _meaning_by_id(results_path):
    """{clip_id: sim} from _semantic.json for this results file's config (its stem). Empty if
    the semantic pass has not been run for it — meaning% is then reported as n/a, not skipped
    silently."""
    if not SEMANTIC.exists():
        return {}
    stem = Path(results_path).stem
    cfg = json.loads(SEMANTIC.read_text()).get("configs", {}).get(stem)
    if not cfg:
        return {}
    return {c["id"]: c["sim"] for c in cfg.get("clips", [])}


def compare(base_path, tuned_path):
    """Structured Gate 1 + Gate 2 comparison of two results JSONs. Returns a dict so a test can
    assert on real behaviour; report() prints it. Compares ONLY clips shared by id AND with a
    matching reference — aggregating files independently, or matching a stale id whose reference
    changed, both manufacture a delta with no model change (second-eye findings)."""
    terms = trained_terms()
    base_by, tuned_by = _clips_by_id(base_path), _clips_by_id(tuned_path)
    shared = sorted(set(base_by) & set(tuned_by))
    dropped = (set(base_by) ^ set(tuned_by))
    # a shared id whose reference text differs is NOT the same clip — refuse it
    mismatched = [c for c in shared
                  if (base_by[c].get("reference") or "") != (tuned_by[c].get("reference") or "")]
    if mismatched:
        raise SystemExit(f"REFUSING: {len(mismatched)} shared ids have different reference text "
                         f"across the two files (e.g. {mismatched[:3]}) — stale/mismatched "
                         f"manifests. The comparison would be meaningless.")
    shared = [c for c in shared if c not in mismatched]
    base_mean, tuned_mean = _meaning_by_id(base_path), _meaning_by_id(tuned_path)

    out = {"shared": len(shared), "dropped": sorted(dropped), "subsets": {}}
    for name in ("trained-term", "clean"):
        want_trained = name == "trained-term"
        cell = {}
        for tag, by, meanmap in (("base", base_by, base_mean), ("tuned", tuned_by, tuned_mean)):
            clips = [by[cid] for cid in shared]
            tr, cl = partition(clips, terms)
            grp = tr if want_trained else cl
            # meaning% requires EVERY clip in the subset to have semantic data — divide by the
            # subset size, not by however many happen to be covered, or a stale/partial
            # _semantic.json yields a confident-but-wrong number over a different denominator (#3).
            sims = [meanmap.get(c["id"]) for c in grp]
            covered = [s for s in sims if s is not None]
            # NOTE: _semantic.json stores sim rounded to 4dp, and semantic_score applies the 0.80
            # threshold before rounding — so a sim of true 0.79996 (stored 0.8000) can read as a
            # pass here. The boundary error is < 1e-4 of true sim; treat this meaning% as
            # semantic_score's match_rate to ~1 clip, not a bit-identical reproduction (#4).
            cell[tag] = {
                "n": len(grp),
                "kw_recall": _mean([c.get("kw_recall") for c in grp]),
                "wer": _mean([c.get("wer") for c in grp]),        # eval_cleanup writes "wer"
                "meaning_pct": (100.0 * sum(s >= MEANING_THRESHOLD for s in covered) / len(grp)
                                if grp and len(covered) == len(grp) else None),
            }
        out["subsets"][name] = cell
    return out


def report(base_path: str, tuned_path: str) -> dict:
    """Print the Gate 1 + Gate 2 comparison; also return the structured result (see compare())."""
    r = compare(base_path, tuned_path)
    if r["dropped"]:
        print(f"WARNING: {len(r['dropped'])} clips not shared by both files were dropped.")
    print(f"comparing {r['shared']} shared clips\n")
    print(f"{'subset':<14}{'cfg':<7}{'n':>4}{'kw_recall':>11}{'wer':>8}{'meaning%':>10}")
    labels = {"trained-term": "GATE 1  did the terms generalise?",
              "clean": "GATE 2  did it forget?"}
    for name, cell in r["subsets"].items():
        for tag in ("base", "tuned"):
            c = cell[tag]
            kr = f"{c['kw_recall']:.3f}" if c["kw_recall"] is not None else "n/a"
            wer = f"{c['wer']:.3f}" if c["wer"] is not None else "n/a"
            mp = f"{c['meaning_pct']:.1f}" if c["meaning_pct"] is not None else "n/a"
            print(f"{name:<14}{tag:<7}{c['n']:>4}{kr:>11}{wer:>8}{mp:>10}")
        b, t = cell["base"], cell["tuned"]
        if b["kw_recall"] is not None and t["kw_recall"] is not None:
            print(f"{'':<14}Δ kw_recall {t['kw_recall'] - b['kw_recall']:+.3f}   <- {labels[name]}")
        if b["meaning_pct"] is not None and t["meaning_pct"] is not None:
            print(f"{'':<14}Δ meaning%  {t['meaning_pct'] - b['meaning_pct']:+.1f}")
        print()
    if all(cell[t]["meaning_pct"] is None for cell in r["subsets"].values() for t in ("base", "tuned")):
        print("meaning% is n/a — run semantic_score.py so eval_results/_semantic.json covers these configs")
    return r


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--report", action="store_true",
                    help="score the trained-term / clean subsets of two results JSONs")
    ap.add_argument("--base", help="base-model results JSON (with --report)")
    ap.add_argument("--tuned", help="finetuned results JSON (with --report)")
    a = ap.parse_args()
    if a.report:
        if not (a.base and a.tuned):
            raise SystemExit("--report needs --base and --tuned")
        report(a.base, a.tuned)
    else:
        freeze()


if __name__ == "__main__":
    main()
