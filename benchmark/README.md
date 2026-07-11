# OLIV benchmark harness

The reproducible pipeline behind every number on
[the landing page](https://chayapats.github.io/oliv/). Nothing on that page is
hand-typed: results flow from these scripts into `eval_results/report_data.json`
and from there into `docs/index.html`.

## Layout

- `data/manifest_all.jsonl` (194 clips, everyday speech), `data/manifest_holdout.jsonl`
  (40 clips, fresh words recorded **before** any tuning), `data/manifest_d2.jsonl`
  (30 clips, confirmation) — reference texts for the 264-clip corpus. The audio is
  the developer's own voice and is not tracked; record your own set following
  `data/manifest.example.jsonl`.
- `eval_cleanup.py` — runs the **shipped pipeline** (the same code the app executes)
  over a manifest. `run_eval_full.sh` runs the full config matrix.
- `eval_models.py` — the same pipeline over alternative STT engines
  (Whisper large-v3, Pathumma, the cloud rows) for the comparison table.
- `semantic_score.py` — the "meaning match" metric: LaBSE cosine ≥ 0.80,
  Thai word-segmented before embedding. **Not** word-for-word accuracy.
- `metrics.py`, `engines.py`, `pipeline.py`, `dictionary.py`, `phonetic.py`,
  `prompts.py`, `cleanup_worker.py` — the pipeline pieces under test.
- `build_report_data.py` → `eval_results/report_data.json` (aggregate scores +
  surface metrics) · `build_landing.py` → `../docs/index.html`.
- `test_*.py` — hermetic tests (dictionary, pipeline guardrails, spacing).

## Reproduce

```bash
# from the repo root:
OLIV_TYPHOON_MLX_REPO=<local-or-hf-repo> HF_HUB_DISABLE_XET=1 \
  sidecar/.venv/bin/python benchmark/eval_cleanup.py \
    --manifest data/manifest_all.jsonl --engine typhoon-turbo-mlx \
    --out benchmark/eval_results/ship_main.json
sidecar/.venv/bin/python benchmark/semantic_score.py     # meaning scores
sidecar/.venv/bin/python benchmark/build_report_data.py  # -> report_data.json
sidecar/.venv/bin/python benchmark/build_landing.py      # -> docs/index.html
```

Env: see `.env.example` — a Groq key is needed only for the cloud comparison rows.
Deps: `requirements.txt` (or reuse the app's `sidecar/.venv`).
