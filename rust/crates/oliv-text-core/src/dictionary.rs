//! `benchmark/dictionary.py`: deterministic transliteration fixes and canonical casing.

use std::collections::HashMap;
use std::sync::LazyLock;

use crate::data::is_thai_word;
use crate::pyu::{collapse_blanks, is_space, strip};
use crate::tokenize::word_tokenize;

pub use crate::dictionary_tables::{CANONICAL_CASE, TRANSLIT};

/// newmm token spans `(start, end, token)` over the original text, in code points.
pub fn token_spans(text: &str) -> Vec<(usize, usize, String)> {
    let mut pos = 0;
    word_tokenize(text, true)
        .into_iter()
        .map(|tok| {
            let n = tok.chars().count();
            pos += n;
            (pos - n, pos, tok)
        })
        .collect()
}

/// Keys sorted longest first; ties keep table order (Python's stable sort).
fn sorted_keys<'a>(table: &[(&'a str, &'a str)]) -> Vec<(Vec<char>, &'a str)> {
    let mut keys: Vec<(Vec<char>, &str)> = table
        .iter()
        .map(|(k, v)| (k.chars().collect(), *v))
        .collect();
    keys.sort_by_key(|(k, _)| std::cmp::Reverse(k.len()));
    keys
}

static TRANSLIT_KEYS: LazyLock<Vec<(Vec<char>, &'static str)>> =
    LazyLock::new(|| sorted_keys(TRANSLIT));

/// `apply_dictionary(text)` with the built-in `TRANSLIT` table.
pub fn apply_dictionary(text: &str) -> (String, usize) {
    apply_keys(text, &TRANSLIT_KEYS)
}

/// `apply_dictionary(text, table)` with a caller-supplied table (user replacements).
pub fn apply_table(text: &str, table: &[(&str, &str)]) -> (String, usize) {
    apply_keys(text, &sorted_keys(table))
}

fn apply_keys(text: &str, keys: &[(Vec<char>, &str)]) -> (String, usize) {
    if text.is_empty() {
        return (String::new(), 0);
    }
    let spans = token_spans(text);
    let breaks_real_word = |p: usize| {
        for (s, e, tok) in &spans {
            if *s < p && p < *e {
                return is_thai_word(tok);
            }
            if *s >= p {
                break;
            }
        }
        false
    };

    let t: Vec<char> = text.chars().collect();
    let mut claimed = vec![false; t.len()];
    let mut repl: Vec<(usize, usize, &str)> = Vec::new();
    for (k, en) in keys {
        let mut start = 0;
        while let Some(i) = crate::pyu::find_chars(&t, k, start) {
            let j = i + k.len();
            start = i + 1;
            if claimed[i..j].iter().any(|&c| c) {
                continue;
            }
            if breaks_real_word(i) || breaks_real_word(j) {
                continue;
            }
            claimed[i..j].iter_mut().for_each(|c| *c = true);
            repl.push((i, j, en));
        }
    }
    if repl.is_empty() {
        return (text.to_string(), 0);
    }

    repl.sort();
    let mut out = String::with_capacity(text.len() + 16);
    let mut pos = 0;
    for &(i, j, en) in &repl {
        out.extend(&t[pos..i]);
        if out.chars().next_back().is_some_and(|c| !is_space(c)) {
            out.push(' ');
        }
        out.push_str(en);
        if j < t.len() && !is_space(t[j]) {
            out.push(' ');
        }
        pos = j;
    }
    out.extend(&t[pos..]);
    (strip(&collapse_blanks(&out)).to_string(), repl.len())
}

static CANON: LazyLock<HashMap<&'static str, &'static str>> =
    LazyLock::new(|| CANONICAL_CASE.iter().copied().collect());

/// `apply_canonical_casing`: re-case maximal `[A-Za-z][A-Za-z0-9]*` runs found in
/// `CANONICAL_CASE`.
pub fn apply_canonical_casing(text: &str) -> String {
    let t: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < t.len() {
        if !t[i].is_ascii_alphabetic() {
            out.push(t[i]);
            i += 1;
            continue;
        }
        let mut j = i + 1;
        while j < t.len() && t[j].is_ascii_alphanumeric() {
            j += 1;
        }
        let run: String = t[i..j].iter().collect();
        match CANON.get(run.to_ascii_lowercase().as_str()) {
            Some(c) => out.push_str(c),
            None => out.push_str(&run),
        }
        i = j;
    }
    out
}
