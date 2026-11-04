# Apple's on-device text model as an OLIV cleanup backend

Developer benchmark only, macOS 26+. This does not change the app's backend.
It constructs `SystemLanguageModel.default`, never a Private Cloud Compute
model. Each generation gets a fresh session and greedy sampling.
Build with the macOS 27 SDK (Xcode 27) for the model-variant diagnostics;
the executable's deployment target is macOS 26.

```sh
swift build -c release --package-path tools/apple-cleanup
tools/apple-cleanup/.build/release/oliv-apple-cleanup status
```

With no arguments it accepts the inference helper's JSONL requests on stdin:
`ping`, `generate` and `llm_warm`; generations use `content` and `max_tokens`.
Replies preserve `id`. Errors are explicit and remain subject to the Rust
pipeline's existing fallback and preservation checks.

To evaluate cleanup alone, create a separate runtime directory with the
production `oliv-sidecar` and this executable named `oliv-inference`, then use
`oliv-dev eval --replay RESULTS --runtime-dir DIRECTORY`. This preserves the
production dictionary, gate, prompt selection and guards. It loads no Gemma.
Label results with the actual backend; older `oliv-dev` versions otherwise
write their default Gemma name in the metadata.

Optional environment variables:

- `OLIV_APPLE_CLEANUP_INSTRUCTIONS`: UTF-8 file containing session instructions.
  Without it the original OLIV prompt is passed unchanged as the user turn.
- `OLIV_APPLE_CLEANUP_TRACE`: local JSONL trace of requests and responses.
  **This contains transcripts. Keep it under ignored `benchmark/eval_results/`.**
- `OLIV_APPLE_TRANSFORM_GUARDRAILS=1`: Apple's documented
  `permissiveContentTransformations` mode for transforming user-supplied text.
  Keep separate results from the default guardrail configuration. The Rust
  preservation checks and fallback remain in place.

The Foundation Models API does not expose the Gemma stop reason, so replies
report `stop_reason: unknown`. This helper is for cleanup evaluation, not the
app's voice editing path, which requires a known normal stop.

Availability and language support are separate. Always record `status`: an
available model is not a promise that Thai is supported. On the benchmark Mac
the model was available but `supportsLocale(th_TH)` was false.
