#!/usr/bin/env python3
"""Build the personal-finetune term list from four sources and assign each term a
sentence quota for the script generator.

    S1  terms_manual.txt        — terms you typed yourself
    S2  repo mining             — git log + docs/*.md + code identifiers
    S3  eval_results            — terms the SHIPPED pipeline provably gets wrong
    S4  dictionary.py           — TRANSLIT / CANONICAL_CASE, already curated

S3 is the one that matters: it is not what we think breaks, it is what the
recorded corpus shows breaking. A term missing from `raw` is an acoustic miss —
the only error class a finetune can fix. Missing from `final` too means the
dictionary and Gemma could not recover it either.

    python3 benchmark/finetune/build_terms.py            # -> terms.jsonl + summary

Stdlib only, on purpose: this must run before anyone sets up a venv.
"""
import ast
import json
import re
import subprocess
from collections import defaultdict
from pathlib import Path

FT = Path(__file__).resolve().parent
BENCH = FT.parent
ROOT = BENCH.parent
DATA = BENCH / "data"

MANUAL = FT / "terms_manual.txt"
OUT = FT / "terms.jsonl"

# Shipped config only. Other engines' failures are not our problem to train away.
# These overlap (ship_main and full_e2b_main run the same manifest), so observations
# are deduped by (clip, term) — otherwise every miss gets counted twice.
EVAL_FILES = ["ship_main.json", "ship_hold.json", "full_e2b_main.json", "full_e2b_hold.json"]

# Quota is a COVERAGE target: how many times the term must occur across the whole
# script, in distinct contexts. It is NOT a sentence count — one sentence carries
# several terms at once ("deploy ... production ... merge branch main" = 5). The
# sentence total falls out of slots / DENSITY below.
QUOTA = {"P0": 24, "P1": 12, "P2": 6}

# Terms per sentence the generator should average. The hand-written corpus sits at
# 2.45; 3.0 is reachable without the sentences starting to sound like keyword soup,
# which would defeat the point of training on natural speech.
DENSITY = 3.0

STOP = set("""
the a an and or but if then else for of to in on at by with from as is are was were be been
this that these those it its it's we you i he she they them our your my me us do does did not
no yes can could will would should shall may might must have has had get got make made use used
what when where who why how all any some each more most other into over under out up down off
so than too very just now new old good bad big small one two three first last next
main test tests todo fix add remove update change set run build check
com www http https org net io dev app src lib bin tmp var etc usr
""".split())

CODEISH = re.compile(r"^(?:[a-z]+_[a-z_]+|[A-Z_]{3,}|.*\d{2,}.*)$")

# Mining artefacts that survive every structural filter but are not vocabulary:
# fragments of longer terms ("Root" from "root cause", "Airways" from "Thai Airways")
# and doc headings ("Effort"). Cheaper to name them than to invent a rule.
JUNK = {"thai", "effort", "root", "airways"}


def sh(*args: str) -> str:
    p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else ""


def load_jsonl(p: Path) -> list[dict]:
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text().splitlines()
            if l.strip() and not l.startswith("#")]


def norm(t: str) -> str:
    return re.sub(r"\s+", " ", t.strip())


def key(t: str) -> str:
    """Match keys case- and space-insensitively; 'Fine-Tune' == 'fine tune'."""
    return re.sub(r"[\s\-_]+", "", t.lower())


# ---------------------------------------------------------------- S4: dictionary
def from_dictionary() -> dict[str, str]:
    """Parse dictionary.py with ast — importing it would drag in pythainlp."""
    tree = ast.parse((BENCH / "dictionary.py").read_text())
    out: dict[str, str] = {}
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        name = getattr(node.targets[0], "id", "")
        if name not in ("TRANSLIT", "CANONICAL_CASE") or not isinstance(node.value, ast.Dict):
            continue
        for v in node.value.values:  # the English side is the value in both maps
            if isinstance(v, ast.Constant) and isinstance(v.value, str):
                out.setdefault(key(v.value), norm(v.value))
    return out


# A frozen ruler must never be a source of the vocabulary it exists to measure.
#
# manifest_holdout was authored with all-new jargon (Istio, Elasticsearch, Vault, Cassandra,
# Datadog, Triton...) precisely so it would test GENERALISATION — "none in manifest_all", per
# D2_HOLDOUT_PLAN.md. Then from_eval() harvested its `keywords` as top-weighted evidence, and
# spoken_vocab() used its sentences to vouch that repo-mined words are really spoken. The ruler
# became the evidence for itself, and 30 of its 40 clips now carry terms the finetune trains on.
#
# This does NOT un-contaminate the current holdout — Elasticsearch/Cassandra/Datadog/Kibana also
# arrive via dictionary.py and are legitimate vocabulary we SHOULD teach. It protects the next one.
# Note the asymmetry with evalcorpus.py, which must keep reading the holdout: that is leak DEFENCE
# (never train on an eval sentence), the opposite direction, and correct.
FROZEN_RULERS = frozenset({"manifest_holdout.jsonl"})

