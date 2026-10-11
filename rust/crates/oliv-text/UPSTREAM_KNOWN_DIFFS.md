# Deliberate differences from the Python reference

- A failed LLM keeps dictionary/vocabulary corrections, spacing and casing.
  `guardrail_flag` is `llmError->dict`; the error is reported without losing text.
- A failed forced-English second decode preserves the first transcription.
- Request options are validated before processing.
- Rust Unicode tables may recognize characters newer than Python's tables.

Mac formatting commands and audio gates are implemented in `commands.rs`,
`audio.rs` and `local.rs`. Typhoon avoids an STT initial prompt, while other
Whisper engines retain vocabulary/formatting hints. Native model kernels can
produce a different greedy token near a numerical tie; corpus-level accuracy
is measured separately from deterministic text parity.

The upstream word-to-number and romanization edge cases remain covered by the
public reference fixtures. See `UPSTREAM.md` for source revisions and licenses.
