//! `sidecar_server.remove_fillers`: drop standalone filler words before cleanup.
//!
//! Intentionally diverges from Oliv (see KNOWN_DIFFS.md): a filler also takes
//! the punctuation right after it, a Thai filler glued to its neighbours is
//! dropped when newmm cuts it as a whole word, and `ฮึม`/`ฮึ่ม`/`อึม`/`อึ่ม` count
//! as fillers.

use std::sync::LazyLock;

use crate::data::is_thai_word;
use crate::pyu::{collapse_blanks, has_thai, is_blank, is_thai, strip};
use crate::tokenize::word_tokenize;

/// `_FILLERS` plus `ฮึม`/`ฮึ่ม`/`อึม`/`อึ่ม`. `เออ` and `อะ` are real words.
const THAI_FILLERS: [&str; 12] = [
    "อืมม",
    "อืม",
    "เอ่อ",
    "เอ้อ",
    "อ่าา",
    "อ่า",
    "เอิ่ม",
    "หืม",
    "ฮึม",
    "ฮึ่ม",
    "อึม",
    "อึ่ม",
];
const ENGLISH_FILLERS: [&str; 6] = ["uhh", "erm", "hmm", "um", "uh", "er"];

/// Consumed with the filler before them, e.g. `Hmm, the` -> `the`.
fn is_trailing_punct(c: char) -> bool {
    matches!(c, ',' | '.' | '…' | '!' | '?' | '-')
}

/// `_FILLERS` in the regex alternation order (`sorted(key=len, reverse=True)`, stable).
static FILLERS: LazyLock<Vec<Vec<char>>> = LazyLock::new(|| {
    let mut v: Vec<Vec<char>> = THAI_FILLERS
        .iter()
        .chain(&ENGLISH_FILLERS)
        .map(|f| f.chars().collect())
        .collect();
    v.sort_by_key(|f| std::cmp::Reverse(f.len()));
    v
});

/// `_GLUE` under `re.IGNORECASE`: `A-Za-z0-9` and the Thai block. Python matches a
/// char against a case-insensitive range through its simple lower/upper mapping,
/// which also admits these four non-ASCII letters.
fn is_glue(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || is_thai(c)
        || matches!(c, '\u{0130}' | '\u{0131}' | '\u{017f}' | '\u{212a}')
}

/// Case-insensitive (ASCII) literal match of `pat` at `text[i..]`.
fn matches_at(text: &[char], i: usize, pat: &[char]) -> bool {
    i + pat.len() <= text.len()
        && text[i..i + pat.len()]
            .iter()
            .zip(pat)
            .all(|(a, b)| a.to_ascii_lowercase() == *b)
}

/// The filler's last char may be held (`เอ่ออ`, `อืมมม`, `hmmm`); `er` is not
/// stretched, since `err` is a word.
fn stretch_end(text: &[char], f: &[char], mut end: usize) -> usize {
    let last = f[f.len() - 1];
    if f != ['e', 'r'] {
        while text
            .get(end)
            .is_some_and(|c| c.to_ascii_lowercase() == last)
        {
            end += 1;
        }
    }
    end
}

/// `-` joining two words: `uh-huh` is an answer, not a filler.
fn hyphen_joined(text: &[char], i: usize) -> bool {
    text.get(i) == Some(&'-') && text.get(i + 1).is_some_and(|&c| is_glue(c))
}

/// A lone `.`/`!`/`?` after a filler that ends the sentence: at the end of the
/// text or before a capital letter.
fn ends_sentence(text: &[char], punct: &[char], after: usize) -> bool {
    let rest = &text[after..];
    matches!(punct, ['.' | '!' | '?'])
        && match rest.iter().position(|c| !c.is_whitespace()) {
            None => true,
            Some(k) => k > 0 && rest[k].is_ascii_uppercase(),
        }
}

