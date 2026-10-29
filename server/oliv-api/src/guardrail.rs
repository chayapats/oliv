//! `pipeline._guardrail` and its checks: sanitize the LLM generation, falling back
//! to the post-dictionary text on anything suspicious.

use std::collections::HashSet;
use std::sync::LazyLock;

use num_bigint::BigInt;
use regex::Match;

use crate::data::is_thai_word;
use crate::dictionary::CANONICAL_CASE;
use crate::gate::{LATIN_SPAN_RE, SPOKEN_NUMBER_WORDS, latin_spans};
use crate::metrics;
use crate::phonetic::{fold, norm_dist, thai_fold};
use crate::pyu::{has_thai, lower, remove_ws, strip};
use crate::spacing::is_thai_mark;
use crate::tokenize::word_tokenize;
use crate::wordtonum::thaiword_to_num;

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

/// A dict span this short must survive as a whole Latin token, not as letters
/// inside another word (`PR` is not kept by `app proof`). A lowercase one may
/// also grow into a word it starts (`env` -> `environment`).
const SHORT_SPAN_MAX: usize = 3;
/// A misspelled span at least this long may be fixed within `len / 5` edits.
const LONG_SPAN_MIN: usize = 8;
/// Most adjacent dict spans the LLM may merge into one word (`Elastic Sir Ch`).
const MERGE_MAX_SPANS: usize = 4;
/// A merged span at least this long may also be fixed within `len / 5` edits.
const MERGE_FUZZY_MIN: usize = 6;

const DIGIT_WORDS: [&str; 10] = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
];

/// Same first char and within `max(1, len / 5)` edits of a candidate span.
fn near_spelling(span: &[char], cand_span_chars: &[Vec<char>]) -> bool {
    let tol = (span.len() / 5).max(1);
    cand_span_chars
        .iter()
        .any(|t| t.first() == span.first() && edit_distance(span, t) <= tol)
}

/// A short span kept by the candidate: equal to a Latin token or one of its
/// joined parts (`CI/CD`), plus digits or a plural `s` (`S3`, `PRs`), or the
/// tail of a longer one (`GraphQL`, `CircleCI`).
fn survives_as_token(span: &str, cand_spans: &[&str]) -> bool {
    cand_spans.iter().any(|t| {
        t.split(['/', '.', '_', '+', '-']).any(|p| p == span)
            || t.strip_prefix(span)
                .is_some_and(|rest| rest.chars().all(|c| c.is_ascii_digit() || c == 's'))
            || t.ends_with(span)
    })
}

/// All ASCII capitals (`PR`, `UI`): spelled out, so never shorthand for a word.
fn is_acronym(span: &str) -> bool {
    span.chars().all(|c| c.is_ascii_uppercase())
}

/// An acronym the LLM grew into the loanword it starts (`AI อ็อปส์` -> `AIOps`,
/// `ML โฟลว์` -> `MLflow`, `PG บาวน์เซอร์` -> `PgBouncer`, `SQLite`, `CICD`):
/// a candidate word that starts with the acronym in its own case, or goes on
/// with a capital after its letters. A word that merely starts with the
/// letters in lowercase (`PR` -> `proof`, `Proof`) is no growth.
fn grown_acronym(span: &str, cand_cased: &[&str]) -> bool {
    let sl = lower(span);
    cand_cased.iter().any(|t| {
        t.len() > span.len()
            && (t.starts_with(span)
                || (lower(t).starts_with(&sl)
                    && t[span.len()..].starts_with(|c: char| c.is_ascii_uppercase())))
    })
}

