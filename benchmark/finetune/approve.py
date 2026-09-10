#!/usr/bin/env python3
"""Listen to the takes the verifier flagged, and settle them yourself.

    benchmark/.venv/bin/python benchmark/finetune/approve.py

The verifier is deliberately trigger-happy: it flags ~7% of correct readings in order to
catch 96% of skipped words, because a false flag costs one take and a skipped word poisons
the model silently and forever. That trade only works if the false flags have somewhere to
go — otherwise the honest response to "this take is fine and the model is wrong" is to
override the check, and an override is a hole that never closes.

So there is no override. There is this instead: play the audio, look at the sentence, and
decide. A human who has heard the clip is BETTER evidence than the model, not weaker — the
model's failure on these terms is the entire reason this corpus exists. Your decision is
recorded as a verdict like any other, and export treats it as one.

  [a] the audio does say this        -> approved, ships
  [r] it does not                    -> take retired, re-record it
  [p] play it again
  [s] skip for now
"""
import json
import subprocess
import sys
import termios
import time
import tty
from pathlib import Path

FT = Path(__file__).resolve().parent
DS = FT / "dataset"
CLIPS = DS / "clips"
TAKES, VERIFY = DS / "takes.jsonl", DS / "verify.jsonl"


def load(p: Path) -> list[dict]:
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]


def append(p: Path, row: dict) -> None:
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def key() -> str:
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        return sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def main() -> None:
    latest: dict[str, dict] = {}
    for t in load(TAKES):
        latest[t["id"]] = t
    verdicts: dict[tuple, dict] = {}
    for v in load(VERIFY):
        verdicts[(v["id"], v.get("audio"), v.get("label"))] = v   # last wins

    todo = []
    for cid, t in latest.items():
        if t.get("invalid"):
            continue
        v = verdicts.get((cid, t.get("audio"), t.get("label")))
        if v and v.get("judged") and v.get("flag"):
            todo.append((t, v))

    if not todo:
        print("ไม่มี take ที่ถูก flag — ไม่มีอะไรต้องตัดสิน")
        return

    print(f"{len(todo)} take ถูก flag ว่าเสียงอาจไม่ตรงกับข้อความ\n"
          f"  [a] เสียงพูดตามนี้จริง (โมเดลผิดเอง)   [r] ไม่ตรง — อัดใหม่\n"
          f"  [p] ฟังซ้ำ   [s] ข้ามไว้ก่อน   [q] ออก\n")

    approved = retired = 0
    for i, (t, v) in enumerate(todo, 1):
        wav = CLIPS / f"{t['id']}__{t['audio']}.wav"
        print(f"\n─── {i}/{len(todo)}  {t['id']}   sim={v.get('sim')} gap={v.get('gap')}")
        print(f"  ข้อความ : {t['text']}")
        print(f"  โมเดลได้ยิน: {v.get('hyp', '')}")
        while True:
            if wav.exists():
                subprocess.run(["afplay", str(wav)], check=False)
            else:
                print("  (ไม่พบไฟล์เสียง)")
            k = key().lower()
            if k == "p":
                continue
            break
        if k == "a":
            # A human listened. That is a verdict, and a better one than the model's.
            append(VERIFY, {"id": t["id"], "audio": t["audio"], "label": t["label"],
                            "hyp": v.get("hyp", ""), "sim": v.get("sim"),
                            "flag": False, "judged": True, "by": "human",
                            "ts": int(time.time())})
            approved += 1
            print("  ✓ อนุมัติ")
        elif k == "r":
            append(TAKES, {"id": t["id"], "invalid": True, "reason": "human rejected",
                           "audio": t.get("audio"), "text": t.get("text", ""),
                           "ts": int(time.time())})
            retired += 1
            print("  ✗ ทิ้ง — ต้องอัดใหม่")
        elif k == "q":
            break
        else:
            print("  … ข้าม")

    print(f"\nอนุมัติ {approved} · ทิ้ง {retired} · เหลือ {len(todo) - approved - retired}")
    if retired:
        print("รัน record.py อีกครั้ง แล้วอัดข้อที่ทิ้งไปใหม่")


if __name__ == "__main__":
    main()