/// Returns `(new_text, n_removed)`; byte-identical passthrough when nothing fires.
pub fn remove_fillers(text: &str) -> (String, usize) {
    let t: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut n = 0;
    let mut i = 0;
    while i < t.len() {
        let behind_ok =
            i == 0 || !(is_glue(t[i - 1]) || (t[i - 1] == '-' && i >= 2 && is_glue(t[i - 2])));
        let hit = behind_ok
            .then(|| {
                FILLERS.iter().find_map(|f| {
                    if !matches_at(&t, i, f) {
                        return None;
                    }
                    let end = stretch_end(&t, f, i + f.len());
                    let bounded = t.get(end).is_none_or(|&c| !is_glue(c));
                    (bounded && !hyphen_joined(&t, end)).then_some(end)
                })
            })
            .flatten();
        let Some(end) = hit else {
            out.push(t[i]);
            i += 1;
            continue;
        };
        n += 1;
        i = end;
        while t.get(i).is_some_and(|&c| is_trailing_punct(c)) {
            i += 1;
        }
        if ends_sentence(&t, &t[end..i], i) && !is_blank(&out) {
            // `do it, um.` -> `do it.`: keep the full stop, drop the comma.
            let kept = out.trim_end();
            let kept = kept.strip_suffix(',').unwrap_or(kept).trim_end().len();
            out.truncate(kept);
            out.push(t[end]);
        } else if i > end && t.get(i) == Some(&' ') {
            i += 1;
        }
    }
    let (out, glued) = drop_thai_filler_words(out);
    n += glued;
    if n == 0 {
        return (text.to_string(), 0);
    }
    (strip(&collapse_blanks(&out)).to_string(), n)
}

/// `เอ่อ` is also the verb "to well up" (`น้ำตาเอ่อคลอ`, `น้ำเอ่อท่วมถนน`):
/// glued after one of these words, or before one of the next ones, it stays.
const UOE: &str = "เอ่อ";
const UOE_SUBJECTS: [&str; 3] = ["น้ำ", "ตา", "น้ำตา"];
const UOE_VERB_NEXT: [&str; 5] = ["ล้น", "คลอ", "ท่วม", "ท้น", "ขึ้น"];

