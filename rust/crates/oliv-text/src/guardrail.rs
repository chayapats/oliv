//! `pipeline._guardrail` and its checks: sanitize the LLM generation, falling back
//! to the post-dictionary text on anything suspicious.

use std::collections::HashSet;
use std::sync::LazyLock;

use crate::data::is_thai_word;
use crate::dictionary::CANONICAL_CASE;
use crate::gate::latin_spans;
use crate::metrics;
use crate::pyu::{has_thai, lower, remove_ws, strip};
use crate::tokenize::word_tokenize;

/// `STOPS`: generation is cut at the first of each, in order.
pub const STOPS: [&str; 7] = [
    "<end_of_turn>",
    "<eos>",
    "<end_of_text>",
    "<|channel",
    "\nIN:",
    "\nOUT:",
    "\n\n",
];

pub fn strip_out(generation: &str) -> String {
    let mut t = generation;
    for s in STOPS {
        if let Some(i) = t.find(s) {
            t = &t[..i];
        }
    }
    strip(t).to_string()
}

static PROTECTED_LATIN: LazyLock<HashSet<String>> = LazyLock::new(|| {
    CANONICAL_CASE
        .iter()
        .flat_map(|(k, v)| [k.to_string(), lower(v)])
        .collect()
});

fn within_one_edit(a: &[char], b: &[char]) -> bool {
    let (mut a, mut b) = (a, b);
    if a.len().abs_diff(b.len()) > 1 {
        return false;
    }
    if a.len() == b.len() {
        return a.iter().zip(b).filter(|(x, y)| x != y).count() <= 1;
    }
    if a.len() > b.len() {
        std::mem::swap(&mut a, &mut b);
    }
    let (mut i, mut j, mut edited) = (0, 0, false);
    while i < a.len() && j < b.len() {
        if a[i] == b[j] {
            i += 1;
            j += 1;
        } else {
            if edited {
                return false;
            }
            edited = true;
            j += 1;
        }
    }
    true
}

fn edit_distance(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    if n.abs_diff(m) > 3 {
        return 99;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    for (i, ca) in a.iter().enumerate() {
        let mut cur = vec![0; m + 1];
        cur[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            cur[j + 1] = (prev[j + 1] + 1)
                .min(cur[j] + 1)
                .min(prev[j] + usize::from(ca != cb));
        }
        prev = cur;
    }
    prev[m]
}

fn chars(s: &str) -> Vec<char> {
    s.chars().collect()
}

fn is_asr_english_repair(lost: &str, cand_spans: &[&str]) -> bool {
    let sl = lower(lost);
    let slc = chars(&sl);
    if slc.len() < 4 || PROTECTED_LATIN.contains(&sl) {
        return false;
    }
    cand_spans.iter().any(|t| {
        let tl = chars(&lower(t));
        !tl.is_empty()
            && slc[0] == tl[0]
            && (within_one_edit(&slc, &tl) || edit_distance(&slc, &tl) <= 3)
    })
}

/// Latin spans in `dict_text` that fail to survive into the candidate.
pub fn lost_spans(dict_text: &str, cand: &str, allow_asr_repair: bool) -> Vec<String> {
    let cand_low = lower(cand);
    let cand_nows = remove_ws(&cand_low);
    let cand_spans = latin_spans(&cand_low);
    let cand_span_chars: Vec<Vec<char>> = cand_spans.iter().map(|t| chars(t)).collect();
    let mut lost = Vec::new();
    for s in latin_spans(dict_text) {
        let sl = lower(s);
        if cand_nows.contains(&sl) {
            continue;
        }
        let slc = chars(&sl);
        if slc.len() >= 4 && cand_span_chars.iter().any(|t| within_one_edit(&slc, t)) {
            continue;
        }
        if allow_asr_repair && is_asr_english_repair(&sl, &cand_spans) {
            continue;
        }
        lost.push(s.to_string());
    }
    lost
}

const R2_MIN_WORD_LEN: usize = 5;
const R2_LOST_THRESH: usize = 3;
const R2_INVENT_THRESH: usize = 6;

fn real_thai_words(text: &str) -> Vec<String> {
    word_tokenize(text, false)
        .into_iter()
        .filter(|t| has_thai(t) && is_thai_word(t))
        .collect()
}

/// `(lost_long_content, invented_content)` between dict_text and candidate.
pub fn thai_divergence(dict_text: &str, cand: &str) -> (usize, usize) {
    let cand_nows = remove_ws(cand);
    let lost = real_thai_words(dict_text)
        .iter()
        .filter(|t| t.chars().count() >= R2_MIN_WORD_LEN && !cand_nows.contains(t.as_str()))
        .count();
    let dict_nows = remove_ws(dict_text);
    let invented = real_thai_words(cand)
        .iter()
        .filter(|t| !dict_nows.contains(t.as_str()))
        .count();
    (lost, invented)
}

fn latin_letter_count(text: &str) -> usize {
    text.chars().filter(|c| c.is_ascii_alphabetic()).count()
}

/// True when the candidate adds Latin jargon vs dict_text (de-transliteration).
pub fn latin_gain(dict_text: &str, cand: &str) -> bool {
    let d_spans = latin_spans(dict_text).len();
    let c_spans = latin_spans(cand).len();
    let d_letters = latin_letter_count(dict_text);
    let c_letters = latin_letter_count(cand);
    if c_spans > d_spans && c_letters > d_letters {
        return true;
    }
    c_letters >= d_letters + 8 && c_spans >= d_spans
}

const TRANSLATION_GLOSS: [&str; 17] = [
    "use", "send", "manage", "order", "call", "please", "company", "through", "instead", "will",
    "faster", "help", "want", "need", "ask", "tell", "let",
];

/// Latin tokens in cand that look like translated Thai, not restored jargon.
pub fn invented_translation_gloss(dict_text: &str, cand: &str) -> Vec<String> {
    let have: HashSet<String> = latin_spans(dict_text).into_iter().map(lower).collect();
    latin_spans(cand)
        .into_iter()
        .filter(|s| {
            let l = lower(s);
            TRANSLATION_GLOSS.contains(&l.as_str()) && !have.contains(&l)
        })
        .map(str::to_string)
        .collect()
}

/// `(final, flag)`: the stripped generation, or dict_text with the reason it tripped.
pub fn guardrail(dict_text: &str, generation: &str) -> (String, &'static str) {
    let c = strip_out(generation);
    let fallback = |flag| (dict_text.to_string(), flag);
    if c.is_empty() {
        return fallback("empty->dict");
    }
    let rt = metrics::tokenize(&metrics::normalize(dict_text)).len() as f64;
    let ct = metrics::tokenize(&metrics::normalize(&c)).len() as f64;
    let gain = latin_gain(dict_text, &c);
    if ct < 0.6 * rt && !gain {
        return fallback("tooShort->dict");
    }
    if ct > 1.6 * rt {
        return fallback("tooLong->dict");
    }
    if !lost_spans(dict_text, &c, gain).is_empty() {
        return fallback("spanLoss->dict");
    }
    let (lost, invented) = thai_divergence(dict_text, &c);
    if lost >= R2_LOST_THRESH || invented >= R2_INVENT_THRESH {
        return fallback("editDist->dict");
    }
    if !invented_translation_gloss(dict_text, &c).is_empty() {
        return fallback("translate->dict");
    }
    (c, "ok")
}
