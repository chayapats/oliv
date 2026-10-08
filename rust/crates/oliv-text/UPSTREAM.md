# Source and licenses

Extracted from https://github.com/chayapats/oliv-linux at
`0000a4de36413075788945ae7d12fce8caa06466`, `server/oliv-api/src`,
`server/oliv-api/tests/golden*`, and `server/data`.

The upstream Rust crate declares Apache-2.0. Its Python reference is OLIV
`39c10cf744befa88e33b8353b594f4ff0d721d54` (MIT). Thai corpus files
retain their separate `data/LICENSE-pythainlp` license.

Extraction removes HTTP server/config/inference adapters from the core,
embeds corpus data within this crate, and keeps the pure LLM/STT contracts.
Mac-specific extensions live in `commands.rs`, `audio.rs`, and `local.rs`.
Corpus-derived upstream goldens are excluded from this public repository.
Public fixtures are regenerated from existing public Python test literals and
synthetic examples by `benchmark/generate_text_goldens.py`, with mocked LLM
responses. The seeded tokenizer fuzz uses only the public PyThaiNLP corpus.
Private corpus comparison results and recordings remain outside Git.
