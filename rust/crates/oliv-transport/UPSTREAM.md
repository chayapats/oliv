# Source and licenses

API request/TLS/error/WAV behavior is extracted from the OLIV Linux/Windows
client, which now lives in this repository under `desktop/`
(`desktop/src/api.rs`, `desktop/src/api/tls_tests.rs`, `desktop/src/config.rs`
and `desktop/src/wav.rs`). That code was first published under Apache-2.0 by its sole
author, who relicensed it under this repository's MIT license. Linux disk history/pending recovery and process locks are omitted.
Mac keeps credentials in Keychain and sends them only through private stdin.
The caller owns cooldown/cancellation; inference requests are never retried.
