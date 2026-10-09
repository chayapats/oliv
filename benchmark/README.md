# Native OLIV benchmarks

`oliv-dev` is a Rust CLI using the shipped Rust + native MLX pipeline. Swift/MLX
and the Rust Hugging Face tokenizer score LaBSE embeddings. No interpreter,
virtual environment, Torch or pip packages are required.

```sh
bash scripts/build_dev.sh
HF_HUB_OFFLINE=1 build/native-tools/oliv-dev eval \
  --manifest data/manifest_all.jsonl --engine typhoon-turbo-mlx \
  --out benchmark/eval_results/ship_main.json
build/native-tools/oliv-dev score --input benchmark/eval_results/ship_main.json \
  --out benchmark/eval_results/rescored.json
build/native-tools/oliv-dev semantic --model-dir /path/to/LaBSE/snapshot
build/native-tools/oliv-dev report --input benchmark/eval_results/ship_main.json \
  --out benchmark/eval_results/ship_main.html
```

Run from the repository root. Use `--help` for each command. `ffmpeg` is needed
for file normalization. Explicitly download the dictation models with the app
before offline runs. `--runtime-dir` can point to the installed app's
`Contents/Resources/oliv-runtime/bin` directory. `HF_HOME` overrides the normal
app model cache. LaBSE requires a local snapshot containing `config.json`,
`tokenizer.json` and `model.safetensors`; the CLI never downloads it implicitly.

Evaluation retains `fl` filler removal, `fm` formatting commands and `vb`
vocabulary flags. `--no-cleanup` is pure STT, with those features disabled.
`--no-vocab`, `--buckets` and per-bucket `--limit` support ablations. Selected
missing audio, duplicate IDs and empty selections fail instead of silently
changing the scored population. Console output contains counts and aggregate
metrics; transcripts are written only to requested local JSON/HTML files.

WER uses the same Rust newmm tokenizer and NFC normalization as production;
CER strips spaces after normalization. Semantic scoring word-segments both
sides, truncates to 256 tokens, computes L2-normalized LaBSE pooler output and
compares cosine against 0.80. The native metric version is recorded separately
from historical Torch results; rebaseline the complete matrix before publishing
a comparison. `_semantic.json` records aggregate and per-clip scores.

`latency_s` includes file conversion; `t_stt` and `t_cleanup` isolate runtime stages.
`run_eval_full.sh` covers the three currently shipped local STT engines with pure
and E2B cleanup configurations. Groq requires an explicit environment key and is
excluded from the default offline sweep.

Voice recordings, manifests and per-clip reports remain private and untracked.
Record your own corpus following `data/manifest.example.jsonl`. Reports never
copy audio into `docs/` or publish pages. Existing landing and comparison pages
are historical artifacts; this CLI creates fresh local reports rather than
silently replacing their published numbers.

The previous app prototype, reference pipeline, Wispr automation, experimental
model runners and personal finetuning tools are retired from the current checkout.
Their source is preserved at Git commit `55f8da0`. Native training and automatic
third-party app control are not provided by this evaluation CLI. Frozen public
goldens continue to verify the text port independently of its implementation.