/// Thai has no spaces, so the glue test above misses `เอ่อเดี๋ยว` or `ตัวนี้เอ่อ`.
/// Drops newmm words that are exactly a Thai filler, held (`เอ่อ` `อ`) or not,
/// when every other word in the same unspaced Thai run is a real word. A
/// fragment there (`อ่า` `กา` `ศ` from `อ่ากาศ`) means newmm cut through a word.
/// Linear in the number of words.
fn drop_thai_filler_words(text: String) -> (String, usize) {
    if !THAI_FILLERS.iter().any(|f| text.contains(f)) {
        return (text, 0);
    }
    let words = word_tokenize(&text, true);
    // (start, end) of each filler with its held tail, in token indexes.
    let mut fillers = Vec::new();
    let mut in_filler = vec![false; words.len()];
    let mut i = 0;
    while i < words.len() {
        let w = &words[i];
        i += 1;
        if THAI_FILLERS.contains(&w.as_str()) {
            let last = w.chars().last();
            let start = i - 1;
            while words
                .get(i)
                .is_some_and(|h| h.chars().all(|c| Some(c) == last))
            {
                i += 1;
            }
            in_filler[start..i].fill(true);
            fillers.push((start, i));
        }
    }
    // Each unspaced Thai run gets an id; count the fragments in it.
    let mut run_of = vec![usize::MAX; words.len()];
    let mut fragments: Vec<usize> = Vec::new();
    for (k, w) in words.iter().enumerate() {
        if !has_thai(w) {
            continue;
        }
        if k == 0 || run_of[k - 1] == usize::MAX {
            fragments.push(0);
        }
        run_of[k] = fragments.len() - 1;
        if !in_filler[k] && !is_thai_word(w) {
            fragments[run_of[k]] += 1;
        }
    }
    let verb_uoe = |a: usize, b: usize| {
        words[a] == UOE
            && ((a > 0 && UOE_SUBJECTS.contains(&words[a - 1].as_str()))
                || words
                    .get(b)
                    .is_some_and(|n| UOE_VERB_NEXT.iter().any(|v| n.starts_with(v))))
    };
    let mut drop = vec![false; words.len()];
    let mut n = 0;
    for &(a, b) in &fillers {
        if fragments[run_of[a]] == 0 && !verb_uoe(a, b) {
            drop[a..b].fill(true);
            n += 1;
        }
    }
    if n == 0 {
        return (text, 0);
    }
    let kept: String = words
        .iter()
        .zip(&drop)
        .filter(|(_, d)| !**d)
        .map(|(w, _)| w.as_str())
        .collect();
    (kept, n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filler_takes_its_punctuation() {
        assert_eq!(
            remove_fillers("Hmm, the latency is a bit high. Um, we should optimize."),
            ("the latency is a bit high. we should optimize.".into(), 2)
        );
        assert_eq!(remove_fillers("ok um... so"), ("ok so".into(), 1));
        assert_eq!(remove_fillers("uh- อันนี้"), ("อันนี้".into(), 1));
        assert_eq!(remove_fillers("um."), ("".into(), 1));
    }

    #[test]
    fn sentence_final_filler_keeps_the_full_stop() {
        assert_eq!(
            remove_fillers("We should do it, um."),
            ("We should do it.".into(), 1)
        );
        assert_eq!(remove_fillers("Ship it uh!"), ("Ship it!".into(), 1));
        assert_eq!(
            remove_fillers("We did it, um. Next we test."),
            ("We did it. Next we test.".into(), 1)
        );
        assert_eq!(remove_fillers("ok um. so"), ("ok so".into(), 1));
    }

    #[test]
    fn hyphenated_answers_are_not_fillers() {
        for s in ["uh-huh ok", "um-hmm ok", "mm-hmm"] {
            assert_eq!(remove_fillers(s), (s.to_string(), 0), "{s}");
        }
    }

    #[test]
    fn held_fillers_are_dropped_whole() {
        assert_eq!(remove_fillers("เอ่ออ ไปกัน"), ("ไปกัน".into(), 1));
        assert_eq!(remove_fillers("อืมมมม โอเค"), ("โอเค".into(), 1));
        assert_eq!(remove_fillers("so hmmm ok"), ("so ok".into(), 1));
        assert_eq!(remove_fillers("Ummm, right"), ("right".into(), 1));
        assert_eq!(remove_fillers("เอ่อออไปกัน"), ("ไปกัน".into(), 1));
        assert_eq!(remove_fillers("err ok"), ("err ok".into(), 0));
    }

    #[test]
    fn glued_thai_filler_is_dropped() {
        assert_eq!(remove_fillers("เอ่อเดี๋ยวนะ"), ("เดี๋ยวนะ".into(), 1));
        assert_eq!(remove_fillers("อืมกินข้าวก่อน"), ("กินข้าวก่อน".into(), 1));
        assert_eq!(remove_fillers("ตัวนี้เอ่อ deploy"), ("ตัวนี้ deploy".into(), 1));
        assert_eq!(remove_fillers("ฮึ่ม โอเค"), ("โอเค".into(), 1));
    }

    #[test]
    fn welling_up_is_not_a_filler() {
        for w in [
            "น้ำตาเอ่อคลอ",
            "น้ำเอ่อท่วมถนน",
            "น้ำตาเอ่อเลย",
            "น้ำเริ่มเอ่อขึ้นมา",
            "ตาเอ่อไปด้วยน้ำตา",
            "น้ำเอ่อล้นตลิ่ง",
        ] {
            assert_eq!(remove_fillers(w), (w.to_string(), 0), "{w}");
        }
        assert_eq!(remove_fillers("เอ่อเดี๋ยวนะ"), ("เดี๋ยวนะ".into(), 1));
    }

    #[test]
    fn long_glued_runs_take_linear_time() {
        let text = "เอ่อไปเอ่อมาเอ่อกิน".repeat(600);
        let t0 = std::time::Instant::now();
        let (out, n) = remove_fillers(&text);
        assert_eq!(n, 1800);
        assert_eq!(out, "ไปมากิน".repeat(600));
        assert!(t0.elapsed().as_millis() < 1500, "{:?}", t0.elapsed());
    }

    #[test]
    fn filler_cut_from_a_misspelled_word_stays() {
        for w in ["อ่ากาศดี", "วันนี้อ่ากาศ"] {
            assert_eq!(remove_fillers(w), (w.to_string(), 0), "{w}");
        }
    }

    #[test]
    fn real_words_survive() {
        for w in ["อ่านหนังสือ", "อ่างล้างหน้า", "เออ ได้", "ใช่อะ", "อึมครึม"]
        {
            assert_eq!(remove_fillers(w), (w.to_string(), 0));
        }
    }
}
