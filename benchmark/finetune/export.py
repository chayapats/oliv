#!/usr/bin/env python3
"""Turn recorded takes into a train/val split a Whisper finetune can read directly.

    python3 benchmark/finetune/export.py
    python3 benchmark/finetune/export.py --allow-unverified   # you had better mean it

Rows are {"audio": <abs path to 16 kHz mono wav>, "text": <label>} — what HuggingFace
`datasets` and every Whisper LoRA script expect.

THIS IS THE LAST GATE, so it re-derives every invariant instead of trusting what upstream
recorded. Two rounds of review taught that lesson the hard way: each earlier version
believed a field written by the recorder (the take hash, the verdict key, the label) and
each was wrong in a way that shipped audio under a sentence nobody had spoken. Anything
that can put a label in front of a model gets checked here, again, from the bytes:

  * the WAV on disk is re-hashed and must match the take that claims it
  * the label is re-hashed and must match the verdict that cleared it
  * every exported label is re-run through the leak guard, because the recorder can edit
    a sentence to anything and the generation-time guard never sees it
  * a verdict must exist for that exact (id, audio, label) and must SAY something —
    a row carrying only an identity is absence of evidence, not evidence of absence

There is NO override. A take without a verdict does not ship. If the verifier flagged a
take you believe is fine, `approve.py` plays it to you and records YOUR verdict — which is
stronger evidence than the model's, not weaker.

`select()` is a pure function so all of that is testable without a browser or a model.
"""
import argparse
import hashlib
import json
import random
from collections import Counter, defaultdict
from pathlib import Path

import evalcorpus
from matching import hostile_chars, is_eval_leak

FT = Path(__file__).resolve().parent
DS = FT / "dataset"
CLIPS = DS / "clips"
ROOT = FT.parent.parent

VAL_FRAC = 0.05
SEED = 42


def load(p: Path) -> list[dict]:
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]


def sha(b: bytes) -> str:
    return hashlib.sha1(b).hexdigest()[:16]


def select(takes, verdicts, clips_dir: Path, forbidden):
    """(rows, dropped). Pure — no I/O beyond reading the WAVs it is asked to vouch for."""
    latest: dict[str, dict] = {}
    for t in takes:                       # append-only; last row per id wins
        latest[t["id"]] = t
    have = {(v["id"], v.get("audio"), v.get("label")): v for v in verdicts}

    rows: list[dict] = []
    dropped: dict[str, list] = defaultdict(list)

    for cid, t in latest.items():
        if t.get("invalid"):
            dropped["invalidated — edited, awaiting re-record"].append(cid)
            continue

        wav = clips_dir / f"{cid}__{t.get('audio')}.wav"
        if not wav.exists():
            dropped["no audio on disk"].append(cid)
            continue
        # The take names the audio it was cut from. If the file no longer hashes to it,
        # something wrote over it — a crash mid-publish, a stray copy. Never guess.
        if sha(wav.read_bytes()) != t.get("audio"):
            dropped["audio on disk does not match the take that claims it"].append(cid)
            continue
        if sha(t["text"].encode()) != t.get("label"):
            dropped["label does not match its own hash (hand-edited jsonl?)"].append(cid)
            continue

        bad = hostile_chars(t["text"])
        if bad:
            dropped["label contains hostile characters"].append((cid, t["text"], bad))
            continue

        # A label edited in the recorder never passed the generation-time leak guard.
        hit = is_eval_leak(t["text"], forbidden)
        if hit:
            dropped["label leaks an eval sentence"].append((cid, t["text"], hit))
            continue

        v = have.get((cid, t.get("audio"), t.get("label")))
        if v is None:
            dropped["no verdict for THIS audio+label"].append(cid)
            continue
        # A verdict must SAY something. `v.get("judged", True)` and `v.get("flag")` meant a
        # row carrying nothing but an identity — no evidence that verification ran, let
        # alone passed — sailed through on Python's defaults. Absence of a field is absence
        # of evidence; demand it.
        # Present AND actually boolean. Checking only presence let {"judged": "false"}
        # through — a non-empty string is truthy — and {"flag": 0} read as clean. Python's
        # truthiness is a convenience, not a schema, and evidence needs a schema.
        if not isinstance(v.get("judged"), bool) or not isinstance(v.get("flag"), bool):
            dropped["malformed verdict (judged/flag not boolean)"].append(cid)
            continue
        if not v["judged"]:
            dropped["verifier could not judge"].append(cid)
            continue
        if v["flag"]:
            dropped["verifier says the audio does not say this"].append(
                (cid, t["text"], v.get("hyp", ""), v.get("sim")))
            continue

        rows.append({"audio": str(wav.resolve()), "text": t["text"], "id": cid,
                     "bucket": t.get("bucket", ""), "style": t.get("style", ""),
                     "device": t.get("device", ""), "dur": t.get("dur", 0.0),
                     "by": v.get("by", "model")})
    return rows, dropped


