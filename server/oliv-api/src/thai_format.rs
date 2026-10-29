//! `sidecar/thai_format.py`: reduplication (`มากมาก` -> `มากๆ`) then spoken
//! numbers -> Arabic digits, on the final cleaned text.
//!
//! Intentionally diverges from Oliv's `thai_format.py` in three places (see
//! KNOWN_DIFFS.md): a digit glued onto the word before a numeral run is split
//! off, a bare power word stays a word before a few verbs and adjectives
//! (`แสนสวย`, `ร้อยเรียง`, `พันแผล`, `ร้อยละ`), and `<cls><cls>ละ` is not
//! collapsed.

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
const DIGIT_WORDS: [&str; 9] = ["หนึ่ง", "สอง", "สาม", "สี่", "ห้า", "หก", "เจ็ด", "แปด", "เก้า"];
/// The few words after which a lone power word is a word, not a number:
/// `แสน` as "very" (`แสนสวย`, `แสนดี`), `ร้อย` as "to string" or in `ร้อยละ`
/// (`ร้อยเรียง`, `ร้อยมาลัย`, `ร้อยแก้ว`, `ร้อยกรอง`) and `พัน` as "to wrap"
/// (`พันแผล`, `พันผ้า`, `พันกัน`). Anywhere else it is converted like Oliv.
const POWER_WORD_COLLOCATES: [(&str, &[&str]); 3] = [
    (
        "แสน",
        &[
            "สวย",
            "ดี",
            "แพง",
            "รู้",
            "สนุก",
            "สุข",
            "เศร้า",
            "หวาน",
            "ไกล",
            "นาน",
            "ง่าย",
            "ยาก",
            "เหนื่อย",
            "อบอุ่น",
            "จะ",
            "ห่วง",
            "เสียดาย",
            "รัก",
            "เบื่อ",
            "เก่ง",
            "ซน",
            "สั้น",
            "ยาว",
            "ธรรมดา",
            "วิเศษ",
            "สาหัส",
            "สบาย",
            "อร่อย",
            "น่ารัก",
            "ลำบาก",
            "กล",
            "งอน",
            "แสบ",
        ],
    ),
    ("ร้อย", &["ละ", "เรียง", "มาลัย", "แก้ว", "กรอง", "รัด"]),
    ("พัน", &["แผล", "ผ้า", "กัน"]),
];
/// Distributive marker: `งวด งวดละ` loses its space in normalize_thai_spacing.
const LA: &str = "ละ";
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
        let distributive = j < n && tokens[j] == LA;
        if j - i >= 2
            && !distributive
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

/// newmm glues a digit onto the word before a numeral run (`ที่สี่` `หมื่น`), and
/// words_to_num then reads the leading power word as 1 (`สี่15000`). Split the
/// digit off when it parses together with the run, so `ตีห้า` `สี่สิบ` stays.
fn split_glued_digit(tokens: Vec<String>) -> Vec<String> {
    let is_num: Vec<bool> = tokens.iter().map(|t| numeral_value(t).is_some()).collect();
    let mut out = Vec::with_capacity(tokens.len());
    for (i, tok) in tokens.iter().enumerate() {
        if !is_num[i] && is_num.get(i + 1) == Some(&true) {
            let split = DIGIT_WORDS.iter().find_map(|d| {
                let prefix = tok.strip_suffix(d)?;
                (!prefix.is_empty() && is_thai_word(prefix)).then_some((prefix, *d))
            });
            if let Some((prefix, digit)) = split {
                let end = (i + 1..tokens.len())
                    .find(|&k| !is_num[k])
                    .unwrap_or(tokens.len());
                if num(&(digit.to_string() + &tokens[i + 1..end].concat())).is_some() {
                    out.push(prefix.to_string());
                    out.push(digit.to_string());
                    continue;
                }
            }
        }
        out.push(tok.clone());
    }
    out
}

