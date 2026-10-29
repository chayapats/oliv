//! Small HTTP helpers shared by the backends.

use std::time::Duration;

/// `GET url` answers 2xx within a second.
pub fn healthy(url: &str) -> bool {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(1)))
        .build()
        .into();
    agent.get(url).call().is_ok()
}

/// Percent-encode everything outside RFC 3986 unreserved characters, so any text
/// (Thai included) fits in an ASCII header; Python's `urllib.parse.unquote` undoes it.
pub fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}
