# Source and licenses

Extracted from https://github.com/chayapats/oliv-linux at
`0000a4de36413075788945ae7d12fce8caa06466`, `server/oliv-api/src`,
`server/oliv-api/tests/golden*`, and `server/data`.

The upstream Rust crate declares Apache-2.0. Its Python reference is OLIV
`39c10cf744befa88e33b8353b594f4ff0d721d54` (MIT). Thai corpus files
retain their separate `data/LICENSE-pythainlp` license.

Extraction removes HTTP server/config/inference adapters from the core,
and keeps the pure LLM/STT contracts. The deterministic text modules
(segmentation, dictionary, numbers, romanization, phonetic matching, metrics)
and the embedded corpus data live in the sibling `oliv-text-core` crate, which
oliv-server also depends on; this crate re-exports them.
Mac-specific extensions live in `commands.rs`, `audio.rs`, and `local.rs`.
Corpus-derived upstream goldens are excluded from this public repository.
Public fixtures are frozen from public test literals and synthetic examples
recorded from the pre-0.2.0 implementation, with mocked LLM responses. The independent reference
outputs are retained unchanged; the obsolete generator was retired and is not published. The seeded tokenizer fuzz uses only the public PyThaiNLP corpus.
Private corpus comparison results and recordings remain outside Git.
