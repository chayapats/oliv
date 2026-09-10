"""Context / semantic similarity metric for the OLIV eval (W6-EVAL).

WER penalizes word-by-word mismatches, which is unfair to Thai+English dictation:
"ดีพลอย" (transliterated) vs "deploy" is scored as an error even though the
MEANING is identical. This adds a real-world metric: encode the final output and
the reference with a MULTILINGUAL sentence encoder (LaBSE — trained so that a
sentence and its translation land close together) and take cosine similarity.
"log" vs "ล็อก", "deploy" vs "ดีพลอย" score near-identical, so this measures
"did the sentence convey the same thing" rather than "same surface words".

Runs OFFLINE on the cached per-clip outputs in benchmark/eval_results/*.json
(no STT/cleanup re-run), and writes benchmark/eval_results/_semantic.json:
    { config_key: { overall_sim, match_rate, aggregate:{bucket:{sim,match,n}},
                    clips:[{id,bucket,sim}] } }
where sim = mean cosine (0..1) and match_rate = % clips with sim >= THRESHOLD.

    benchmark/.venv/bin/python benchmark/semantic_score.py

metric_v2 (2026-07-08): word-segment BOTH sides with newmm before encoding.
LaBSE's WordPiece tokenizer emits a single [UNK] for any whitespace-free "word"
longer than max_input_chars_per_word=100. OLIV's normalize_thai_spacing strips
ALL Thai-Thai spaces, so a long-form Thai output became one 120-char unbroken
run -> encoded as garbage and scored against a normally-spaced reference (lf
clips hit NEGATIVE cosine despite near-perfect transcription). The reference
keeps natural spacing, so the bug uniquely penalized OLIV's (correct) spacing.
Fix: newmm-segment ref AND hyp uniformly (same tokenizer WER uses) so the
comparison is fair for every config -- verified lf 0.695->0.953, Groq lf
unchanged (it keeps spaces). This is a metric-version change: DO NOT mix v1 and
v2 numbers; re-baseline every config together.
"""

from __future__ import annotations

import glob
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "eval_results"
MODEL_ID = "sentence-transformers/LaBSE"
# Cosine >= THRESHOLD counts the clip as "meaning preserved". LaBSE puts
# same-meaning sentences ~0.9+ and translations ~0.85+, unrelated ~0.3, so 0.80
# is a conservative "clearly the same thing" bar. Reported alongside mean sim so
# the threshold choice is transparent, not load-bearing.
THRESHOLD = 0.80
METRIC_VERSION = "v2_newmm_seg"


def bucket_of(cid: str) -> str:
    m = re.match(r"[a-z]+", cid)
    return m.group() if m else cid


def seg_thai(text: str) -> str:
    """Insert spaces at Thai word boundaries (newmm) so LaBSE's WordPiece can
    tokenize long unspaced Thai instead of collapsing it to a single [UNK].
    Applied to BOTH reference and hypothesis so the comparison stays fair across
    every config. See the metric_v2 note in the module docstring."""
    from pythainlp.tokenize import word_tokenize
    toks = word_tokenize(text or " ", engine="newmm", keep_whitespace=True)
    return re.sub(r"\s+", " ", " ".join(toks)).strip()


def main() -> int:
    import numpy as np
    import torch
    from transformers import AutoModel, AutoTokenizer

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"loading {MODEL_ID} on {device} ...")
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModel.from_pretrained(MODEL_ID).to(device).eval()

    @torch.no_grad()
    def embed(texts: list[str]) -> "np.ndarray":
        # LaBSE sentence embedding = L2-normalized pooler_output (CLS→dense→tanh).
        out = []
        for i in range(0, len(texts), 64):
            batch = [t if t.strip() else " " for t in texts[i:i + 64]]
            enc = tok(batch, padding=True, truncation=True, max_length=256, return_tensors="pt").to(device)
            emb = model(**enc).pooler_output
            emb = torch.nn.functional.normalize(emb, p=2, dim=1)
            out.append(emb.cpu().numpy())
        return np.concatenate(out, axis=0)

    # Collect every (config, clip) pair; encode unique texts once.
    files = sorted(glob.glob(str(RESULTS / "*.json")))
    files = [f for f in files if not Path(f).name.startswith("_")]
    texts: dict[str, int] = {}
    def tid(s):
        s = s or ""
        if s not in texts:
            texts[s] = len(texts)
        return texts[s]

    per_config = {}
    for f in files:
        d = json.loads(Path(f).read_text(encoding="utf-8"))
        rows = []
        for c in d.get("clips", []):
            # metric_v2: newmm-segment both sides before encoding (see docstring).
            rows.append((c["id"], bucket_of(c["id"]),
                         tid(seg_thai(c["reference"])), tid(seg_thai(c["final"])),
                         bool(c.get("reference", "").strip()), bool(c.get("final", "").strip())))
        per_config[Path(f).stem] = rows

    uniq = [None] * len(texts)
    for s, i in texts.items():
        uniq[i] = s
    print(f"encoding {len(uniq)} unique texts across {len(files)} configs ...")
    E = embed(uniq)

    out = {"model": MODEL_ID, "threshold": THRESHOLD,
           "metric_version": METRIC_VERSION, "configs": {}}
    for key, rows in per_config.items():
        by_bucket: dict[str, list[float]] = {}
        sims = []
        clip_sims = []  # per-clip [{id,bucket,sim}] for the diff harness
        for cid, b, ri, hi, r_ok, h_ok in rows:
            sim = 0.0 if not (r_ok and h_ok) else float((E[ri] * E[hi]).sum())
            sim = max(0.0, min(1.0, sim))
            sims.append(sim)
            clip_sims.append({"id": cid, "bucket": b, "sim": round(sim, 4)})
            by_bucket.setdefault(b, []).append(sim)
        if not sims:
            continue
        agg = {}
        for b, xs in by_bucket.items():
            agg[b] = {"sim": round(sum(xs) / len(xs), 4),
                      "match": round(100.0 * sum(x >= THRESHOLD for x in xs) / len(xs), 1),
                      "n": len(xs)}
        out["configs"][key] = {
            "overall_sim": round(sum(sims) / len(sims), 4),
            "match_rate": round(100.0 * sum(x >= THRESHOLD for x in sims) / len(sims), 1),
            "aggregate": agg,
            "clips": clip_sims,
        }
        print(f"  {key:22} sim {out['configs'][key]['overall_sim']:.3f}  "
              f"match@{THRESHOLD} {out['configs'][key]['match_rate']}%")

    (RESULTS / "_semantic.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nwrote {RESULTS / '_semantic.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