# Each site keeps the manifest set it always had, minus the frozen rulers. (Do NOT collapse
# these into one list: from_eval read 3 manifests and spoken_vocab read 5, and quietly widening
# either one would change what gets mined for reasons that have nothing to do with this fix.)
EVAL_MANIFESTS = tuple(m for m in ("manifest_all.jsonl", "manifest_holdout.jsonl",
                                   "manifest_d2.jsonl")
                       if m not in FROZEN_RULERS)
SPOKEN_MANIFESTS = tuple(m for m in ("manifest_all.jsonl", "manifest_holdout.jsonl",
                                     "manifest_d2.jsonl", "manifest_v2.jsonl",
                                     "manifest.jsonl")
                         if m not in FROZEN_RULERS)


# ---------------------------------------------------------------- S3: eval failures
def from_eval() -> dict[str, dict]:
    """Terms the shipped pipeline demonstrably drops, weighted by how badly."""
    manifests: dict[str, dict] = {}
    for m in EVAL_MANIFESTS:
        for r in load_jsonl(DATA / m):
            manifests[r["id"]] = r

    stats: dict[str, dict] = defaultdict(
        lambda: {"seen": 0, "raw_miss": 0, "final_miss": 0, "examples": []})
    seen_obs: set[tuple[str, str]] = set()  # (clip, term) — the eval files overlap

    for fname in EVAL_FILES:
        f = BENCH / "eval_results" / fname
        if not f.exists():
            continue
        for clip in json.load(f.open())["clips"]:
            kws = manifests.get(clip["id"], {}).get("keywords") or []
            raw = key(clip.get("raw") or "")
            final = key(clip.get("final") or "")
            for kw in kws:
                k = key(kw)
                if (clip["id"], k) in seen_obs:
                    continue
                seen_obs.add((clip["id"], k))
                s = stats[k]
                s["seen"] += 1
                s.setdefault("term", norm(kw))
                if k not in raw:
                    s["raw_miss"] += 1
                    if k not in final:
                        s["final_miss"] += 1
                        if len(s["examples"]) < 2:
                            s["examples"].append(
                                {"id": clip["id"], "ref": clip["reference"],
                                 "raw": clip.get("raw", ""), "final": clip.get("final", "")})
    return stats


def spoken_vocab() -> set[str]:
    """Every English token that appears in a sentence you have actually recorded.

    Repo mining alone is a bad proxy for speech: docs are full of words ('section',
    'overview', 'table') that no one dictates. A repo term that never shows up in a
    spoken sentence and is not in the dictionary is prose, not vocabulary.
    """
    out: set[str] = set()
    for m in SPOKEN_MANIFESTS:
        for r in load_jsonl(DATA / m):
            text = (r.get("reference") or "") + " " + (r.get("say") or "")
            for w in re.findall(r"[A-Za-z][A-Za-z0-9.+#-]{1,24}", text):
                out.add(key(w.strip(".-")))
    return out


# ---------------------------------------------------------------- S2: repo mining
def from_repo() -> dict[str, dict]:
    """Nominate candidates from prose you wrote. Low precision by nature, so we also
    record how often each term appears as a proper noun or acronym: 'Kubernetes',
    'Kafka', 'JWT' are vocabulary; 'table', 'before', 'instead' are just English.
    That shape test is what keeps repo-only terms honest — see classify() below.
    """
    text = " ".join([
        sh("git", "log", "--all", "--pretty=%s%n%b"),
        *[p.read_text(errors="ignore")
          for p in [*ROOT.glob("*.md"), *(ROOT / "docs").rglob("*.md")]
          if p.is_file()],
    ])
    out: dict[str, dict] = defaultdict(lambda: {"freq": 0, "proper": 0, "spell": ""})
    # Skip the first word of a sentence: it is capitalized by grammar, not by nature.
    for m in re.finditer(r"([.!?:\n]\s*)?([A-Za-z][A-Za-z0-9.+#-]{1,24})", text):
        w = m.group(2).strip(".-")
        if len(w) < 3 or w.lower() in STOP or CODEISH.match(w):
            continue
        e = out[key(w)]
        e["freq"] += 1
        if not m.group(1) and (w[0].isupper() or w.isupper()):
            e["proper"] += 1
        if not e["spell"] or (w[0].isupper() and not e["spell"][0].isupper()):
            e["spell"] = w
    return out


