# OLIV core parity

The client transport reference is the former `oliv-linux` repository at `0000a4de36413075788945ae7d12fce8caa06466` (now [`server/`](../../server/README.md) and [`desktop/`](../../desktop/README.md) in this repository), inspected on 2026-10-03, especially its [public API migration contract](../../desktop/docs/API-MIGRATION.md). The iPhone app sends the original OLIV options and audio format to the public HTTPS service. It does not load speech or language models onto the phone. The repository's unchanged server files remain a reference for the core processing pipeline; upstream identifies its deployment scripts as a snapshot from before the public API migration, not upgrade instructions.

## Source behavior and iPhone mapping

| Source capability | iPhone implementation |
| --- | --- |
| Hold Right Shift → record → release → process | Native microphone capture and App Intent entry points; no custom keyboard required. Starting/stopping is adapted to touch and iPhone system controls. |
| 16 kHz, mono, signed 16-bit PCM WAV | `AudioCaptureService` and `WAVMetadata`; RIFF parsing supports additional recorder chunks rather than assuming a 44-byte header. |
| 120-second recording cap | Recorder cap and core request validation. |
| Accidental Linux key presses under 300 ms ignored; fewer than 100 ms of captured samples rejected | iPhone rejects recordings shorter than 250 ms. This is a deliberate touch-interaction adaptation, not exact key-hold parity. Source thresholds also remain represented in `RecordingLimits`. |
| Thai + English in one utterance | The existing server performs automatic language decoding. Low-confidence auto results can be re-decoded in English and replaced only when confidence improves. |
| Dictionary, vocabulary, phonetic correction | Identical server pipeline. The personal Dictionary is stored on the server per profile and applied to every request (`server/docs/DICTIONARY.md`); servers without it receive derived vocabulary per request. |
| Selective language-model cleanup | `cleanup` option maps directly to the server. No additional client-side rewriting is applied. |
| Remove fillers | `remove_fillers` defaults to true and is configurable. |
| Thai formatting | `thai_format` defaults to true and is configurable. |
| Spoken → written corrections | Dictionary entries with a correction. For servers without dictionary sync they are transmitted as an insertion-ordered `replacements` object. String escaping is delegated to `JSONEncoder`. |
| Clean existing text | `POST /v1/clean`, using the same options and server pipeline as dictation. |
| No-speech / hallucination result | Successful empty results and `no_speech` never become text to copy or return from an intent. |
| Cleanup failure preserves text | `cleanup_error` is a successful degraded result. Deterministic text remains available rather than triggering an audio retry. |
| Failed transcription retains WAV | Audio is saved locally **before** upload with an options snapshot; failure/cancellation keeps it for retry. |
| Retry oldest pending recordings | Pending items sort oldest-first and keep their original options; no automatic retry loop. |
| API throttling and temporary server cooldown | `Retry-After` seconds and HTTP-date are persisted for `429` and `5xx` with that header. A missing/invalid `429` delay defaults to 60 seconds, with a minimum one-second wait. New audio stays pending while requests are blocked. No timer or automatic inference retry runs; changing the key/address does not clear the cooldown. |
| Last result, history, timing and pipeline diagnostics | `HistoryEntry` retains raw/final text, STT/cleanup/total timings, no-speech, re-decode, gate/guardrail and stage counts. History retains the newest 1,000 entries. |
| Cancel recording | Releases the microphone and discards the current recording. Cancelling an in-flight upload keeps its already-saved retry audio. |
| Linux automatic focused-app paste | Optional OLIV keyboard inserts a requested result through its own active `textDocumentProxy`, only when the original field and cursor context remain unchanged. Apple keyboard users retain explicit copy/share and Shortcut output. iOS offers no unrestricted global text injection. |

## Exact server contract

The base URL is the configured OLIV server (none in source builds); an HTTPS server needs no private VPN. `POST /v1/dictate` receives `wav_b64`, `cleanup`, `remove_fillers`, `thai_format`, `vocabulary`, and `replacements`. It requires an individual API key with scope `dictate`; that scope includes cleanup within dictation. `POST /v1/clean` uses `text` in place of `wav_b64` and separately requires scope `clean`. Both authenticate with `Authorization: Bearer …`. The old shared token and private endpoint are retired. The client omits `prompt` so the deployed server chooses its configured prompt version.

