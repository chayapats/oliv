# Server eval

Scoring helpers for an end-to-end eval of a running `oliv-api`: send each clip
through `/v1/dictate` (or its earlier `raw` text through `/v1/clean`), score the
replies with LaBSE similarity against the reference and keyword recall, then
summarise them with these tools. Only the code is in this repository. **No eval
data is included; bring your own clips and manifests**, plus your own runner and
results. Eval audio is private data: the `.gitignore` keeps `eval/**/*.jsonl`,
audio, `cache/` and `results/` out of git.

| File | Role |
|---|---|
| `evalscore.py` | Pure scoring and Markdown report rendering (unit-tested by `test_evalscore.py`) |
| `tune_report.py` | Compare scored runs by split |
| `prompts/` | Candidate cleanup prompts used during prompt tuning |

The original runner and the port check against the Python pipeline needed an
unpublished checkout of the retired Python reference, so they are not
published.

## Result rows

Both tools read JSONL, one object per clip: the `/v1/dictate` reply (`raw`,
`final`, timings, flags) merged with its manifest row, plus the LaBSE
similarities your runner computed:

```json
{"id": "th01", "set": "my-set", "split": "main", "reference": "ช่วยสรุปประเด็นหลักของการประชุมเมื่อเช้าให้หน่อย",
 "keywords": [], "scored": null, "raw": "...", "final": "...",
 "sim_final": 0.93, "sim_raw": 0.88, "kw_hit": null}
```

- `id`: unique; its letter prefix is the bucket used in reports (`th01` → `th`).
  Ids starting with `fm` (spoken formatting commands) are excluded from scores.
- `split`: `main` (the set you tune on), `extra` (a second set to confirm on),
  `holdout` (look once, at the end) or `validation` (reported apart from the
  overall score).
- `reference`: the exact ground-truth transcript.
- `keywords`: optional terms for keyword recall; `scored: "stt"` judges the
  recogniser (`raw`, `sim_raw`) instead of `final` (`sim_final`).

This is the same idea as the Mac benchmark's
[`benchmark/data/manifest.example.jsonl`](../../benchmark/data/manifest.example.jsonl).

```sh
python3 tune_report.py results/base.jsonl results/cand.jsonl
python3 -m unittest discover -s server/eval -p 'test_*.py'
```
