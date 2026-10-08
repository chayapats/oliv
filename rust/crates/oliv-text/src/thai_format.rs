//! `sidecar/thai_format.py`: reduplication (`มากมาก` -> `มากๆ`) then spoken
//! numbers -> Arabic digits, on the final cleaned text.

use num_bigint::BigInt;

use crate::data::is_thai_word;
use crate::pyu::has_thai;
use crate::tokenize::word_tokenize;
use crate::wordtonum::words_to_num;

const STOPLIST: [&str; 8] = ["ไม่", "ก็", "ที่", "จะ", "นะ", "ค่ะ", "ครับ", "คะ"];
const NUMERAL_WORDS: [&str; 18] = [
    "ศูนย์",
    "หนึ่ง",
    "สอง",
    "ยี่",
    "สาม",
    "สี่",
    "ห้า",
    "หก",
    "เจ็ด",
    "แปด",
    "เก้า",
    "เอ็ด",
    "สิบ",
    "ร้อย",
    "พัน",
    "หมื่น",
    "แสน",
    "ล้าน",
];
const DOT: &str = "จุด";
const MAI_YAMOK: &str = "ๆ";
const MAX_NUM_RUN: usize = 40;

fn num(tok: &str) -> Option<BigInt> {
    words_to_num(tok).ok()
}

fn numeral_value(tok: &str) -> Option<BigInt> {
    if tok.is_empty()
        || !tok
            .chars()
            .all(|c| NUMERAL_WORDS.iter().any(|w| w.contains(c)))
    {
        return None;
    }
    num(tok)
}

fn is_unit_digit(v: &Option<BigInt>) -> bool {
    v.as_ref()
        .is_some_and(|i| *i >= BigInt::from(0) && *i <= BigInt::from(9))
}

fn render_decimal_segment(seg: &[&str]) -> Option<String> {
    let vals: Vec<Option<BigInt>> = seg.iter().map(|t| num(t)).collect();
    if vals.iter().all(is_unit_digit) {
        return Some(vals.into_iter().map(|v| v.unwrap().to_string()).collect());
    }
    num(&seg.concat()).map(|c| c.to_string())
}

fn collapse_reduplication(tokens: Vec<String>) -> (Vec<String>, usize) {
    let n = tokens.len();
    let mut out = Vec::with_capacity(n);
    let mut changes = 0;
    let mut i = 0;
    while i < n {
        let tok = &tokens[i];
        let mut j = i + 1;
        while j < n && tokens[j] == *tok {
            j += 1;
        }
        if j - i >= 2
            && is_thai_word(tok)
            && !STOPLIST.contains(&tok.as_str())
            && num(tok).is_none()
        {
            if j < n && tokens[j] == MAI_YAMOK {
                out.push(tok.clone());
            } else {
                out.push(format!("{tok}{MAI_YAMOK}"));
            }
            changes += 1;
        } else {
            out.extend_from_slice(&tokens[i..j]);
        }
        i = j;
    }
    (out, changes)
}

fn convert_numbers(tokens: Vec<String>) -> (Vec<String>, usize) {
    let n = tokens.len();
    let is_num: Vec<bool> = tokens.iter().map(|t| numeral_value(t).is_some()).collect();
    let is_dot: Vec<bool> = tokens.iter().map(|t| t == DOT).collect();
    let mut out = Vec::with_capacity(n);
    let mut changes = 0;
    let mut i = 0;
    while i < n {
        if !is_num[i] {
            out.push(tokens[i].clone());
            i += 1;
            continue;
        }
        let mut end = i + 1;
        while end < n {
            if is_num[end] || (is_dot[end] && end + 1 < n && is_num[end + 1]) {
                end += 1;
            } else {
                break;
            }
        }
        let run = &tokens[i..end];
        if end - i > MAX_NUM_RUN {
            out.extend_from_slice(run);
            i = end;
            continue;
        }
        if is_dot[i..end].iter().any(|&d| d) {
            let mut segments: Vec<Vec<&str>> = vec![Vec::new()];
            for k in i..end {
                if is_dot[k] {
                    segments.push(Vec::new());
                } else {
                    segments.last_mut().unwrap().push(&tokens[k]);
                }
            }
            let int_val = num(&segments[0].concat());
            let rendered: Option<Vec<String>> = int_val.as_ref().and_then(|_| {
                segments[1..]
                    .iter()
                    .map(|fs| render_decimal_segment(fs))
                    .collect()
            });
            match (int_val, rendered) {
                (Some(iv), Some(r)) => {
                    out.push(
                        std::iter::once(iv.to_string())
                            .chain(r)
                            .collect::<Vec<_>>()
                            .join("."),
                    );
                    changes += 1;
                }
                _ => out.extend_from_slice(run),
            }
        } else {
            match num(&run.concat()) {
                Some(v) if v >= BigInt::from(10) => {
                    out.push(v.to_string());
                    changes += 1;
                }
                _ => out.extend_from_slice(run),
            }
        }
        i = end;
    }
    (out, changes)
}

/// `apply_thai_format(text)` -> `(formatted_text, n_changes)`.
pub fn apply_thai_format(text: &str) -> (String, usize) {
    if text.is_empty() || !has_thai(text) {
        return (text.to_string(), 0);
    }
    let tokens = word_tokenize(text, true);
    let (tokens, n_redup) = collapse_reduplication(tokens);
    let (tokens, n_num) = convert_numbers(tokens);
    (tokens.concat(), n_redup + n_num)
}
