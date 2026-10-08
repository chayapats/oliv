# Source and licenses

API request/TLS/error/WAV behavior is extracted from OLIV Linux
`0000a4de36413075788945ae7d12fce8caa06466`, `client/src/api.rs`,
`client/src/api/tls_tests.rs`, `client/src/config.rs`, and `client/src/wav.rs`
(Apache-2.0). Linux disk history/pending recovery and process locks are omitted.
Mac keeps credentials in Keychain and sends them only through private stdin.
The caller owns cooldown/cancellation; inference requests are never retried.
