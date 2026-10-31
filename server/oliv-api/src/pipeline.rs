//! `pipeline.clean_ex`: built-in dictionary -> user dictionary (corrections,
//! Thai numerals) -> vocab -> gate -> LLM -> guardrail -> user-dictionary guard
//! -> Thai spacing -> canonical casing.

use serde::Serialize;

use crate::dictate::AsrProfile;
use crate::dictionary::{apply_canonical_casing, apply_dictionary};
use crate::gate::gate;
use crate::guardrail::guardrail;
use crate::llm::{Llm, Prompt, Request};
use crate::phonetic::{correct_with_vocab, vocab_hint};
use crate::spacing::normalize_thai_spacing;
use crate::user_dictionary::UserDictionary;

/// Per-stage trace of one cleanup (Oliv's `CleanResult` minus timings).
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct CleanResult {
    pub text: String,
    pub raw: String,
    pub dict_text: String,
    pub dict_hits: usize,
    pub llm_ran: bool,
    pub gate_reason: String,
    pub vocab_fired: usize,
    pub llm_raw_gen: Option<String>,
    pub guardrail_flag: String,
    pub suspect_tokens: Vec<String>,
    /// Set when the LLM call failed (timeout, HTTP error); `text` is then the
    /// deterministic result, as if the guardrail had fallen back.
    #[serde(skip)]
    pub llm_error: Option<String>,
    /// Outputs the pre-LLM correction pass wrote, which the post pass
    /// ([`apply_replacements`]) must not correct again.
    #[serde(skip)]
    pub corrected: Vec<String>,
}

/// Guardrail flag used when the LLM call itself failed.
pub const LLM_ERROR_FLAG: &str = "llmError->dict";

/// Guardrail flag used when the LLM rewrote a user-dictionary word (e.g.
/// romanized a Thai name the user fixed); `text` is then the deterministic
/// result.
pub const DICTIONARY_FLAG: &str = "dictionary->dict";

/// Gate reason when a non-Turbo profile runs the LLM on `clean-thai` text.
/// Qwen3-ASR and Typhoon-ctx spell loanwords with dictionary-legal Thai
/// syllables (แคปค่า, เรทลิมิต) that the gate signals miss. Not in Oliv.
pub const PROFILE_ALWAYS: &str = "profile-always";

/// `vocab` is the full fuzzy/STT vocabulary (dictionary words first, see
/// `Options::effective_vocabulary`); `dict` supplies the literal corrections,
/// Thai-numeral words and the LLM guard.
/// `profile` is the STT model behind `text`: only Turbo may skip the LLM on
/// `clean-thai` (see [`PROFILE_ALWAYS`]).
/// `force_llm` always runs the LLM: its reason replaces `clean-thai`, which no
/// longer holds, and is appended to any other gate reason.
pub fn clean_ex(
    text: &str,
    vocab: &[String],
    dict: &UserDictionary,
    prompt: Prompt,
    profile: AsrProfile,
    force_llm: Option<&'static str>,
    llm: &dyn Llm,
) -> CleanResult {
    let (mut dict_text, mut dict_hits) = apply_dictionary(text);
    let (t, n, corrected) = dict.apply_corrections_before(&dict_text, &[]);
    dict_text = t;
    dict_hits += n;
    let (t, n) = dict.apply_numerals(&dict_text);
    dict_text = t;
    dict_hits += n;
    let mut vocab_fired = 0;
    let mut hints = Vec::new();
    if !vocab.is_empty() {
        let (t, n, subs) = correct_with_vocab(&dict_text, vocab);
        dict_text = t;
        vocab_fired = n;
        // Only letter-changing snaps prove code-switching for the gate.
        dict_hits += subs
            .iter()
            .filter(|(src, dst)| src.to_lowercase() != dst.to_lowercase())
            .count();
        hints = vocab_hint(&dict_text, vocab);
    }

    let (mut run_llm, mut gate_reason, susp) = gate(&dict_text, dict_hits);
    if let Some(reason) = force_llm {
        run_llm = true;
        gate_reason = match gate_reason.as_str() {
            "" | "clean-thai" => reason.to_string(),
            r => format!("{r}+{reason}"),
        };
    }
    if !run_llm && gate_reason == "clean-thai" && profile != AsrProfile::Turbo {
        run_llm = true;
        gate_reason = PROFILE_ALWAYS.to_string();
    }
    if !hints.is_empty() && !run_llm {
        run_llm = true;
        gate_reason = if gate_reason.is_empty() {
            "vocab-hint".into()
        } else {
            format!("{gate_reason}+vocab-hint")
        };
    }

    let mut llm_raw_gen = None;
    let mut llm_error = None;
    let (final_text, flag) = if !run_llm {
        (dict_text.clone(), "skipped".to_string())
    } else {
        match llm.generate(&Request {
            prompt,
            text: &dict_text,
            hints: &hints,
        }) {
            Ok(g) => {
                let (f, flag) = guardrail(&dict_text, &g);
                llm_raw_gen = Some(g);
                if dict.lost_words(&dict_text, &f).is_empty() {
                    (f, flag.to_string())
                } else {
                    (dict_text.clone(), DICTIONARY_FLAG.to_string())
                }
            }
            Err(e) => {
                llm_error = Some(e.to_string());
                (dict_text.clone(), LLM_ERROR_FLAG.to_string())
            }
        }
    };
    let final_text = apply_canonical_casing(&normalize_thai_spacing(&final_text));

    CleanResult {
        text: final_text,
        raw: text.to_string(),
        dict_text,
        dict_hits,
        llm_ran: run_llm,
        gate_reason,
        vocab_fired,
        llm_raw_gen,
        guardrail_flag: flag,
        suspect_tokens: susp,
        llm_error,
        corrected,
    }
}

