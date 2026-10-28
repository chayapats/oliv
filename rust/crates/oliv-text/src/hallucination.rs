//! Sidecar no-speech gates on the transcript: CJK strip (B) and caption-phrase /
//! repetition-loop hallucinations (D).

use std::collections::HashMap;

use crate::pyu::{casefold, collapse_ws, is_space, is_word, lower, remove_ws, split_ws, strip};

fn is_cjk(c: char) -> bool {
    matches!(c,
        '\u{3040}'..='\u{30ff}'
        | '\u{3400}'..='\u{4dbf}'
        | '\u{4e00}'..='\u{9fff}'
        | '\u{f900}'..='\u{faff}'
        | '\u{ac00}'..='\u{d7af}')
}

/// `_strip_cjk`: drop CJK / kana / hangul, then squeeze whitespace runs.
pub fn strip_cjk(text: &str) -> String {
    if !text.chars().any(is_cjk) {
        return text.to_string();
    }
    let kept: Vec<char> = text.chars().filter(|&c| !is_cjk(c)).collect();
    // re.sub(r"\s{2,}", " ", ...)
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < kept.len() {
        if is_space(kept[i]) {
            let mut j = i;
            while j < kept.len() && is_space(kept[j]) {
                j += 1;
            }
            if j - i >= 2 {
                out.push(' ');
            } else {
                out.push(kept[i]);
            }
            i = j;
        } else {
            out.push(kept[i]);
            i += 1;
        }
    }
    strip(&out).to_string()
}

const HALLUCINATION_PHRASES: [&str; 15] = [
    "thank you for watching",
    "thanks for watching",
    "thank you for listening",
    "thanks for listening",
    "please subscribe",
    "please like and subscribe",
    "like and subscribe",
    "subscribe to my channel",
    "don't forget to subscribe",
    "dont forget to subscribe",
    "see you next time",
    "see you in the next video",
    "see you in the next one",
    "bye bye",
    "www.youtube.com",
];
const PHRASE_RATIO: f64 = 0.70;
const REPETITION_MIN_RUN: usize = 6;
const REPETITION_MIN_CHARS: usize = 12;

fn normalize_hallucination_text(text: &str) -> String {
    let s = lower(text);
    let s: String = strip(&s)
        .chars()
        .map(|c| if is_word(c) || is_space(c) { c } else { ' ' })
        .collect();
    strip(&collapse_ws(&s)).to_string()
}

fn clen(s: &str) -> usize {
    s.chars().count()
}

/// `_is_hallucination_phrase`: the transcript is (almost) all caption ghosts.
pub fn hallucination_phrase(text: &str) -> bool {
    let norm = normalize_hallucination_text(text);
    let n = clen(&norm);
    if n < 8 {
        return false;
    }
    for phrase in HALLUCINATION_PHRASES {
        if norm == phrase {
            return true;
        }
        if norm.contains(phrase) && clen(phrase) as f64 / n as f64 >= PHRASE_RATIO {
            return true;
        }
    }
    let mut phrases = HALLUCINATION_PHRASES;
    phrases.sort_by_key(|p| std::cmp::Reverse(clen(p)));
    let mut stripped = norm.clone();
    for phrase in phrases {
        stripped = stripped.replace(phrase, " ");
    }
    let stripped = strip(&collapse_ws(&stripped)).to_string();
    if stripped.is_empty() {
        return true;
    }
    clen(&stripped) as f64 / n as f64 <= 1.0 - PHRASE_RATIO
}

/// `_is_repetition_loop`: a tight spaced or unspaced repetition.
pub fn repetition_loop(text: &str) -> bool {
    let t = strip(text);
    if clen(t) < REPETITION_MIN_CHARS {
        return false;
    }
    let parts: Vec<String> = split_ws(t).into_iter().map(casefold).collect();
    if parts.len() >= REPETITION_MIN_RUN {
        let mut run = 1;
        for i in 1..parts.len() {
            if parts[i] == parts[i - 1] {
                run += 1;
                if run >= REPETITION_MIN_RUN {
                    return true;
                }
            } else {
                run = 1;
            }
        }
        // Counter.most_common(1): highest count, first inserted on ties.
        let mut counts: HashMap<&str, (usize, usize)> = HashMap::new();
        for (i, p) in parts.iter().enumerate() {
            counts.entry(p).or_insert((0, i)).0 += 1;
        }
        let (top, (n, _)) = counts
            .iter()
            .max_by(|a, b| a.1.0.cmp(&b.1.0).then(b.1.1.cmp(&a.1.1)))
            .unwrap();
        if clen(top) <= 12 && *n >= REPETITION_MIN_RUN && *n as f64 / parts.len() as f64 >= 0.7 {
            return true;
        }
    }

    let compact: Vec<char> = remove_ws(t).chars().collect();
    if compact.len() >= REPETITION_MIN_CHARS {
        for unit_len in 1..9 {
            let unit = &compact[..unit_len];
            let mut end = 0;
            while compact.len() >= end + unit_len && compact[end..end + unit_len] == *unit {
                end += unit_len;
            }
            let copies = end / unit_len;
            if copies >= REPETITION_MIN_RUN && end as f64 / compact.len() as f64 >= 0.8 {
                return true;
            }
        }
    }
    false
}

/// `_is_text_hallucination`: gate (D).
pub fn text_hallucination(text: &str) -> bool {
    if strip(text).is_empty() {
        return false;
    }
    hallucination_phrase(text) || repetition_loop(text)
}
