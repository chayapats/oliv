//! `pipeline._gate` and its signals: decide whether the LLM pass is worth running.

use std::sync::LazyLock;

use regex::Regex;

use crate::data::is_thai_word;
use crate::pyu::{has_thai, is_alpha, is_blank, is_thai};
use crate::tokenize::word_tokenize;

/// `_LATIN_SPAN_RE`: a Latin run with ASCII joiners (`A/B`, `p99`, `CI/CD`).
pub static LATIN_SPAN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z][A-Za-z0-9]*(?:[/._+-][A-Za-z0-9]+)*").unwrap());

pub fn latin_spans(text: &str) -> Vec<&str> {
    LATIN_SPAN_RE.find_iter(text).map(|m| m.as_str()).collect()
}

const LOAN_RUN_MIN_CHARS: usize = 10;
const LOAN_RUN_MIN_TOKS: usize = 3;
const LOAN_SHORT_MAX: usize = 4;
const LOAN_LONG_CONTENT_MIN: usize = 6;

const SPOKEN_NUMBER_WORDS: [&str; 18] = [
    "ศูนย์",
    "หนึ่ง",
    "เอ็ด",
    "สอง",
    "สาม",
    "สี่",
    "ห้า",
    "หก",
    "เจ็ด",
    "แปด",
    "เก้า",
    "สิบ",
    "ยี่สิบ",
    "ร้อย",
    "พัน",
    "หมื่น",
    "แสน",
    "ล้าน",
];

const THAI_FUNCTION_WORDS: [&str; 40] = [
    "ใน",
    "ที่",
    "ของ",
    "และ",
    "กับ",
    "ให้",
    "ไป",
    "มา",
    "แล้ว",
    "ก็",
    "จะ",
    "ไม่",
    "ได้",
    "เป็น",
    "อยู่",
    "นี้",
    "นั้น",
    "หน่อย",
    "ไหม",
    "ครับ",
    "ค่ะ",
    "นะ",
    "เลย",
    "ด้วย",
    "จาก",
    "ถึง",
    "บน",
    "ลง",
    "ขึ้น",
    "หรือ",
    "แต่",
    "ถ้า",
    "เมื่อ",
    "ยัง",
    "แค่",
    "อีก",
    "ว่า",
    "เพื่อ",
    "โดย",
    "ตาม",
];

/// newmm tokens that contain Thai characters but are not real Thai words.
pub fn suspicious_tokens(text: &str) -> Vec<String> {
    word_tokenize(text, false)
        .into_iter()
        .filter(|t| !is_blank(t) && has_thai(t) && !is_thai_word(t))
        .collect()
}

fn is_loan_compound_run(run: &str) -> bool {
    if run.chars().count() < LOAN_RUN_MIN_CHARS {
        return false;
    }
    let toks: Vec<String> = word_tokenize(run, false)
        .into_iter()
        .filter(|t| !is_blank(t) && has_thai(t))
        .collect();
    if toks.len() < LOAN_RUN_MIN_TOKS {
        return false;
    }
    let is_num = |t: &str| SPOKEN_NUMBER_WORDS.contains(&t);
    let is_func = |t: &str| THAI_FUNCTION_WORDS.contains(&t);
    let len = |t: &str| t.chars().count();
    if toks.iter().filter(|t| is_num(t)).count() >= 3 {
        return false;
    }
    let long_content = toks
        .iter()
        .filter(|t| is_thai_word(t) && len(t) >= LOAN_LONG_CONTENT_MIN)
        .count();
    let short_real = toks
        .iter()
        .filter(|t| is_thai_word(t) && len(t) <= LOAN_SHORT_MAX && !is_func(t) && !is_num(t))
        .count();
    let shreds = toks.iter().filter(|t| len(t) <= 2 && !is_func(t)).count();
    long_content == 0 && short_real >= 2 && shreds >= 1
}

/// Maximal Thai runs that look like transliterated English loan compounds.
pub fn loan_compound_runs(text: &str) -> Vec<String> {
    let mut runs = Vec::new();
    let mut cur = String::new();
    for c in text.chars().chain(std::iter::once('\0')) {
        if is_thai(c) {
            cur.push(c);
        } else if !cur.is_empty() {
            if is_loan_compound_run(&cur) {
                runs.push(cur.clone());
            }
            cur.clear();
        }
    }
    runs
}

/// Single-letter Latin spans amid Thai (ASR crumbs).
pub fn latin_crumbs(text: &str) -> Vec<String> {
    latin_spans(text)
        .into_iter()
        .filter(|s| s.chars().count() == 1 && s.chars().all(is_alpha))
        .map(str::to_string)
        .collect()
}

/// `(run_llm, gate_reason, suspect_tokens)` for the post-dictionary text.
pub fn gate(dict_text: &str, dict_hits: usize) -> (bool, String, Vec<String>) {
    if !has_thai(dict_text) {
        return (false, "no-thai".into(), Vec::new());
    }
    let susp = suspicious_tokens(dict_text);
    let loans = loan_compound_runs(dict_text);
    let crumbs = latin_crumbs(dict_text);
    if dict_hits == 0 && susp.is_empty() && loans.is_empty() && crumbs.is_empty() {
        return (false, "clean-thai".into(), susp);
    }
    let mut reasons = Vec::new();
    if dict_hits > 0 {
        reasons.push("dict-hit");
    }
    if !susp.is_empty() {
        reasons.push("suspect-tokens");
    }
    if !loans.is_empty() {
        reasons.push("loan-compound");
    }
    if !crumbs.is_empty() {
        reasons.push("latin-crumb");
    }
    (true, reasons.join("+"), susp)
}
