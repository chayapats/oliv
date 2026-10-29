//! Repairs for STT output that spells Latin letters out one by one (Qwen3-ASR
//! writes `G P U`, `C I`, `S three`). Not in Oliv: joining them first keeps the
//! gate from seeing single-letter crumbs and the guardrail from counting `GPU`
//! as too short against `G P U`.

use unicode_general_category::{GeneralCategory, get_general_category};

use crate::pyu::is_thai;
use crate::spacing::is_thai_mark;

/// Longest spelled run that is joined; longer ones are more likely a list.
const MAX_SPELLED: usize = 6;

const DIGIT_WORDS: [&str; 10] = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
];

/// Uppercase English words that are not a letter code before a digit word
/// (`OK one more`, `3 PM two days`, `NO ONE`).
const NOT_CODES: [&str; 40] = [
    "OK", "AM", "PM", "NO", "SO", "TO", "GO", "DO", "ON", "OR", "IN", "IS", "IT", "AT", "AS", "AN",
    "BY", "OF", "UP", "WE", "US", "MY", "ME", "HE", "BE", "IF", "THE", "AND", "FOR", "BUT", "NOT",
    "ARE", "YOU", "ALL", "ANY", "WAS", "HAS", "GOT", "ONE", "TWO",
];

/// A char that glues a Latin letter into a longer word (`don't`, `U2`, `Á`
/// written as `A` plus U+0301). Thai marks only count after the letter, where
/// they make it part of a corrupted syllable (`Gี`); before it they end a
/// Thai word (`ที่G P U`).
fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || matches!(c, '\'' | '’')
        || (get_general_category(c) == GeneralCategory::NonspacingMark && !is_thai(c))
}

/// True if no word char sits right before `t[i]` or right after `t[j - 1]`.
fn bounded(t: &[char], i: usize, j: usize) -> bool {
    (i == 0 || !is_word_char(t[i - 1]))
        && t.get(j)
            .is_none_or(|&c| !is_word_char(c) && !is_thai_mark(c))
}

/// A lowercase ASCII word starts at `t[i]` after a space: the sentence goes on
/// in English, so the letters or digit before it are words (`Vitamin C I
/// think`, `plan B two days`).
fn word_follows(t: &[char], i: usize) -> bool {
    t.get(i) == Some(&' ') && t.get(i + 1).is_some_and(char::is_ascii_lowercase)
}

/// The next word at `t[i..]` after a space is `or`/`and`: a list of options
/// (`A B or C`), not a spelled acronym.
fn list_follows(t: &[char], i: usize) -> bool {
    ["or", "and"].iter().any(|w| {
        let end = i + 1 + w.len();
        t.get(i) == Some(&' ')
            && end <= t.len()
            && t[i + 1..end].iter().copied().eq(w.chars())
            && bounded(t, i + 1, end)
    })
}

/// `G P U` -> `GPU`, `C I` -> `CI`, `S three` -> `S3`, `R two` -> `R2`.
/// Returns `(new_text, n_joined)`; byte-identical passthrough when nothing fires.
pub fn join_spelled(text: &str) -> (String, usize) {
    let (t, a) = join_letters(text);
    let (t, b) = join_letter_digits(&t);
    (t, a + b)
}

/// Two to six single uppercase letters separated by single spaces become one
/// acronym. A pair of only `I`/`A` is left alone (`I A`, `A I`), and a final
/// `I`/`A` before a lowercase word is the pronoun or article that starts it
/// (`Vitamin C I think`, `option B I guess`). A longer run, a run before
/// `or`/`and` (`A B or C`) and a run glued to `-` (`A B-tree`) stay.
fn join_letters(text: &str) -> (String, usize) {
    let t: Vec<char> = text.chars().collect();
    let single = |i: usize| t.get(i).is_some_and(char::is_ascii_uppercase) && bounded(&t, i, i + 1);
    let mut out = String::with_capacity(text.len());
    let mut n = 0;
    let mut i = 0;
    while i < t.len() {
        if !single(i) {
            out.push(t[i]);
            i += 1;
            continue;
        }
        let mut letters = vec![t[i]];
        let mut j = i + 1;
        while t.get(j) == Some(&' ') && single(j + 1) {
            letters.push(t[j + 1]);
            j += 2;
        }
        let (end, run_len) = (j, letters.len());
        if letters.len() > 1 && word_follows(&t, j) && matches!(letters.last(), Some('I' | 'A')) {
            letters.pop();
            j -= 2;
        }
        let only_ia = letters.len() == 2 && letters.iter().all(|c| matches!(c, 'I' | 'A'));
        let list = list_follows(&t, j) || t.get(j) == Some(&'-');
        if letters.len() > 1 && run_len <= MAX_SPELLED && !only_ia && !list {
            out.extend(letters);
            n += 1;
            i = j;
        } else {
            out.extend(&t[i..end]);
            i = end;
        }
    }
    (out, n)
}

/// The digit of an English digit word at `t[i..]` (any case) and its length.
fn digit_word_at(t: &[char], i: usize) -> Option<(usize, usize)> {
    DIGIT_WORDS.iter().enumerate().find_map(|(d, w)| {
        let end = i + w.len();
        let hit = end <= t.len()
            && t[i..end]
                .iter()
                .zip(w.chars())
                .all(|(a, b)| a.to_ascii_lowercase() == b)
            && bounded(t, i, end);
        hit.then_some((d, w.len()))
    })
}