`GET /health` is public and may return only `{"ok":true}`. It establishes API liveness, not key validity, scope, Whisper/Gemma readiness or pipeline health. **Test connection** sends this unauthenticated request only; it does not call cleanup as a key preflight. Recording and inference do not require a preceding health check. The iPhone client does not call `/v1/status` or admin/model routes, which are not public through this hostname.

Success replies preserve `ok`, `raw`, `final`, `no_speech`, `stt_redecoded`, `t_stt`, `t_cleanup`, `llm_ran`, `gate_reason`, `guardrail_flag`, `cleanup_error`, `dict_hits`, `vocab_fired`, `fillers_removed`, `replacements_fired`, and `thai_format_fired` when provided. `raw` may be omitted. `final` must be a string unless it is absent with explicit `no_speech:true`; present null or wrong-type text fields are rejected. A bare `{"ok":true}` is liveness, not a valid dictation result.

The client sends `User-Agent: oliv-ios/0.1.0` and uses a 120-second request/resource timeout, an 8 MiB request limit, and a 1 MiB streamed response limit. Redirects are refused so audio, text, and credentials do not follow an unexpected destination. TLS uses the platform's normal certificate and hostname validation. Custom local/private-network HTTP still requires explicit opt-in; this development option does not mean the retired private endpoint remains usable. A custom reverse-proxy base path is preserved before appending the API routes.

## Server processing retained unchanged

The authoritative order in `server/oliv-api/src/dictate.rs` and `pipeline.rs` is:

1. Automatic-language speech recognition; if mean confidence is below −0.30, try English decoding and accept it only when confidence improves by more than 0.02. A failed second decode keeps the first result.
2. Strip CJK output and reject known hallucinations or repetition loops.
3. Remove fillers, when enabled.
4. Apply dictionary and vocabulary/phonetic corrections.
5. Gate language-model cleanup and provide relevant vocabulary hints.
6. Apply the model only when needed; guard against missing content, added content, lost protected terms, translation, or excessive edits. Fall back to deterministic text on rejection or model failure.
7. Normalize Thai spacing and canonical casing.
8. Apply Dictionary corrections merged with request replacements.
9. Apply Thai number conversion and reduplication formatting, when enabled.

Vocabulary is deliberately **not** passed into Whisper's initial prompt in the source deployment: source evaluation found that doing so caused repetition loops. The iPhone client retains that behavior. Linux v1 explicitly excludes spoken formatting commands, and it does not provide a creative rewrite, translation, or tone-selection product feature.

## Persistence and verification

Tokens belong in iOS Keychain and are excluded from the Codable configuration/options models. History and pending WAVs are private files excluded from device backup; writes are atomic and pending audio is synchronized before upload. Successful recordings are removed only after the chosen result-persistence step succeeds. With history disabled, a successful result remains in memory and successful audio is deleted. Existing corrupted stores are preserved rather than silently overwritten.

The pure Swift package tests cover wire contracts, Thai/English strings, replacement ordering and escaping, response/error handling, actual task cancellation, bounds, WAV variants/truncation, persistence/restart, retry snapshots, retention, file permissions, and expiring at-most-once keyboard delivery. Malformed success replies are errors so retry audio is retained. App-model tests exercise the orchestration with injected microphone/network fixtures, with separate real microphone, isolated Keychain, and opt-in live API checks. These tests establish protocol and lifecycle behavior; they do not establish real-server recognition accuracy, radio-network latency, microphone-route behavior, or physical-device system-control eligibility. Current run counts and authenticated-live evidence belong in [Testing](TESTING.md); a public health response alone proves none of those authenticated behaviors.

Source entry points: [`client/src/api.rs`](../../desktop/src/api.rs), [`capture.rs`](../../desktop/src/capture.rs), [`daemon.rs`](../../desktop/src/daemon.rs), [`server/oliv-api/src/api.rs`](../../server/oliv-api/src/api.rs), [`dictate.rs`](../../server/oliv-api/src/dictate.rs), [`stt.rs`](../../server/oliv-api/src/stt.rs), [`pipeline.rs`](../../server/oliv-api/src/pipeline.rs), and [`guardrail.rs`](../../server/oliv-api/src/guardrail.rs).
