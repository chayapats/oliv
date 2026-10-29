# Source and licenses

Extracted from the OLIV server text pipeline, which now lives in this
repository under `server/` (`server/oliv-api/src` and
`server/oliv-api/tests/golden*`; its corpus data is the set embedded in
`oliv-text-core/data`). The Linux/Windows client is in `desktop/`.

That code was first published under Apache-2.0 by its sole author, who
relicensed it under this repository's MIT license. Its reference behaviour is
the earlier Python implementation of OLIV (MIT). The pythainlp ports in
`oliv-text-core` stay under Apache-2.0 (see that crate's `NOTICE.md`), and the
Thai corpus files retain their separate `data/LICENSE-pythainlp` license.

Extraction removes HTTP server/config/inference adapters from the core,
and keeps the pure LLM/STT contracts. The deterministic text modules
(segmentation, dictionary, numbers, romanization, phonetic matching, metrics)
and the embedded corpus data live in the sibling `oliv-text-core` crate, which
the server in `server/` also depends on; this crate re-exports them.
Mac-specific extensions live in `commands.rs`, `audio.rs`, and `local.rs`.
Corpus-derived upstream goldens are excluded from this public repository.
Public fixtures are frozen from public test literals and synthetic examples
recorded from the pre-0.2.0 implementation, with mocked LLM responses. The independent reference
outputs are retained unchanged; the obsolete generator was retired and is not published. The seeded tokenizer fuzz uses only the public PyThaiNLP corpus.
Private corpus comparison results and recordings remain outside Git.