def main() -> None:
    ap = argparse.ArgumentParser()
    # There is deliberately NO --allow-unverified and NO --keep-flagged.
    #
    # They used to exist, gated behind an acknowledgement phrase and quarantined filenames,
    # and that was still the wrong shape. An override is a hole that never closes: the
    # moment the verifier is inconvenient — and at a 7% false-flag rate it WILL be
    # inconvenient — the path of least resistance is to type the magic words, and then
    # nothing vouches for anything.
    #
    # The real problem an override was solving is "this take is fine and the model is
    # wrong", and that has an honest answer: listen to it. approve.py plays the clip and
    # records YOUR verdict, which is better evidence than the model's, not weaker. Anything
    # without a verdict simply does not ship.
    a = ap.parse_args()

    takes = load(DS / "takes.jsonl")
    if not takes:
        raise SystemExit(f"ไม่มี take ใน {(DS / 'takes.jsonl').relative_to(ROOT)} — อัดก่อน")

    rows, dropped = select(takes, load(DS / "verify.jsonl"), CLIPS, evalcorpus.load())

    n_takes = len({t["id"] for t in takes})
    if not rows:
        print(f"{n_takes} takes -> 0 shipped")
        for reason, items in dropped.items():
            print(f"    {len(items):4d}  {reason}")
        raise SystemExit("\nไม่มี take ที่ผ่านเกณฑ์")

    # Hold out whole SENTENCES. A re-recorded line landing on both sides of the split
    # would turn the val score into a memorisation score.
    by_text: dict[str, list] = defaultdict(list)
    for r in rows:
        by_text[r["text"]].append(r)
    texts = sorted(by_text)
    random.Random(SEED).shuffle(texts)
    val_texts = set(texts[:max(1, round(len(texts) * VAL_FRAC))])

    train = [r for r in rows if r["text"] not in val_texts]
    val = [r for r in rows if r["text"] in val_texts]

    for name, part in (("train", train), ("val", val)):
        with (DS / f"{name}.jsonl").open("w", encoding="utf-8") as f:
            for r in part:
                f.write(json.dumps({"audio": r["audio"], "text": r["text"]},
                                   ensure_ascii=False) + "\n")

    hours = sum(r["dur"] for r in rows) / 3600
    # "verified" must mean it: an escape hatch of ANY kind voids the claim. It used to
    # ignore --keep-flagged entirely, so a set containing takes the verifier had actively
    # rejected still described itself as verified.
    human = sum(1 for r in rows if r.get("by") == "human")
    meta = {"clips": len(rows), "train": len(train), "val": len(val),
            "hours": round(hours, 2), "verified": True,
            "verified_by_human": human,
            "dropped": {k: len(v) for k, v in dropped.items()},
            "buckets": dict(Counter(r["bucket"] for r in rows)),
            "styles": dict(Counter(r["style"] for r in rows)),
            "devices": dict(Counter(r["device"] for r in rows)),
            "sample_rate": 16000, "channels": 1}
    (DS / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))

    print(f"{n_takes} takes -> {len(rows)} shipped  {hours:.2f} h")
    print(f"  train {len(train)} / val {len(val)}")
    print(f"  devices  {meta['devices']}")
    if dropped:
        print("\n  DROPPED:")
        for reason, items in dropped.items():
            print(f"    {len(items):4d}  {reason}")
        for cid, text, hyp, sim in dropped.get(
                "verifier says the audio does not say this", [])[:5]:
            print(f"\n    {cid}  sim {sim}\n      ควรพูด: {text}\n      ได้ยิน : {hyp}")
    flagged = len(dropped.get("verifier says the audio does not say this", []))
    if flagged:
        print(f"\n  {flagged} take(s) were flagged. Listen to them and settle it:\n"
              f"    benchmark/.venv/bin/python benchmark/finetune/approve.py")
    print(f"\n  {(DS / 'train.jsonl').relative_to(ROOT)}")
    print(f"  {(DS / 'val.jsonl').relative_to(ROOT)}")


if __name__ == "__main__":
    main()
