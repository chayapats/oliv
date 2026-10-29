//! Speech-to-text backend: `whisper_server.py` on loopback.

use std::time::Duration;

use serde_json::Value;

use crate::http::{healthy, percent_encode};

/// One decode: the text plus the mean per-segment `avg_logprob` (None when
/// Whisper returned no segments).
#[derive(Debug, Clone, PartialEq)]
pub struct Transcript {
    pub text: String,
    pub avg_logprob: Option<f64>,
}

/// Transcribes one clip. `language` None = auto-detect.
pub trait Stt {
    fn transcribe(
        &self,
        wav: &[u8],
        initial_prompt: Option<&str>,
        language: Option<&str>,
    ) -> Result<Transcript, String>;

    fn healthy(&self) -> bool {
        true
    }
}

/// Oliv's `TyphoonTurboMLXBackend.seed_prompt`: typhoon-turbo repetition-loops
/// when its decode is primed with a vocabulary term (Vault, Cassandra), so the
/// vocabulary only feeds the post-STT corrector. Priming was measurably worse
/// on the eval.
pub const SEED_PROMPT: bool = false;

/// `_REDECODE_MIN_LOGPROB` / `_REDECODE_MARGIN` of the sidecar.
const REDECODE_MIN_LOGPROB: f64 = -0.30;
const REDECODE_MARGIN: f64 = 0.02;

/// Most non-ASCII Latin letters a forced-English decode may contain (`café`).
const REDECODE_MAX_EXTENDED: usize = 2;

/// A forced-English decode that came back in another Latin-script language
/// (`Branch này merge xong rồi, but staging test vẫn fail`): any
/// Vietnamese letter (U+1EA0..U+1EF9) or more than `REDECODE_MAX_EXTENDED`
/// letters from the Latin-1 to Extended Additional blocks.
fn not_english(text: &str) -> bool {
    let mut extended = 0;
    for c in text.chars() {
        if ('\u{1ea0}'..='\u{1ef9}').contains(&c) {
            return true;
        }
        if c.is_alphabetic() && matches!(c, '\u{00c0}'..='\u{024f}' | '\u{1e00}'..='\u{1eff}') {
            extended += 1;
        }
    }
    extended > REDECODE_MAX_EXTENDED
}

/// `_transcribe_maybe_redecode`: decode in auto-language mode; when that is
/// unconfident, decode again forced to English and keep whichever is more
/// confident. Returns (text, redecoded). Typhoon is a Thai fine-tune that can
/// decode pure English as garble; on real Thai the forced-en decode scores far
/// lower, so Thai is kept. Unlike the sidecar, a failed second decode keeps the
/// first text instead of failing the request (the text is never lost), and so
/// does a forced-en decode that is [`not_english`].
pub fn transcribe_maybe_redecode(
    stt: &dyn Stt,
    wav: &[u8],
    initial_prompt: Option<&str>,
) -> Result<(String, bool), String> {
    let auto = stt.transcribe(wav, initial_prompt, None)?;
    let Some(lp) = auto.avg_logprob.filter(|lp| *lp < REDECODE_MIN_LOGPROB) else {
        return Ok((auto.text, false));
    };
    match stt.transcribe(wav, initial_prompt, Some("en")) {
        Ok(Transcript {
            text,
            avg_logprob: Some(alp),
        }) if alp > lp + REDECODE_MARGIN && !not_english(&text) => Ok((text, true)),
        _ => Ok((auto.text, false)),
    }
}

/// Oliv's `_MAX_PROMPT_CHARS`.
const MAX_PROMPT_CHARS: usize = 960;

/// `_build_initial_prompt` for a vocabulary list (no explicit prompt, no format
/// commands in v1): the stripped non-empty terms joined by ", ", capped.
pub fn initial_prompt(vocabulary: &[String]) -> Option<String> {
    let terms: Vec<&str> = vocabulary
        .iter()
        .map(|t| crate::pyu::strip(t))
        .filter(|t| !t.is_empty())
        .collect();
    if terms.is_empty() {
        return None;
    }
    Some(terms.join(", ").chars().take(MAX_PROMPT_CHARS).collect())
}

pub struct HttpStt {
    url: String,
    health_url: String,
    agent: ureq::Agent,
}

impl HttpStt {
    /// `base_url` like `http://127.0.0.1:8082`.
    pub fn new(base_url: &str, timeout: Duration) -> Self {
        let base = base_url.trim_end_matches('/');
        let agent = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .max_redirects(0)
            .http_status_as_error(false)
            .build()
            .into();
        HttpStt {
            url: format!("{base}/transcribe"),
            health_url: format!("{base}/health"),
            agent,
        }
    }
}

impl Stt for HttpStt {
    fn transcribe(
        &self,
        wav: &[u8],
        initial_prompt: Option<&str>,
        language: Option<&str>,
    ) -> Result<Transcript, String> {
        let mut req = self
            .agent
            .post(&self.url)
            .header("Content-Type", "audio/wav");
        if let Some(p) = initial_prompt {
            req = req.header("X-Initial-Prompt", percent_encode(p));
        }
        if let Some(l) = language {
            req = req.header("X-Language", l);
        }
        let mut resp = req.send(wav).map_err(|e| format!("stt: {e}"))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(format!("stt: HTTP {status}"));
        }
        let v: Value = resp
            .body_mut()
            .with_config()
            .limit(256 * 1024)
            .read_json()
            .map_err(|e| format!("stt: HTTP {status}: {e}"))?;
        match (v["ok"].as_bool(), v["text"].as_str()) {
            (Some(true), Some(t)) if t.len() <= 16 * 1024 => Ok(Transcript {
                text: t.to_string(),
                avg_logprob: v["avg_logprob"].as_f64(),
            }),
            _ => Err(format!(
                "stt: HTTP {status}: {}",
                v["error"].as_str().unwrap_or("bad reply")
            )),
        }
    }

    fn healthy(&self) -> bool {
        healthy(&self.health_url)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn not_english_catches_vietnamese_not_loanwords() {
        for t in [
            "Branch này merge xong rồi, but staging test vẫn fail.",
            "Sprint này dời sang thứ ba được không?",
            "Cache nì miss hoài là à ì",
        ] {
            assert!(not_english(t), "{t}");
        }
        for t in [
            "please rebase your branch on top of main before merging",
            "update the résumé before Friday",
            "Service này cache miss, need check hàm init.",
            "สวัสดี 5 × 3",
        ] {
            assert!(!not_english(t), "{t}");
        }
    }
}
