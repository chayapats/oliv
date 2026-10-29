# Public golden fixtures

Independent reference outputs for `oliv_pipeline`, frozen from the pre-0.2.0
OLIV implementation (Python pipeline, pythainlp 5.3.4) before it was retired. Tests read the gzipped JSONL directly with Rust; an interpreter is
not needed. Do not regenerate expected values from the implementation under
test, and do not edit them by hand.

Inputs come exclusively from public test literals and invented examples. LLM
replies are deterministic synthetic mocks in `../reference/gens.jsonl`. No case
is derived from private eval clips, transcripts, manifests or recorded model
generations; the original corpus-derived server goldens and the generator that
built them were retired and are not published.

- `src: "public-test-literal/synthetic"` and `"synthetic-mock"`: the same cases
  as the public fixtures in `rust/crates/oliv-text/tests/golden/` and
  `rust/crates/oliv-text-core/tests/golden/` (Mac local engine).
- `src: "oliv_test:<file>"`: calls recorded while running OLIV's own Python
  tests from the retired Python implementation (`sidecar/test_text_passes.py`, `benchmark/test_pipeline_*.py`,
  `benchmark/test_dictionary.py`): their literals, strings the tests build
  from literals, and the internal calls those make (e.g. romanised forms in
  `fold`/`royin`).
- `tokenize_fuzz.jsonl.gz`: the seeded fuzz set over the public PyThaiNLP
  corpus, byte-identical to the one in `oliv-text-core`.

Each line is one case:

```json
{"args": [...], "kwargs": {...}, "out": ..., "src": "..."}
```

- `out` is the return value (tuples as lists, sets as sorted lists,
  dataclasses as objects); a raised exception is `"raises": "<name>"` instead.
- `clean_ex.jsonl.gz` has a `prompt`; `dictate.jsonl.gz` is the whole
  `/v1/clean` path, with the request options in `kwargs`.
- `prompt.jsonl.gz`: `args = [prompt, text, hints]`, `out` is the JSON body
  sent to `/v1/chat/completions`.

Where the server intentionally differs from the reference, the case is listed
in `../known_diffs/<file>` with the reference value and the server's, and the
reason is in `../../KNOWN_DIFFS.md`. `OLIV_GOLDEN_DIR` can point local tests at
an untracked fixture set with the same schema (plain or gzipped); files missing
there are skipped.

| File | Cases | Source |
|---|---:|---|
| `casing.jsonl.gz` | 869 | public 869 |
| `clean_ex.jsonl.gz` | 4896 | synthetic-mock 4896 |
| `dictate.jsonl.gz` | 7344 | synthetic-mock 7344 |
| `dictionary.jsonl.gz` | 1694 | public 1687, oliv_test 7 |
| `fillers.jsonl.gz` | 816 | public 816 |
| `fold.jsonl.gz` | 1814 | public 1779, oliv_test 35 |
| `gate.jsonl.gz` | 821 | public 819, oliv_test 2 |
| `guardrail.jsonl.gz` | 4928 | public 4908, oliv_test 20 |
| `hallucination_phrase.jsonl.gz` | 817 | public 816, oliv_test 1 |
| `hint_line.jsonl.gz` | 3 | public 2, oliv_test 1 |
| `latin_crumbs.jsonl.gz` | 845 | public 843, oliv_test 2 |
| `latin_gain.jsonl.gz` | 5100 | public 5083, oliv_test 17 |
| `loan_compound_runs.jsonl.gz` | 845 | public 843, oliv_test 2 |
| `lost_spans.jsonl.gz` | 7440 | public 7425, oliv_test 15 |
| `metrics_tokenize.jsonl.gz` | 3009 | public 3007, oliv_test 2 |
| `normalize.jsonl.gz` | 3192 | public 3190, oliv_test 2 |
| `prompt.jsonl.gz` | 180 | synthetic-mock 180 |
| `repetition_loop.jsonl.gz` | 817 | public 816, oliv_test 1 |
| `royin.jsonl.gz` | 1448 | public 1411, oliv_test 37 |
| `spacing.jsonl.gz` | 872 | public 870, oliv_test 2 |
| `strip_cjk.jsonl.gz` | 817 | public 815, oliv_test 2 |
| `strip_out.jsonl.gz` | 3169 | public 3153, oliv_test 16 |
| `suspicious_tokens.jsonl.gz` | 845 | public 843, oliv_test 2 |
| `text_hallucination.jsonl.gz` | 817 | public 816, oliv_test 1 |
| `thai_divergence.jsonl.gz` | 5033 | public 5024, oliv_test 9 |
| `thai_fold.jsonl.gz` | 1448 | public 1411, oliv_test 37 |
| `thai_format.jsonl.gz` | 872 | public 870, oliv_test 2 |
| `tokenize.jsonl.gz` | 7080 | public 7075, oliv_test 5 |
| `tokenize_fuzz.jsonl.gz` | 31998 | fuzz 31998 |
| `translation_gloss.jsonl.gz` | 5030 | public 5024, oliv_test 6 |
| `vocab_correct.jsonl.gz` | 1665 | public 1665 |
| `vocab_hint.jsonl.gz` | 1666 | public 1666 |
| `words_to_num.jsonl.gz` | 942 | public 940, oliv_test 2 |
