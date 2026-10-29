# Thai ContextASR Bench scorer provenance

The scorer is derived from `scorer/norm.py`, `tok.py`, `metrics.py` and
`score.py` in [wayu-ai/thai-contextasr-bench](https://huggingface.co/datasets/wayu-ai/thai-contextasr-bench/tree/84e309935208cca72ce4a19b073dc450515febad/scorer),
revision `84e309935208cca72ce4a19b073dc450515febad`. The upstream dataset card
licenses these code files under Apache-2.0; a copy is included in
[LICENSE-APACHE](../../LICENSE-APACHE).

OLIV ports the Python scorer to Rust, including normalization, tokenization,
alignment, entity attribution and seeded bootstrap sampling. The adapter adds
production sidecar execution, transcript caching, stage attribution, WER,
paired comparisons and local JSON/CSV/Markdown reports. See
[benchmark/contextasr.md](../../../../../benchmark/contextasr.md) for scoring
parity and evaluation conditions.

Dataset audio, annotations and bias lists are separately licensed CC-BY-NC-4.0.
They are downloaded outside this checkout and are not included in OLIV source
or application bundles. The application's MIT licence does not relicense the
scorer or dataset.
