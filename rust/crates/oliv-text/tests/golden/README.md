# Public text fixtures

These independent reference outputs were frozen at OLIV `55f8da0` before retiring
the previous implementation. Tests read JSONL/gzip directly with Rust; an interpreter
is not needed. Do not regenerate expected values from the implementation under test.

Inputs came exclusively from public test literals and invented examples. LLM replies
are deterministic mocks. The historical generator is retained in Git history and
never read private manifests, audio, evaluation outputs or recorded generations.

`tokenize_fuzz.jsonl.gz` is the upstream seeded fuzz set from the public
PyThaiNLP corpus (see `data/LICENSE-pythainlp`). `macos_commands.jsonl` contains
486 invented formatting-command cases from the Mac reference.

Corpus-derived OLIV Linux goldens and recorded generations are intentionally
excluded. `OLIV_GOLDEN_DIR` can point local tests at an untracked private set.
Missing fixture files fail tests. Gzip files retain the same JSONL schema.
