//! Writing systems OLIV accepts. It dictates Thai and English, so a letter of
//! any other script (Hangul, Han, kana, Lao, Cyrillic, ...) in a transcript is a
//! recognition artifact, and in a cleanup result a model error: on FLEURS Thai
//! the cleanup model wrote a Hangul syllable into one Thai name and Lao letters
//! into another. Shared by the Mac pipeline (`oliv-text`) and the OLIV server.

use std::sync::LazyLock;

use regex::Regex;

use crate::pyu::{is_space, is_thai, strip};

/// Latin letters with their diacritics, IPA and the Latin extensions.
fn is_latin(c: char) -> bool {
    matches!(c,
        '\0'..='\u{036f}'
        | '\u{1ab0}'..='\u{1aff}'
        | '\u{1dc0}'..='\u{1eff}'
        | '\u{2c60}'..='\u{2c7f}'
        | '\u{a720}'..='\u{a7ff}'
        | '\u{ab30}'..='\u{ab6f}'
        | '\u{fb00}'..='\u{fb06}')
}

/// Blocks of other scripts, so their combining marks (a Lao tone mark, a
/// virama), which are not letters, count as well. Only marks: their digits,
/// currency signs and punctuation (Khmer ០–៩ and ៛, a danda) are kept.
fn in_other_script_block(c: char) -> bool {
    matches!(c,
        '\u{0370}'..='\u{0dff}'
        | '\u{0e80}'..='\u{1aaf}'
        | '\u{1b00}'..='\u{1dbf}'
        | '\u{2c00}'..='\u{2c5f}'
        | '\u{2c80}'..='\u{2dff}'
        | '\u{3040}'..='\u{9fff}'
        | '\u{a000}'..='\u{a71f}'
        | '\u{a800}'..='\u{ab2f}'
        | '\u{ab70}'..='\u{d7ff}'
        | '\u{f900}'..='\u{faff}'
        | '\u{fb13}'..='\u{fdff}'
        | '\u{fe70}'..='\u{fefe}'
        | '\u{ff66}'..='\u{ffdc}')
}

static MARK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\p{M}$").unwrap());

/// A combining mark (Unicode category M).
fn is_mark(c: char) -> bool {
    let mut buf = [0u8; 4];
    MARK.is_match(c.encode_utf8(&mut buf))
}

/// A letter or mark of a script other than Thai and Latin, or U+FFFD (a byte
/// the recognizer could not decode). Digits, punctuation, symbols, emoji and
/// whitespace are not foreign, whichever script they belong to.
pub fn is_foreign(c: char) -> bool {
    c == '\u{fffd}'
        || (!is_thai(c)
            && !is_latin(c)
            && !is_space(c)
            && (c.is_alphabetic() || (in_other_script_block(c) && is_mark(c))))
}

/// Whether `output` has a foreign char that `input` does not: a rewrite that
/// added another script. Foreign text copied through unchanged is allowed.
pub fn adds_foreign(input: &str, output: &str) -> bool {
    output.chars().any(|c| is_foreign(c) && !input.contains(c))
}

/// `_strip_cjk` for every script but Thai and Latin ([`is_foreign`]), plus
/// undecodable bytes (U+FFFD); not in the Python reference. OLIV dictates
/// Thai and English, so such letters in a transcript are recognition artifacts
/// (a Cyrillic tail after a hallucinated FLEURS transcript), never words to type.
pub fn strip_foreign(text: &str) -> String {
    strip_chars(text, is_foreign)
}

/// `text` without the chars `drop` selects, whitespace runs then squeezed to
/// one space (`re.sub(r"\s{2,}", " ", ...)`) and the ends stripped, as in
/// `_strip_cjk`; `text` unchanged if it has no such char.
pub fn strip_chars(text: &str, drop: fn(char) -> bool) -> String {
    if !text.chars().any(drop) {
        return text.to_string();
    }
    let kept: Vec<char> = text.chars().filter(|&c| !drop(c)).collect();
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

#[cfg(test)]
mod tests {
    use super::{adds_foreign, is_foreign};

    #[test]
    fn only_thai_and_latin_are_native() {
        // Thai letters, marks, digits and baht; ASCII; Latin with diacritics
        // (precomposed and combining); punctuation, symbols, emoji; spaces,
        // including ones that sit in other scripts' blocks.
        for c in "กฃฮั่์ำ๑฿ AZaz09éüçĞșạ\u{301}.,!?-“”…€°™😀❤\u{fe0f}\u{1680}\u{3000}".chars()
        {
            assert!(!is_foreign(c), "{c:?}");
        }
        // Other scripts' digits, currency signs and punctuation: a price in
        // Khmer digits and riel, a Devanagari danda, a fullwidth comma.
        for c in "០១២៣៤៥៦៧៨៩៛។\u{964}\u{ff0c}".chars() {
            assert!(!is_foreign(c), "{c:?}");
        }
        // Hangul, Han, kana, Lao (letter, vowel sign, tone mark), Cyrillic,
        // Greek, Arabic, Devanagari, fullwidth Latin, U+FFFD.
        for c in "투谢あア\u{e8a}\u{eb1}\u{ec8}\u{410}\u{3bc}\u{633}\u{915}\u{ff54}\u{fffd}".chars()
        {
            assert!(is_foreign(c), "{c:?}");
        }
    }

    #[test]
    fn foreign_strip_keeps_other_scripts_digits_and_currency() {
        assert_eq!(super::strip_foreign("ราคา ១០០៛"), "ราคา ១០០៛");
        assert_eq!(super::strip_foreign("ราคา ១០០៛ 투"), "ราคา ១០០៛");
    }

    #[test]
    fn only_added_foreign_text_counts() {
        // FLEURS Thai: the cleanup model's Hangul and Lao letters.
        assert!(adds_foreign("ทูปปัว ธามาซิส", "투ปัวธามาซิส"));
        assert!(adds_foreign(
            "ซึนดาบันส์",
            "\u{e8a}ึน\u{e94}\u{eb2}\u{e9a}\u{eb1}\u{e99}ส์"
        ));
        // Copied through, or no other script at all.
        assert!(!adds_foreign("谢谢 ครับ", "谢谢ครับ"));
        assert!(!adds_foreign("รีสตาร์ทเซิร์ฟเวอร์", "restart server"));
        assert!(!adds_foreign("คาเฟ่", "café"));
    }
}
