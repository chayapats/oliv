# Deliberate differences from the Python reference

- A failed LLM keeps dictionary/vocabulary corrections, spacing and casing.
  `guardrail_flag` is `llmError->dict`; the error is reported without losing text.
- A failed forced-English second decode preserves the first transcription.
- Request options are validated before processing.
- Rust Unicode tables may recognize characters newer than Python's tables.
- Vocabulary (measured on Thai ContextASR Bench, see `benchmark/contextasr.md`):
  Thai-script terms re-spell near-identical Thai spans; listed Latin names
  replace Thai spans with an identical royin skeleton; the Latin path skips
  terms with Thai or non-ASCII letters and 3-letter skeletons, and acronyms
  never replace real Thai words unless those spell the letters. The frozen
  vocabulary goldens (one 5-term Latin list) are unaffected.
- An LLM edit that touches a listed Thai-script vocabulary term is reverted
  (`guardrail_flag` `ok-termKept`).

Mac formatting commands and audio gates are implemented in `commands.rs`,
`audio.rs` and `local.rs`. Typhoon avoids an STT initial prompt, while other
Whisper engines retain vocabulary/formatting hints. Native model kernels can
produce a different greedy token near a numerical tie; corpus-level accuracy
is measured separately from deterministic text parity.

The upstream word-to-number and romanization edge cases remain covered by the
public reference fixtures. See `UPSTREAM.md` for source revisions and licenses.
