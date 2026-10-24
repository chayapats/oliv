//! `pipeline.clean_ex`: built-in dictionary -> user dictionary (corrections,
//! Thai numerals) -> vocab -> gate -> LLM -> guardrail -> user-dictionary guard
//! -> Thai spacing -> canonical casing. Same order as oliv-server's pipeline.

use serde::Serialize;

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
}

/// Guardrail flag used when the LLM call itself failed.
pub const LLM_ERROR_FLAG: &str = "llmError->dict";

/// Guardrail flag used when the LLM rewrote a user-dictionary word (e.g.
/// romanized a Thai name the user fixed); `text` is then the deterministic
/// result.
pub const DICTIONARY_FLAG: &str = "dictionary->dict";

/// `vocab` is the full fuzzy/STT vocabulary (dictionary words first, see
/// `Options::effective_vocabulary`); `dict` supplies the literal corrections,
/// Thai-numeral words and the LLM guard.
pub fn clean_ex(
    text: &str,
    vocab: &[String],
    dict: &UserDictionary,
    prompt: Prompt,
    llm: &dyn Llm,
) -> CleanResult {
    let (mut dict_text, mut dict_hits) = apply_dictionary(text);
    for pass in [
        UserDictionary::apply_corrections,
        UserDictionary::apply_numerals,
    ] {
        let (t, n) = pass(dict, &dict_text);
        dict_text = t;
        dict_hits += n;
    }
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
    }
}

/// After cleanup: dictionary corrections merged with the legacy
/// `replacements` table, then Thai-numeral words again (repairs what the LLM
/// split or spelled out), then Thai spacing. Without a dictionary this is the
/// sidecar's `apply_dictionary(text, table)` + spacing.
pub fn apply_replacements(
    text: &str,
    dict: &UserDictionary,
    legacy: &[(String, String)],
) -> (String, usize) {
    let (t, a) = dict.apply_with_legacy(text, legacy);
    let (t, b) = dict.apply_numerals(&t);
    (normalize_thai_spacing(&t), a + b)
}