/// For each dict span, whether a window of space-separated spans it belongs to
/// was merged by the LLM into one candidate span (`Elastic Sir Ch` ->
/// `Elasticsearch`, `font end` -> `frontend`, `My SQL` -> `MySQL`).
fn merged_spans(
    dict_text: &str,
    spans: &[Match],
    cand_spans: &[&str],
    cand_span_chars: &[Vec<char>],
) -> Vec<bool> {
    let mut merged = vec![false; spans.len()];
    for a in 0..spans.len() {
        let mut joined = lower(spans[a].as_str());
        for b in a + 1..spans.len().min(a + MERGE_MAX_SPANS) {
            if !dict_text[spans[b - 1].end()..spans[b].start()]
                .chars()
                .all(|c| c == ' ')
            {
                break;
            }
            joined.push_str(&lower(spans[b].as_str()));
            let jc = chars(&joined);
            if cand_spans.contains(&joined.as_str())
                || (jc.len() >= MERGE_FUZZY_MIN && near_spelling(&jc, cand_span_chars))
            {
                merged[a..=b].fill(true);
            }
        }
    }
    merged
}

/// Latin spans in `dict_text` that fail to survive into the candidate.
///
/// Looser than Oliv where the LLM rightly rewrote a span (merged, respelled,
/// digit for a digit word, a crumb glued into a Thai syllable) and stricter for
/// short spans (KNOWN_DIFFS.md §11).
pub fn lost_spans(dict_text: &str, cand: &str, allow_asr_repair: bool) -> Vec<String> {
    let cand_low = lower(cand);
    let cand_nows = remove_ws(&cand_low);
    let cand_spans = latin_spans(&cand_low);
    let cand_cased = latin_spans(cand);
    let cand_span_chars: Vec<Vec<char>> = cand_spans.iter().map(|t| chars(t)).collect();
    let spans: Vec<Match> = LATIN_SPAN_RE.find_iter(dict_text).collect();
    let merged = merged_spans(dict_text, &spans, &cand_spans, &cand_span_chars);
    let mut lost = Vec::new();
    for (m, merged) in spans.iter().zip(merged) {
        // Letters glued before a Thai mark (`โปรเจกtnี้`) are a corrupted syllable.
        let in_syllable = dict_text[m.end()..]
            .chars()
            .next()
            .is_some_and(is_thai_mark);
        if merged || in_syllable {
            continue;
        }
        let s = m.as_str();
        let sl = lower(s);
        let slc = chars(&sl);
        let survives = if slc.len() <= SHORT_SPAN_MAX {
            survives_as_token(&sl, &cand_spans)
                || if is_acronym(s) {
                    grown_acronym(s, &cand_cased)
                } else {
                    cand_spans.iter().any(|t| t.starts_with(sl.as_str()))
                }
        } else {
            cand_nows.contains(&sl)
        };
        if survives {
            continue;
        }
        if slc.len() >= 4 && cand_span_chars.iter().any(|t| within_one_edit(&slc, t)) {
            continue;
        }
        if slc.len() >= LONG_SPAN_MIN && near_spelling(&slc, &cand_span_chars) {
            continue;
        }
        if let Some(d) = DIGIT_WORDS.iter().position(|w| *w == sl)
            && cand_nows.contains(char::from(b'0' + d as u8))
        {
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
/// Shortest added Latin span that may stand in for a lost Thai loanword.
const LOAN_SPAN_MIN: usize = 3;
/// A lost Thai word whose fold is this close to an added Latin span's was
/// restored to English (`ฟังก์ชัน` -> `function`), not lost.
const LOAN_FOLD_MAX: f64 = 0.45;

fn real_thai_words(text: &str) -> Vec<String> {
    word_tokenize(text, false)
        .into_iter()
        .filter(|t| has_thai(t) && is_thai_word(t))
        .collect()
}

/// `(lost_long_content, invented_content)` between dict_text and candidate.
///
/// Unlike Oliv, a Thai loanword the candidate replaced with a sound-alike Latin
/// span it added is not lost (KNOWN_DIFFS.md §12).
pub fn thai_divergence(dict_text: &str, cand: &str) -> (usize, usize) {
    let cand_nows = remove_ws(cand);
    let dict_low = lower(dict_text);
    let added: Vec<String> = latin_spans(cand)
        .into_iter()
        .filter(|s| s.chars().count() >= LOAN_SPAN_MIN && !dict_low.contains(&lower(s)))
        .map(fold)
        .collect();
    let restored = |w: &str| {
        let wf = thai_fold(w);
        added.iter().any(|f| norm_dist(&wf, f) <= LOAN_FOLD_MAX)
    };
    let lost = real_thai_words(dict_text)
        .iter()
        .filter(|t| {
            t.chars().count() >= R2_MIN_WORD_LEN && !cand_nows.contains(t.as_str()) && !restored(t)
        })
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

const ENGLISH_NUMBER_WORDS: [&str; 30] = [
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen",
    "twenty",
    "thirty",
    "forty",
    "fifty",
    "sixty",
    "seventy",
    "eighty",
    "ninety",
    "hundred",
    "thousand",
    "million",
];

/// A spoken Thai number token, also a compound newmm keeps whole (`หนึ่งร้อย`).
fn is_thai_number(t: &str) -> bool {
    SPOKEN_NUMBER_WORDS.contains(&t) || (!t.starts_with("ลบ") && thaiword_to_num(t).is_ok())
}

/// The value of each Thai number token in `text` and of each digit string
/// (`2`, `1,000`).
fn number_values(tokens: &[String], text: &str) -> HashSet<BigInt> {
    let thai = tokens
        .iter()
        .filter(|t| is_thai_number(t))
        .filter_map(|t| thaiword_to_num(t).ok());
    let digits = text
        .split(|c: char| !c.is_ascii_digit() && c != ',')
        .filter_map(|d| d.replace(',', "").parse().ok());
    thai.chain(digits).collect()
}

/// English number words the candidate added where a Thai number in dict_text
/// is gone from it (`สี่สิบ` -> `forty`): a translation, not a restored loanword.
/// A Thai number the candidate kept as a word or wrote as digits explains no
/// English one, so `สองคนวันทูวัน` -> `สองคน one-to-one` and `น้องสองคน
/// วันออนวัน` -> `one-on-one น้อง 2 คน` pass. Kept means a whole word: `ห้า`
/// is not kept by `ห้าม`, nor `สาม` by `สามารถ`.
pub fn translated_numbers(dict_text: &str, cand: &str) -> Vec<String> {
    let cand_tokens = word_tokenize(cand, false);
    let kept_values = number_values(&cand_tokens, cand);
    let gone = word_tokenize(dict_text, false).into_iter().any(|t| {
        is_thai_number(&t)
            && !cand_tokens.contains(&t)
            && thaiword_to_num(&t).map_or(true, |v| !kept_values.contains(&v))
    });
    if !gone {
        return Vec::new();
    }
    let have: HashSet<String> = latin_words(dict_text).collect();
    latin_words(cand)
        .filter(|w| ENGLISH_NUMBER_WORDS.contains(&w.as_str()) && !have.contains(w))
        .collect()
}

/// Lowercase Latin words, spans split at their joiners (`forty-two`).
fn latin_words(text: &str) -> impl Iterator<Item = String> + '_ {
    latin_spans(text)
        .into_iter()
        .flat_map(|s| s.split(['/', '.', '_', '+', '-']))
        .map(lower)
}

/// Thai, ASCII and the Latin blocks (Latin-1 to Extended-B, Extended Additional).
fn is_expected_script(c: char) -> bool {
    matches!(c, '\0'..='\u{024f}' | '\u{0e00}'..='\u{0e7f}' | '\u{1e00}'..='\u{1eff}')
}

/// The LLM wrote letters in another script (`स्कीมา`). Detect only: stripping
/// or falling back to dict_text both scored worse on the eval.
fn introduces_script(c: &str) -> bool {
    c.chars()
        .any(|ch| ch.is_alphabetic() && !is_expected_script(ch))
}

/// Accepted-candidate flag when it [`introduces_script`]; the API log shows it.
pub const SCRIPT_FLAG: &str = "ok+script";

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
    if !invented_translation_gloss(dict_text, &c).is_empty()
        || !translated_numbers(dict_text, &c).is_empty()
    {
        return fallback("translate->dict");
    }
    let flag = if introduces_script(&c) {
        SCRIPT_FLAG
    } else {
        "ok"
    };
    (c, flag)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lost_spans_accepts_rewrites_and_needs_short_spans_whole() {
        let cases: [(&str, &str, &[&str]); 16] = [
            (
                "อัปเกรด cluster จาก Mongo DB ไป Dynamo DB แล้วเช็กคอนฟิกไฟล์",
                "upgrade cluster จาก MongoDB ไป DynamoDB แล้วเช็ก config file",
                &[],
            ),
            (
                "ช่วยเช็ก PR อันนี้แล้วกดแอปพรูฟด้วย",
                "ช่วยเช็ก โปรอันนี้แล้วกด app proof ด้วย",
                &["PR"],
            ),
            (
                "ช่วยเช็ก PR อันนี้แล้วกดแอปพรูฟด้วย",
                "ช่วยเช็ก PR อันนี้แล้วกด approve ด้วย",
                &[],
            ),
            (
                "ทำ dashboard ใหม่ด้วยรีแอคและดึงข้อมูลผ่านกราฟ QL แทนโซปเดิม",
                "ทำ dashboard ใหม่ด้วย React และดึงข้อมูลผ่าน GraphQL แทน SOAP เดิม",
                &[],
            ),
            (
                "ส่ง log ไป Elastic Sir Ch แล้วอัปเดต Index Pattern",
                "ส่ง log ไป Elasticsearch แล้วอัปเดต Index Pattern",
                &[],
            ),
            ("รัน C I ผ่าน Circle C I", "run CI ผ่าน CircleCI", &[]),
            (
                "หน้า checkout โหลดเสร็จใน สามร้อยสี่สิบ มิลลิวินาที",
                "หน้า checkout โหลดเสร็จใน three hundred forty milliseconds",
                &[],
            ),
            (
                "ดีบาวซ์ อีเวนต์นี้ก่อนแล้วค่อยรีเฟรช สเตท ของฟอร์มทุกครั้ง",
                "debounce event นี้ก่อนแล้วค่อย refresh state ของ form ทุกครั้ง",
                &[],
            ),
            (
                "laptop เครื่องนี้มี LAM แปดกิกาไบต์ และ SSD หนึ่ง Tera",
                "laptop เครื่องนี้มี RAM แปดกิกาไบต์ และ SSD หนึ่ง Tera",
                &["LAM"],
            ),
            (
                "เอลลิส ลิลลี่ อามิลิส ลดเวลาโหลดได้ ประมาณสามสิบเปอร์เซ็นต์",
                "Ellis, Lily, Amilis, load time can be reduced by about thirty percent",
                &[],
            ),
            ("ระบบ True Put ต่ำ", "ระบบ Trueput ต่ำ", &[]),
            ("แก้ font end ก่อน", "แก้ frontend ก่อน", &[]),
            ("เปิด Observableility ไว้", "เปิด Observability ไว้", &[]),
            ("ใช้ S three กับ R two", "ใช้ S3 กับ R2", &[]),
            ("ดูแลโปรเจกtnี้", "ดูแล project นี้", &[]),
            ("แก้ UI กับ CI ใน PR", "แก้ build กับ CI/CD ใน PRs", &["UI"]),
        ];
        for (dict, cand, want) in cases {
            assert_eq!(lost_spans(dict, cand, false), want, "{dict} -> {cand}");
        }
    }

    #[test]
    fn short_lowercase_spans_may_grow_into_the_word() {
        let cases: [(&str, &str, &[&str]); 7] = [
            ("เขียนด้วย go ทั้งหมด", "เขียนด้วย Golang ทั้งหมด", &[]),
            ("ตั้งค่า env ก่อน deploy", "ตั้งค่า environment ก่อน deploy", &[]),
            ("เปิด app แล้ว login", "เปิด application แล้ว login", &[]),
            // Only a word the span starts, not one it sits inside.
            ("ช่วยรีวิว pr ตัวนี้", "ช่วย review approve ตัวนี้", &["pr"]),
            // Acronyms stay strict.
            ("ช่วยรีวิว PR ตัวนี้", "ช่วย review proof ตัวนี้", &["PR"]),
            ("ช่วยรีวิว PR ตัวนี้", "ช่วย review Proof ตัวนี้", &["PR"]),
            ("แก้ UI ก่อน", "แก้ build ก่อน", &["UI"]),
        ];
        for (dict, cand, want) in cases {
            assert_eq!(lost_spans(dict, cand, false), want, "{dict} -> {cand}");
        }
        let dict = "ตั้งค่า env ก่อน deploy";
        let cand = "ตั้งค่า environment ก่อน deploy";
        assert_eq!(guardrail(dict, cand), (cand.to_string(), "ok"));
    }

    #[test]
    fn acronyms_may_grow_into_the_loanword_they_start() {
        let cases: [(&str, &str, &[&str]); 8] = [
            ("ทีมทำ AI อ็อปส์ อยู่", "ทีมทำ AIOps อยู่", &[]),
            ("ใช้ ML โฟลว์ track", "ใช้ MLflow track", &[]),
            ("ต่อ PG บาวน์เซอร์ ก่อน", "ต่อ PgBouncer ก่อน", &[]),
            ("เก็บใน SQL ไลท์", "เก็บใน SQLite", &[]),
            ("เขียน JS เอ็กซ์", "เขียน JSX", &[]),
            ("ตั้ง CI ซีดี", "ตั้ง CICD", &[]),
            ("ใช้ VS โค้ด", "ใช้ VSCode", &[]),
            ("ช่วยเช็ก PR อันนี้แล้วกดแอปพรูฟ", "ช่วยเช็ก app proof", &["PR"]),
        ];
        for (dict, cand, want) in cases {
            assert_eq!(lost_spans(dict, cand, false), want, "{dict} -> {cand}");
        }
        for (dict, cand) in [
            ("ทีมทำ AI อ็อปส์ อยู่", "ทีมทำ AIOps อยู่"),
            ("ใช้ ML โฟลว์ track", "ใช้ MLflow track"),
            ("ต่อ PG บาวน์เซอร์ ก่อน", "ต่อ PgBouncer ก่อน"),
        ] {
            assert_eq!(guardrail(dict, cand), (cand.to_string(), "ok"), "{dict}");
        }
    }

    #[test]
    fn thai_divergence_excuses_loanwords_restored_to_english() {
        let cases = [
            (
                "ดีบาวซ์ อีเวนต์นี้ก่อนแล้วค่อยรีเฟรช สเตท ของฟอร์มทุกครั้ง",
                "debounce event นี้ก่อนแล้วค่อย refresh state ของ form ทุกครั้ง",
                (0, 0),
            ),
            (
                "เทสต์ model ด้วยเทนเซอร์โฟลว์แล้วดีพลอยผ่านดอกเกอร์",
                "test model ด้วย TensorFlow แล้ว deploy ผ่าน Docker",
                (1, 0),
            ),
            // A translation's English words do not sound like the Thai ones.
            (
                "พรุ่งนี้ประชุมเรื่องงบประมาณกับลูกค้าตอนบ่าย",
                "tomorrow meeting about budget with customer in the afternoon",
                (6, 0),
            ),
            // Only Latin spans the candidate added can stand in for a Thai word.
            ("ส่งฟังก์ชัน function นี้", "ส่ง function นี้", (1, 0)),
        ];
        for (dict, cand, want) in cases {
            assert_eq!(thai_divergence(dict, cand), want, "{dict} -> {cand}");
        }
        assert_eq!(
            guardrail(
                "ดีบาวซ์ อีเวนต์นี้ก่อนแล้วค่อยรีเฟรช สเตท ของฟอร์มทุกครั้ง",
                "debounce event นี้ก่อนแล้วค่อย refresh state ของ form ทุกครั้ง"
            ),
            (
                "debounce event นี้ก่อนแล้วค่อย refresh state ของ form ทุกครั้ง".to_string(),
                "ok"
            )
        );
    }

    #[test]
    fn translated_numbers_need_a_thai_number() {
        let cases: [(&str, &str, &[&str]); 13] = [
            (
                "หน้า checkout โหลดเสร็จใน สามร้อยสี่สิบ มิลลิวินาที",
                "หน้า checkout โหลดเสร็จใน three hundred forty milliseconds",
                &["three", "hundred", "forty"],
            ),
            (
                "ลดเวลาโหลดได้ ประมาณสามสิบเปอร์เซ็นต์",
                "load time can be reduced by about thirty-two percent",
                &["thirty", "two"],
            ),
            ("เปิดพอร์ตเอทตี้", "เปิด port eighty", &[]),
            ("ใช้ two factor สองชั้น", "ใช้ two factor สองชั้น", &[]),
            ("ลบไฟล์ทิ้ง", "ลบ file one ทิ้ง", &[]),
            // The Thai number is kept, so the English one is a restored loanword.
            ("คุยกันสองคนแบบวันทูวัน", "คุยกันสองคนแบบ one-to-one", &[]),
            ("ใช้ทูเฟสคอมมิตสามรอบ", "ใช้ two-phase commit สามรอบ", &[]),
            (
                "ประชุมสามคนแบบวันออนวัน",
                "meeting three people one-on-one",
                &["three", "one", "one"],
            ),
            // A Thai number written as digits is kept too.
            ("ทำวันออนวันกับน้องสองคน", "ทำ one-on-one กับน้อง 2 คน", &[]),
            ("ดู ท็อปเท็น ลิสต์ สามอัน", "ดู top ten list 3 อัน", &[]),
            // Only a whole word keeps it: `ห้าม` holds no `ห้า`, `สามารถ` no `สาม`.
            ("ห้ามใช้ห้าเครื่อง", "ห้ามใช้ five machines", &["five"]),
            (
                "ทีมมีสามคน สามารถทำเสร็จได้",
                "team has three people สามารถทำเสร็จได้",
                &["three"],
            ),
            ("ใช้ห้าเครื่อง", "ใช้ five machines", &["five"]),
        ];
        for (dict, cand, want) in cases {
            assert_eq!(translated_numbers(dict, cand), want, "{dict} -> {cand}");
        }
        for (dict, cand) in [
            ("คุยกันสองคนแบบวันทูวัน", "คุยกันสองคนแบบ one-to-one"),
            ("ทำวันออนวันกับน้องสองคน", "ทำ one-on-one กับน้อง 2 คน"),
            ("ดู ท็อปเท็น ลิสต์ สามอัน", "ดู top ten list 3 อัน"),
            ("ใช้วินโดวส์เท็นอยู่ สองเครื่อง", "ใช้ Windows ten อยู่ 2 เครื่อง"),
        ] {
            assert_eq!(guardrail(dict, cand), (cand.to_string(), "ok"), "{dict}");
        }
        for (dict, cand) in [
            ("ห้ามใช้ห้าเครื่อง", "ห้ามใช้ five machines"),
            (
                "ทีมมีสามคน สามารถทำเสร็จได้",
                "team has three people สามารถทำเสร็จได้",
            ),
        ] {
            assert_eq!(guardrail(dict, cand), (dict.to_string(), "translate->dict"));
        }
        let dict = "เอลลิส ลิลลี่ อามิลิส ลดเวลาโหลดได้ ประมาณสามสิบเปอร์เซ็นต์";
        let cand = "Ellis, Lily, Amilis, load time can be reduced by about thirty percent";
        assert_eq!(guardrail(dict, cand), (dict.to_string(), "translate->dict"));
    }

    #[test]
    fn script_the_llm_introduces_is_flagged_not_stripped() {
        for (t, want) in [
            ("update สคริปต์ แล้ว restart service", false),
            ("update the résumé at the café ครับ", false),
            ("Branch này merge xong rồi", false),
            ("update स्क्रिปต์และ restart", true),
            ("рейт limit", true),
            ("ส่ง API 文档", true),
            ("pipeline นี้ผ่าน اللي แล้ว", true),
        ] {
            assert_eq!(introduces_script(t), want, "{t}");
        }
        let dict = "update สคริปต์และรีสตาร์ทเซอร์วิสใหม่ทั้งหมด";
        let cand = "update स्क्रिปต์และรี restart เซอร์วิสใหม่ทั้งหมด";
        assert_eq!(guardrail(dict, cand), (cand.to_string(), SCRIPT_FLAG));
    }
}
