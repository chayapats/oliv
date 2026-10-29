//! Sidecar no-speech gates on the transcript: CJK strip (B) and caption-phrase /
//! repetition-loop hallucinations (D). `trim_repetition_loops` is not in Oliv: it
//! keeps the real speech in front of a decoder loop instead of dropping it all.

use std::collections::HashMap;

use crate::pyu::{casefold, collapse_ws, is_space, is_word, lower, remove_ws, split_ws, strip};

pub(crate) fn is_cjk(c: char) -> bool {
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

/// Byte spans of the `str.split()` tokens.
fn token_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut start = None;
    for (i, c) in text.char_indices() {
        match (is_space(c), start) {
            (true, Some(s)) => {
                spans.push((s, i));
                start = None;
            }
            (false, None) => start = Some(i),
            _ => {}
        }
    }
    if let Some(s) = start {
        spans.push((s, text.len()));
    }
    spans
}

/// A repeated token that may be dictated on purpose (`0 8 1 1 1 1 1 1 2 3`):
/// a digit string or a single char. Collapsing it would silently type a wrong
/// number, so such a run is left for `text_hallucination` to reject.
fn may_be_spelled(word: &str) -> bool {
    word.chars().count() < 2 || word.chars().all(char::is_numeric)
}

/// Collapse every run of >= `REPETITION_MIN_RUN` identical (casefolded) tokens
/// to its first copy, except runs of [`may_be_spelled`] tokens. A cut-off last
/// token that is a prefix of the looped one ('ต' after 'ต้อง ×N') belongs to the
/// loop. Returns the trimmed text and the number of non-space chars outside the
/// loops, or None when there is no loop.
pub fn trim_repetition_loops(text: &str) -> Option<(String, usize)> {
    if clen(strip(text)) < REPETITION_MIN_CHARS {
        return None;
    }
    let spans = token_spans(text);
    let words: Vec<String> = spans.iter().map(|&(a, b)| casefold(&text[a..b])).collect();
    let mut out = String::with_capacity(text.len());
    let (mut copied, mut outside, mut looped) = (0, 0, false);
    let mut i = 0;
    while i < words.len() {
        let mut j = i + 1;
        while j < words.len() && words[j] == words[i] {
            j += 1;
        }
        if j - i >= REPETITION_MIN_RUN && !may_be_spelled(&words[i]) {
            if j + 1 == words.len() && words[i].starts_with(words[j].as_str()) {
                j += 1;
            }
            out.push_str(&text[copied..spans[i].1]);
            copied = spans[j - 1].1;
            looped = true;
        } else {
            outside += spans[i..j]
                .iter()
                .map(|&(a, b)| clen(&text[a..b]))
                .sum::<usize>();
        }
        i = j;
    }
    looped.then(|| {
        out.push_str(&text[copied..]);
        (out, outside)
    })
}

/// `_is_text_hallucination`: gate (D).
pub fn text_hallucination(text: &str) -> bool {
    if strip(text).is_empty() {
        return false;
    }
    hallucination_phrase(text) || repetition_loop(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trailing_loop_is_trimmed() {
        let loop_ = ["ต้อง"; 30].join(" ");
        let text = format!("the latency is a bit high เราควร {loop_} ต");
        assert_eq!(
            trim_repetition_loops(&text),
            Some(("the latency is a bit high เราควร ต้อง".into(), 26))
        );
        let text = "ok Yes Yes Yes yes yes yes yes done";
        assert_eq!(trim_repetition_loops(text), Some(("ok Yes done".into(), 6)));
    }

    #[test]
    fn whole_loop_leaves_nothing_outside() {
        let text = ["ค่ะ"; 30].join(" ");
        assert_eq!(trim_repetition_loops(&text), Some(("ค่ะ".into(), 0)));
    }

    #[test]
    fn no_loop_is_none() {
        for text in [
            "ไป ไป ไป ไป ไป ประชุม",
            "a a a a a a",
            "คือคือคือคือคือคือคือคือ",
            "เบอร์ 0 8 1 1 1 1 1 1 2 3",
            "รหัสผ่าน 1 1 1 1 1 1",
            "ok x x x x x x go",
            "",
        ] {
            assert_eq!(trim_repetition_loops(text), None);
        }
    }
}
