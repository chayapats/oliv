//! Pure STT backend contract and confidence-based English re-decode.

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
/// vocabulary only feeds the post-STT corrector. Measured again in M5: priming
/// took the vb bucket from 23/24 down to 18/24.
pub const SEED_PROMPT: bool = false;

/// `_REDECODE_MIN_LOGPROB` / `_REDECODE_MARGIN` of the sidecar.
const REDECODE_MIN_LOGPROB: f64 = -0.30;
const REDECODE_MARGIN: f64 = 0.02;

/// `_transcribe_maybe_redecode`: decode in auto-language mode; when that is
/// unconfident, decode again forced to English and keep whichever is more
/// confident. Returns (text, redecoded). Typhoon is a Thai fine-tune that can
/// decode pure English as garble; on real Thai the forced-en decode scores far
/// lower, so Thai is kept. Unlike the sidecar, a failed second decode keeps the
/// first text instead of failing the request (the text is never lost).
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
        }) if alp > lp + REDECODE_MARGIN => Ok((text, true)),
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
