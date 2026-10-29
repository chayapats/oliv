//! `benchmark/metrics.py`: `normalize` and `tokenize` (used by the guardrail clamp).

use unicode_general_category::{GeneralCategory as G, get_general_category};
use unicode_normalization::UnicodeNormalization;

use crate::pyu::{collapse_ws, is_blank, lower, strip};
use crate::tokenize::word_tokenize;

fn is_punct_or_symbol(c: char) -> bool {
    matches!(
        get_general_category(c),
        G::ConnectorPunctuation
            | G::DashPunctuation
            | G::OpenPunctuation
            | G::ClosePunctuation
            | G::InitialPunctuation
            | G::FinalPunctuation
            | G::OtherPunctuation
            | G::MathSymbol
            | G::CurrencySymbol
            | G::ModifierSymbol
            | G::OtherSymbol
    )
}

/// NFC + lowercase + punctuation/symbols -> space + collapse whitespace + strip.
pub fn normalize(text: &str) -> String {
    let t = lower(&text.nfc().collect::<String>());
    let t: String = t
        .chars()
        .map(|c| if is_punct_or_symbol(c) { ' ' } else { c })
        .collect();
    strip(&collapse_ws(&t)).to_string()
}

/// `tokenize(text, "newmm")`: newmm without whitespace tokens.
pub fn tokenize(text: &str) -> Vec<String> {
    word_tokenize(text, false)
        .into_iter()
        .filter(|t| !is_blank(t))
        .collect()
}