/// A lone power word is a number (`แสนบาท`, `ขายได้ร้อยครับ`, `ทีล้าน`) unless
/// the next word makes it a verb or an adverb ([`POWER_WORD_COLLOCATES`]).
fn is_word_power_word(run: &[String], rest: &[String]) -> bool {
    let [word] = run else {
        return false;
    };
    let Some(next) = rest.iter().find(|t| !t.trim().is_empty()) else {
        return false;
    };
    POWER_WORD_COLLOCATES
        .iter()
        .any(|(w, after)| w == word && after.contains(&next.as_str()))
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
        } else if is_word_power_word(run, &tokens[end..]) {
            out.extend_from_slice(run);
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
    let (tokens, n_num) = convert_numbers(split_glued_digit(tokens));
    (tokens.concat(), n_redup + n_num)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fmt(text: &str) -> String {
        apply_thai_format(text).0
    }

    #[test]
    fn glued_digit_is_split_off_the_word_before() {
        assert_eq!(fmt("อยู่ที่สี่หมื่นห้าพันบาท"), "อยู่ที่45000บาท");
        assert_eq!(fmt("อยู่ที่หนึ่งล้านสองแสนบาท"), "อยู่ที่1200000บาท");
    }

    #[test]
    fn glued_digit_stays_when_it_does_not_parse_with_the_run() {
        // same as Oliv
        assert_eq!(fmt("ตีห้าสี่สิบ"), "ตีห้า40");
    }

    #[test]
    fn bare_power_word_stays_a_word_before_its_collocates() {
        for s in [
            "แสนสวย",
            "ราคาแสนแพง",
            "เป็นคนแสนดี",
            "พันแผลก่อน",
            "พันผ้าไว้",
            "ร้อยเรียงเรื่อง",
            "ร้อยมาลัย",
            "ร้อยละห้า",
        ] {
            assert_eq!(fmt(s), s, "{s}");
        }
    }

    #[test]
    fn bare_power_word_is_a_number_everywhere_else() {
        for (s, want) in [
            ("แสนบาท", "100000บาท"),
            ("ร้อยเปอร์เซ็นต์", "100เปอร์เซ็นต์"),
            ("ขายรถได้พันคัน", "ขายรถได้1000คัน"),
            ("ราคาร้อยดอลลาร์", "ราคา100ดอลลาร์"),
            ("พิมพ์หมื่นเล่ม", "พิมพ์10000เล่ม"),
            ("ขายได้ร้อย", "ขายได้100"),
            ("ขายได้ร้อย ms", "ขายได้100 ms"),
            ("มีร้อยกว่าชิ้น", "มี100กว่าชิ้น"),
            ("ได้คนละร้อย", "ได้คนละ100"),
            ("เร็วขึ้นร้อยเท่า", "เร็วขึ้น100เท่า"),
            // before a particle, an adverb or a noun missing from any unit list
            ("ขายได้ร้อยครับ", "ขายได้100ครับ"),
            ("ต้องจ่ายหมื่นครับ", "ต้องจ่าย10000ครับ"),
            ("ได้แสนแล้ว", "ได้100000แล้ว"),
            ("ราคาร้อยนะ", "ราคา100นะ"),
            ("ได้ล้านเลย", "ได้1000000เลย"),
            ("จ่ายร้อยถ้วน", "จ่าย100ถ้วน"),
            ("ได้หมื่นวิว", "ได้10000วิว"),
            ("ข้อมูลล้านแถว", "ข้อมูล1000000แถว"),
            ("ดิสก์พันกิ๊ก", "ดิสก์1000กิ๊ก"),
            ("ให้คะแนนร้อยเต็มร้อย", "ให้คะแนน100เต็ม100"),
            // after a classifier, a room or a month, as in Oliv
            ("ค่าห้องพัน", "ค่าห้อง1000"),
            ("ค่าเช่าห้องหมื่น", "ค่าเช่าห้อง10000"),
            ("ซื้อเสื้อตัวร้อย", "ซื้อเสื้อตัว100"),
            ("ค่า API ต่อเดือนพัน", "ค่า API ต่อเดือน1000"),
            ("ไม่ต้องกดเองทีล้าน", "ไม่ต้องกดเองที1000000"),
        ] {
            assert_eq!(fmt(s), want, "{s}");
        }
    }

    #[test]
    fn distributive_pair_is_not_collapsed() {
        assert_eq!(fmt("สามงวดงวดละ"), "สามงวดงวดละ");
        assert_eq!(fmt("ดีดี"), "ดีๆ");
    }
}
