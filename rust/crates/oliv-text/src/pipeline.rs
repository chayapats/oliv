//! `pipeline.clean_ex`: built-in dictionary -> user dictionary (corrections,
//! Thai numerals) -> vocab -> gate -> LLM -> guardrail -> user-dictionary
//! guard -> listed-term protection -> Thai spacing -> canonical casing.

use serde::Serialize;

use crate::dictionary::{apply_canonical_casing, apply_dictionary};
use crate::gate::gate;
use crate::guardrail::{RESTRICTED_FLAG, guardrail, protect_listed_terms};
use crate::llm::{Llm, Prompt, Request};
use crate::phonetic::{
    correct_with_latin_names, correct_with_thai_vocab, correct_with_vocab, vocab_hint,
};
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
    clean_ex_with(text, vocab, dict, &[], prompt, llm)
}

/// [`clean_ex`] for a request that also carries a legacy `replacements`
/// table (applied after cleanup by [`apply_replacements`]): the pre-LLM
/// corrections leave a longer legacy source for it.
pub fn clean_ex_with(
    text: &str,
    vocab: &[String],
    dict: &UserDictionary,
    legacy: &[(String, String)],
    prompt: Prompt,
    llm: &dyn Llm,
) -> CleanResult {
    let (mut dict_text, mut dict_hits) = apply_dictionary(text);
    let (t, n, corrected) = dict.apply_corrections_before(&dict_text, legacy);
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
        // Thai-script terms re-spell Thai spans, and listed Latin names replace
        // their Thai spelling. Neither proves garbled code-switching, so they add
        // no gate hit and never wake the LLM by themselves.
        for correct in [correct_with_thai_vocab, correct_with_latin_names] {
            let (t, n, _) = correct(&dict_text, vocab);
            dict_text = t;
            vocab_fired += n;
        }
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
                if !dict.lost_words(&dict_text, &f).is_empty() {
                    (dict_text.clone(), DICTIONARY_FLAG.to_string())
                } else if flag == "ok" {
                    match protect_listed_terms(&dict_text, &f, vocab) {
                        (f, 0) => (f, flag.to_string()),
                        (f, _) => (f, RESTRICTED_FLAG.to_string()),
                    }
                } else {
                    (f, flag.to_string())
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

/// The post pass, once per segment. Every correction applies exactly once:
///
/// - `cleaned` = the outputs `clean_ex` already wrote (its pre-LLM pass ran):
///   corrections + the legacy `replacements` table, but never inside those
///   outputs (no chained `foo→bar→baz`, no `ไทย→ประเทศไทย` twice; a phrase
///   the LLM newly produced is still corrected), then Thai-numeral words
///   again (repairs what the LLM split or spelled out).
/// - not cleaned (cleanup off / verbatim app): dictionary corrections merged
///   with the legacy table, like the legacy replacements always were; no
///   numeral rewrite, which is cleanup.
///
/// Then Thai spacing. Without a dictionary this is the sidecar's
/// `apply_dictionary(text, table)` + spacing.
pub fn apply_replacements(
    text: &str,
    dict: &UserDictionary,
    legacy: &[(String, String)],
    cleaned: Option<&[String]>,
) -> (String, usize) {
    if let Some(corrected) = cleaned {
        let (t, a) = dict.apply_after_cleanup(text, legacy, corrected);
        let (t, b) = dict.apply_numerals(&t);
        (normalize_thai_spacing(&t), a + b)
    } else {
        let (t, a) = dict.apply_with_legacy(text, legacy);
        (normalize_thai_spacing(&t), a)
    }
}

/// Whether [`apply_replacements`] has anything to do. A vocabulary-only
/// dictionary never does with cleanup off, so verbatim text stays verbatim.
pub fn has_replacements(dict: &UserDictionary, legacy: &[(String, String)], cleaned: bool) -> bool {
    !legacy.is_empty() || dict.has_corrections() || (cleaned && dict.has_numerals())
}