/// After cleanup: dictionary corrections merged with the legacy
/// `replacements` table, skipping what the pre-LLM pass wrote (`corrected`,
/// empty when cleanup was off), then Thai-numeral words again (repairs what
/// the LLM split or spelled out), then Thai spacing. Without a dictionary this
/// is the sidecar's `apply_dictionary(text, table)` + spacing.
pub fn apply_replacements(
    text: &str,
    dict: &UserDictionary,
    legacy: &[(String, String)],
    corrected: &[String],
) -> (String, usize) {
    let (t, a) = dict.apply_after_cleanup(text, legacy, corrected);
    let (t, b) = dict.apply_numerals(&t);
    (normalize_thai_spacing(&t), a + b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::LlmError;
    use oliv_text_core::user_dictionary::Entry;

    /// Returns the text unchanged.
    struct Echo;

    impl Llm for Echo {
        fn generate(&self, req: &Request) -> Result<String, LlmError> {
            Ok(req.text.to_string())
        }
    }

    const CLEAN_THAI: &str = "วันนี้อากาศดีมาก";

    #[test]
    fn a_chained_correction_applies_once() {
        let entry = |word: &str, heard: &str| Entry {
            word: word.to_string(),
            correction: Some(heard.to_string()),
            enabled: true,
            starred: false,
        };
        let dict = UserDictionary::new(&[entry("docker", "foo"), entry("X", "docker")]);
        let r = clean_ex(
            "say foo",
            &[],
            &dict,
            Prompt::V5,
            AsrProfile::Turbo,
            None,
            &Echo,
        );
        assert_eq!(r.text, "say Docker");
        let (t, _) = apply_replacements(&r.text, &dict, &[], &r.corrected);
        assert_eq!(t, "say Docker");
        // With cleanup off nothing ran before, so every correction does here.
        assert_eq!(apply_replacements("say docker", &dict, &[], &[]).0, "say X");
    }

    #[test]
    fn force_llm_runs_a_skipped_gate() {
        let r = clean_ex(
            CLEAN_THAI,
            &[],
            &UserDictionary::default(),
            Prompt::V5,
            AsrProfile::Turbo,
            None,
            &Echo,
        );
        assert!(!r.llm_ran);
        assert_eq!(r.gate_reason, "clean-thai");
        let r = clean_ex(
            CLEAN_THAI,
            &[],
            &UserDictionary::default(),
            Prompt::V5,
            AsrProfile::Turbo,
            Some("forced"),
            &Echo,
        );
        assert!(r.llm_ran);
        assert_eq!(r.gate_reason, "forced");
        assert_eq!(r.text, CLEAN_THAI);
        let r = clean_ex(
            "ok",
            &[],
            &UserDictionary::default(),
            Prompt::V5,
            AsrProfile::Turbo,
            Some("forced"),
            &Echo,
        );
        assert!(r.llm_ran);
        assert_eq!(r.gate_reason, "no-thai+forced");
    }

    #[test]
    fn non_turbo_profiles_never_skip_thai() {
        for profile in [AsrProfile::Qwen3Asr, AsrProfile::TyphoonCtx] {
            let r = clean_ex(
                CLEAN_THAI,
                &[],
                &UserDictionary::default(),
                Prompt::V5,
                profile,
                None,
                &Echo,
            );
            assert!(r.llm_ran);
            assert_eq!(r.gate_reason, PROFILE_ALWAYS);
            assert_eq!(r.text, CLEAN_THAI);
            let r = clean_ex(
                CLEAN_THAI,
                &[],
                &UserDictionary::default(),
                Prompt::V5,
                profile,
                Some("forced"),
                &Echo,
            );
            assert_eq!(r.gate_reason, "forced");
            // No Thai still skips, and a running gate keeps its reason.
            let r = clean_ex(
                "ok",
                &[],
                &UserDictionary::default(),
                Prompt::V5,
                profile,
                None,
                &Echo,
            );
            assert!(!r.llm_ran);
            assert_eq!(r.gate_reason, "no-thai");
            let text = "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา";
            let a = clean_ex(
                text,
                &[],
                &UserDictionary::default(),
                Prompt::V5,
                AsrProfile::Turbo,
                None,
                &Echo,
            );
            let b = clean_ex(
                text,
                &[],
                &UserDictionary::default(),
                Prompt::V5,
                profile,
                None,
                &Echo,
            );
            assert_eq!(a, b);
        }
    }

    #[test]
    fn force_llm_appends_to_a_running_gate() {
        let text = "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา";
        let a = clean_ex(
            text,
            &[],
            &UserDictionary::default(),
            Prompt::V5,
            AsrProfile::Turbo,
            None,
            &Echo,
        );
        let b = clean_ex(
            text,
            &[],
            &UserDictionary::default(),
            Prompt::V5,
            AsrProfile::Turbo,
            Some("forced"),
            &Echo,
        );
        assert!(a.llm_ran);
        assert_eq!(b.gate_reason, format!("{}+forced", a.gate_reason));
        assert_eq!(a.text, b.text);
    }
}
