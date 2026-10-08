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
- `eval_cleanup.py` / `native_runtime.py` — drive the **shipped Rust + native MLX pipeline**
  over a manifest. `run_eval_full.sh` runs the full config matrix.
- `eval_models.py` — the same pipeline over alternative STT engines
  (Whisper large-v3, Pathumma, the cloud rows) for the comparison table.
- `semantic_score.py` — the "meaning match" metric: LaBSE cosine ≥ 0.80,
  Thai word-segmented before embedding. **Not** word-for-word accuracy.
- `metrics.py`, `engines.py`, `pipeline.py`, `dictionary.py`, `phonetic.py`,
  `prompts.py`, `cleanup_worker.py` — the previous Python reference, used with
  `--runtime reference` and by older model experiments.
- `build_report_data.py` → `eval_results/report_data.json` (aggregate scores +
  surface metrics) · `build_landing.py` → `../docs/index.html`.
- `test_*.py` — hermetic tests (dictionary, pipeline guardrails, spacing).

## Reproduce

```bash
# from the repo root:
bash scripts/build_native.sh
HF_HUB_OFFLINE=1 \
  sidecar/.venv/bin/python benchmark/eval_cleanup.py \
    --manifest data/manifest_all.jsonl --engine typhoon-turbo-mlx \
    --out benchmark/eval_results/ship_main.json
sidecar/.venv/bin/python benchmark/semantic_score.py     # meaning scores
sidecar/.venv/bin/python benchmark/build_report_data.py  # -> report_data.json
sidecar/.venv/bin/python benchmark/build_landing.py      # -> docs/index.html
```

Env: see `.env.example` — a Groq key is needed only for the cloud comparison rows.
Deps: `requirements.txt`, ffmpeg, and a built native runtime. A previous
`sidecar/.venv` can be reused for developer benchmarks; it is never bundled.
Download models explicitly in OLIV's Settings before an offline native run.
Native inference reuses `HF_HOME`, or the installed app's model cache if present.
The published landing-page results predate the native migration; regenerate
the entire comparison matrix before replacing them. File conversion is timed
in `latency_s`; `t_stt` and `t_cleanup` isolate the capture-shaped runtime stages.

## Wispr Flow side-by-side (fair digital loopback)

Wispr's app has no file-upload path. To compare against OLIV on the **same WAV
bytes** without a speaker→mic handicap, play clips into [BlackHole](https://existential.audio/blackhole/)
while Wispr's input is that virtual device, then score with `semantic_score.py`
alongside `ship_hold.json`.

```bash
# from benchmark/
.venv/bin/python wispr_loopback_eval.py setup          # checklist + device detect
.venv/bin/python wispr_loopback_eval.py run \
  --manifest data/manifest_holdout.jsonl \
  --device "BlackHole 2ch" \
  --notes "cleanup=Medium dict=empty lang=Auto"
.venv/bin/python semantic_score.py                     # compare vs ship_hold
```

Do **not** play through laptop speakers into the built-in mic for scored runs.

After a paired full run, build the interactive head-to-head page:

```bash
.venv/bin/python build_h2h.py   # → ../docs/oliv-vs-wispr.html
```
