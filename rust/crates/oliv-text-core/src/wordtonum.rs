//! pythainlp 5.3.4 `util/wordtonum.py`: `words_to_num` as Oliv calls it, with a
//! single `str` instead of a token list.

use std::sync::LazyLock;

use num_bigint::BigInt;
use regex::Regex;

use crate::tokenize::word_tokenize_with;
use crate::trie::Trie;

const DIGITS: [(&str, u32); 11] = [
    ("หนึ่ง", 1),
    ("เอ็ด", 1),
    ("สอง", 2),
    ("ยี่", 2),
    ("สาม", 3),
    ("สี่", 4),
    ("ห้า", 5),
    ("หก", 6),
    ("เจ็ด", 7),
    ("แปด", 8),
    ("เก้า", 9),
];
const POWERS_OF_10: [(&str, u32); 5] = [
    ("สิบ", 10),
    ("ร้อย", 100),
    ("พัน", 1000),
    ("หมื่น", 10000),
    ("แสน", 100000),
];

static RE_THAI_NUMERALS: LazyLock<Regex> = LazyLock::new(|| {
    let d = "(|หนึ่ง|เอ็ด|สอง|ยี่|สาม|สี่|ห้า|หก|เจ็ด|แปด|เก้า)";
    let six = format!("({d}แสน)?({d}หมื่น)?({d}พัน)?({d}ร้อย)?({d}สิบ)?{d}?");
    Regex::new(&format!(r"\A(?:(ลบ)?({six}ล้าน)*{six})\z")).unwrap()
});

/// `_tokenizer()`: newmm over just the numeral words.
static NUM_TRIE: LazyLock<Trie> = LazyLock::new(|| {
    let words = DIGITS.iter().chain(&POWERS_OF_10).map(|(w, _)| *w);
    Trie::new(words.chain(["ล้าน", "ลบ"]))
});

/// Python raises ValueError for anything that is not a Thai numeral.
#[derive(Debug, PartialEq)]
pub struct ValueError;

pub fn thaiword_to_num(word: &str) -> Result<BigInt, ValueError> {
    if word.is_empty() {
        return Err(ValueError);
    }
    if word == "ศูนย์" {
        return Ok(BigInt::from(0));
    }
    if !RE_THAI_NUMERALS.is_match(word) {
        return Err(ValueError);
    }
    let mut tokens = word_tokenize_with(word, &NUM_TRIE, true);
    let is_minus = tokens[0] == "ลบ";
    if is_minus {
        tokens.remove(0);
    }
    let mut acc = BigInt::from(0);
    let mut next_digit: u32 = 1;
    for tok in &tokens {
        if let Some((_, d)) = DIGITS.iter().find(|(w, _)| w == tok) {
            next_digit = *d;
        } else if let Some((_, p)) = POWERS_OF_10.iter().find(|(w, _)| w == tok) {
            acc += next_digit.max(1) * p;
            next_digit = 0;
        } else {
            acc = (acc + next_digit) * 1_000_000u32;
            next_digit = 0;
        }
    }
    acc += next_digit;
    Ok(if is_minus { -acc } else { acc })
}

/// `words_to_num(words)` for a single string. With a `str`, `"จุด" in words` is a
/// substring test and the fractional part starts at `words.index("จุด") + 1`,
/// i.e. inside "จุด" itself, so its first character ("ุ") always raises: any input
/// containing "จุด" is a ValueError and the float path is unreachable.
pub fn words_to_num(words: &str) -> Result<BigInt, ValueError> {
    if words.contains("จุด") {
        return Err(ValueError);
    }
    thaiword_to_num(words)
}