# ---------------------------------------------------------------- S1 + merge
def main() -> None:
    manual = [norm(l) for l in MANUAL.read_text().splitlines()
              if l.strip() and not l.lstrip().startswith("#")] if MANUAL.exists() else []

    dict_terms = from_dictionary()
    fails = from_eval()
    repo = from_repo()
    spoken = spoken_vocab()

    # Canonical spelling, best source wins: you > dictionary > eval > repo.
    display: dict[str, str] = {k: v["spell"] for k, v in repo.items()}
    for k, s in fails.items():
        display[k] = s["term"]
    for k, v in dict_terms.items():
        display[k] = v
    for t in manual:
        display[key(t)] = t

    manual_keys = {key(t) for t in manual}
    rows = []
    for k in manual_keys | set(dict_terms) | set(fails) | set(repo):
        if k in JUNK:
            continue
        f = fails.get(k, {})
        raw_miss, seen = f.get("raw_miss", 0), f.get("seen", 0)
        r = repo.get(k, {})
        freq, proper = r.get("freq", 0), r.get("proper", 0)
        sources = [s for s, hit in (("manual", k in manual_keys),
                                    ("dict", k in dict_terms),
                                    ("eval", k in fails),
                                    ("repo", freq > 0)) if hit]
        vouched = bool({"manual", "dict", "eval"} & set(sources))

        # Repo prose is not vocabulary. A term nobody vouched for earns its place
        # only by *looking* like a term: mostly capitalized mid-sentence, or an
        # acronym. That is what separates Kubernetes/Kafka/JWT from table/before.
        proper_noun = freq >= 4 and proper / freq >= 0.5

        if f.get("final_miss", 0) >= 1 or raw_miss >= 2:
            pri = "P0"                      # proven acoustic failure, unrecovered
        elif vouched and (raw_miss >= 1 or "manual" in sources or "dict" in sources):
            pri = "P1"                      # yours, curated, or a lighter failure
        elif proper_noun and k in spoken:
            pri = "P1"                      # nominated by repo, seen in real speech
        elif proper_noun:
            pri = "P2"                      # nominated by repo, unconfirmed
        else:
            continue  # prose you write but never say

        rows.append({
            "term": display.get(k) or k,
            "key": k,
            "priority": pri,
            "quota": QUOTA[pri],
            # P2 is a nomination, not a decision. Repo mining cannot tell a term you
            # say from an identifier you only ever type (SUFeedURL, Info.plist,
            # W0-T6). You promote the real ones by hand — see terms_manual.txt.
            "include": pri in ("P0", "P1"),
            "sources": sources,
            "repo_freq": freq,
            "eval_seen": seen,
            "raw_miss": raw_miss,
            "final_miss": f.get("final_miss", 0),
            "examples": f.get("examples", []),
        })

    rows.sort(key=lambda r: (r["priority"], -r["raw_miss"], -r["repo_freq"], r["key"]))
    OUT.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))

    write_review(rows)

    by = defaultdict(int)
    for r in rows:
        by[r["priority"]] += 1
    slots = sum(r["quota"] for r in rows if r["include"])
    sents = round(slots / DENSITY)

    print(f"{len(rows)} terms -> {OUT.relative_to(ROOT)}\n")
    print(f"  {'':4s} {'terms':>6s}  {'x quota':>7s}  {'= slots':>8s}")
    for p in ("P0", "P1"):
        print(f"  {p}   {by[p]:6d}  {QUOTA[p]:>7d}  {by[p] * QUOTA[p]:>8d}")
    print(f"  P2   {by['P2']:6d}  {'—':>7s}  {'(nominated, off by default)':>8s}")
    print(f"\n  IN SCRIPT: {by['P0'] + by['P1']} terms, {slots} slots -> ~{sents} sentences"
          f"  ~{sents * 9 / 3600:.1f} h at 9 s/clip")

    print("\nTop P0 — the shipped pipeline loses these outright:")
    for r in [r for r in rows if r["priority"] == "P0"][:12]:
        print(f"  {r['term']:22s} raw_miss {r['raw_miss']}/{r['eval_seen']}  final_miss {r['final_miss']}")
    print(f"\nReview and edit: {(FT / 'TERMS_REVIEW.md').relative_to(ROOT)}")
    print(f"Add your own:    {MANUAL.relative_to(ROOT)}  (then re-run this script)")


def write_review(rows: list[dict]) -> None:
    """A human-scannable view. The P2 section is the ask: tick what you actually say."""
    L = ["# Term list review", "",
         "`P0` proven acoustic failures — highest training value. `P1` yours, curated, or ",
         "lightly failing. `P2` **nominated by repo mining, OFF by default** — mostly ",
         "identifiers you type but never speak. Promote the real ones by copying them into ",
         "`terms_manual.txt`, then re-run `build_terms.py`.", ""]

    p0 = [r for r in rows if r["priority"] == "P0"]
    L += [f"## P0 — {len(p0)} terms, in script", "",
          "| term | lost by STT | unrecovered | evidence |", "|---|---|---|---|"]
    for r in p0:
        ex = r["examples"][0] if r["examples"] else None
        ev = f"`{ex['raw'][:38]}`" if ex else ""
        L.append(f"| **{r['term']}** | {r['raw_miss']}/{r['eval_seen']} | {r['final_miss']} | {ev} |")

    for p, note in (("P1", "in script"), ("P2", "NOT in script — tick to promote")):
        t = [r["term"] for r in rows if r["priority"] == p]
        L += ["", f"## {p} — {len(t)} terms, {note}", "", ", ".join(f"`{x}`" for x in t)]

    (FT / "TERMS_REVIEW.md").write_text("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
