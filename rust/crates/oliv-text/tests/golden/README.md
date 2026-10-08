# Public text fixtures

Regenerate the deterministic fixtures with:

```sh
sidecar/.venv/bin/python benchmark/generate_text_goldens.py
```

Inputs come exclusively from public Python test literals in this repository and
invented examples. LLM responses are deterministic mocks. The generator never
reads private manifests, audio, evaluation outputs or recorded generations.

`tokenize_fuzz.jsonl.gz` is the upstream seeded fuzz set from the public
PyThaiNLP corpus (see `data/LICENSE-pythainlp`). `macos_commands.jsonl` contains
486 invented formatting-command cases from the Mac reference.

Corpus-derived OLIV Linux goldens and recorded generations are intentionally
excluded. `OLIV_GOLDEN_DIR` can point local tests at an untracked private set.
Missing fixture files fail tests. Gzip files retain the same JSONL schema.