/// A letter code read out with a digit word becomes letter + digit. The code
/// is one letter other than `a`/`i`, or two or three uppercase letters that are
/// not an English word ([`NOT_CODES`]), so `for one`, `Cover eight` and
/// `OK one` stay. A digit word that a lowercase word follows is part of the
/// sentence (`plan B two days later`, `Press X one more time`).
fn join_letter_digits(text: &str) -> (String, usize) {
    let t: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut n = 0;
    let mut i = 0;
    while i < t.len() {
        if !t[i].is_ascii_alphabetic() {
            out.push(t[i]);
            i += 1;
            continue;
        }
        let mut k = i;
        while k < t.len() && t[k].is_ascii_alphabetic() {
            k += 1;
        }
        let code = &t[i..k];
        let is_code = match code {
            [c] => !matches!(c.to_ascii_lowercase(), 'a' | 'i'),
            _ => {
                code.len() <= 3
                    && code.iter().all(char::is_ascii_uppercase)
                    && !NOT_CODES.contains(&code.iter().collect::<String>().as_str())
            }
        };
        let digit = (is_code && bounded(&t, i, k) && t.get(k) == Some(&' '))
            .then(|| digit_word_at(&t, k + 1))
            .flatten()
            .filter(|&(_, len)| !word_follows(&t, k + 1 + len));
        out.extend(code);
        i = k;
        if let Some((d, len)) = digit {
            out.push(char::from_digit(d as u32, 10).unwrap());
            n += 1;
            i = k + 1 + len;
        }
    }
    (out, n)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn joined(s: &str) -> String {
        join_spelled(s).0
    }

    #[test]
    fn joins_spelled_acronyms() {
        assert_eq!(join_spelled("บริษัท G P U"), ("บริษัท GPU".into(), 1));
        assert_eq!(joined("ปรับ T T L ของ Redis"), "ปรับ TTL ของ Redis");
        assert_eq!(
            join_spelled("เทสต์บน C I ของ Travis C I แล้วส่งต่อ C D"),
            ("เทสต์บน CI ของ Travis CI แล้วส่งต่อ CD".into(), 3)
        );
        assert_eq!(joined("คอนเทนเนอร์ O M ตอน"), "คอนเทนเนอร์ OM ตอน");
        assert_eq!(joined("เปิดตัวG P Uรุ่นใหม่"), "เปิดตัวGPUรุ่นใหม่");
        assert_eq!(joined("(G P U)."), "(GPU).");
    }

    #[test]
    fn leaves_words_and_long_runs() {
        for s in ["I A", "A I", "A B C D E F G", "GP U", "g p u", ""] {
            assert_eq!(join_spelled(s), (s.to_string(), 0), "{s}");
        }
        assert_eq!(joined("Plan A B C"), "Plan ABC");
        assert_eq!(joined("G P Ux"), "GP Ux");
        assert_eq!(joined("G  P U"), "G  PU");
    }

    #[test]
    fn joins_letter_digit_codes() {
        assert_eq!(
            join_spelled("Cloudflare R two แล้ว"),
            ("Cloudflare R2 แล้ว".into(), 1)
        );
        assert_eq!(joined("MinIO แทน S three"), "MinIO แทน S3");
        assert_eq!(joined("minio ten s three."), "minio ten s3.");
        assert_eq!(joined("ใช้ GPT Four"), "ใช้ GPT4");
        for s in [
            "for one",
            "Cover eight",
            "a one",
            "I two",
            "S threes",
            "S three's",
            "don't one",
            "Tree five",
            "Mac one",
            "S  three",
        ] {
            assert_eq!(join_spelled(s), (s.to_string(), 0), "{s}");
        }
    }

    #[test]
    fn english_pronouns_articles_and_words_are_not_codes() {
        for s in [
            "Vitamin C I think",
            "option B I guess",
            "plan B A lot",
            "OK one more thing",
            "at 3 PM two days",
            "at 9 AM two",
            "NO ONE",
            "ONE TWO",
            "IT one",
            "We'll go with plan B two days later",
            "Press X one more time",
            "Vitamin C one tablet a day",
            "The PS one more thing",
        ] {
            assert_eq!(join_spelled(s), (s.to_string(), 0), "{s}");
        }
        assert_eq!(joined("รัน C I ผ่าน"), "รัน CI ผ่าน");
        assert_eq!(joined("Circle C I."), "Circle CI.");
        assert_eq!(joined("G P U I think"), "GPU I think");
        assert_eq!(joined("Plan A B C"), "Plan ABC");
    }

    #[test]
    fn lists_hyphens_long_runs_and_marks_stay() {
        for s in [
            "Choose A B or C",
            "A B and C",
            "I use A B-tree index",
            "A B C D E F I think",
            "B A\u{301} C",
            "B C\u{301}",
            "G Pี U",
        ] {
            assert_eq!(join_spelled(s), (s.to_string(), 0), "{s}");
        }
        assert_eq!(joined("A B C D E F ok"), "ABCDEF ok");
        assert_eq!(joined("ที่G P U"), "ที่GPU");
        assert_eq!(joined("G P U orchestration"), "GPU orchestration");
    }

    #[test]
    fn spelled_letters_then_digit() {
        assert_eq!(join_spelled("S S H two"), ("SSH2".into(), 2));
    }
}
