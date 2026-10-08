//! Python `str` semantics the port has to reproduce exactly.
//!
//! Oliv indexes and measures strings in code points and relies on Python's
//! Unicode-aware `isspace`, `\s`, `\w`, `\d`, `strip()`, `split()` and
//! `casefold()`. Rust's built-ins differ at the edges (e.g. `char::is_whitespace`
//! excludes U+001C..U+001F, regex `\w` includes Thai combining marks), so every
//! pass goes through these helpers instead.

use unicode_general_category::{GeneralCategory as G, get_general_category};

/// Python `str.isspace()` for one char (also what `re` uses for `\s`).
pub fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n'
            | '\u{0b}'
            | '\u{0c}'
            | '\r'
            | '\u{1c}'..='\u{1f}'
            | ' '
            | '\u{85}'
            | '\u{a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
    )
}

/// Python `str.isalpha()` for one char: general category L*.
pub fn is_alpha(c: char) -> bool {
    if c.is_ascii() {
        return c.is_ascii_alphabetic();
    }
    matches!(
        get_general_category(c),
        G::UppercaseLetter
            | G::LowercaseLetter
            | G::TitlecaseLetter
            | G::ModifierLetter
            | G::OtherLetter
    )
}

/// Python `re` `\d` / `str.isdecimal()`: general category Nd.
pub fn is_decimal(c: char) -> bool {
    if c.is_ascii() {
        return c.is_ascii_digit();
    }
    get_general_category(c) == G::DecimalNumber
}

/// Python `re` `\w`: alphanumeric (L* or N*) or `_`.
pub fn is_word(c: char) -> bool {
    if c.is_ascii() {
        return c.is_ascii_alphanumeric() || c == '_';
    }
    is_alpha(c)
        || matches!(
            get_general_category(c),
            G::DecimalNumber | G::LetterNumber | G::OtherNumber
        )
}

/// Thai block U+0E00..U+0E7F (Oliv's `[฀-๿]`).
pub fn is_thai(c: char) -> bool {
    ('\u{0e00}'..='\u{0e7f}').contains(&c)
}

pub fn has_thai(s: &str) -> bool {
    s.chars().any(is_thai)
}

/// Python `str.strip()`.
pub fn strip(s: &str) -> &str {
    s.trim_matches(is_space)
}

/// Python `str.strip()` is falsy.
pub fn is_blank(s: &str) -> bool {
    s.chars().all(is_space)
}

/// Python `str.split()` with no arguments.
pub fn split_ws(s: &str) -> Vec<&str> {
    s.split(is_space).filter(|p| !p.is_empty()).collect()
}

/// Python `re.sub(r"\s+", "", s)`.
pub fn remove_ws(s: &str) -> String {
    s.chars().filter(|&c| !is_space(c)).collect()
}

/// Python `re.sub(r"\s+", " ", s)`.
pub fn collapse_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_ws = false;
    for c in s.chars() {
        if is_space(c) {
            if !in_ws {
                out.push(' ');
            }
            in_ws = true;
        } else {
            out.push(c);
            in_ws = false;
        }
    }
    out
}

/// Python `re.sub(r"[ \t]{2,}", " ", s)`.
pub fn collapse_blanks(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut run = String::new();
    for c in s.chars() {
        if c == ' ' || c == '\t' {
            run.push(c);
            continue;
        }
        flush_blanks(&mut out, &mut run);
        out.push(c);
    }
    flush_blanks(&mut out, &mut run);
    out
}

fn flush_blanks(out: &mut String, run: &mut String) {
    if run.chars().count() >= 2 {
        out.push(' ');
    } else {
        out.push_str(run);
    }
    run.clear();
}

/// Python `str.lower()`.
pub fn lower(s: &str) -> String {
    s.to_lowercase()
}

/// Python `str.casefold()`.
pub fn casefold(s: &str) -> String {
    caseless::default_case_fold_str(s)
}

/// Python `str.isupper()`: at least one cased char and no lowercase/titlecase one.
pub fn is_upper(s: &str) -> bool {
    let mut cased = false;
    for c in s.chars() {
        if c.is_lowercase() || get_general_category(c) == G::TitlecaseLetter {
            return false;
        }
        if c.is_uppercase() {
            cased = true;
        }
    }
    cased
}

/// Length in code points (Python `len`).
pub fn len(s: &str) -> usize {
    s.chars().count()
}

/// Python `s.find(sub, start)` over code points; returns a code-point index.
pub fn find_chars(hay: &[char], needle: &[char], start: usize) -> Option<usize> {
    if needle.is_empty() {
        return (start <= hay.len()).then_some(start);
    }
    if needle.len() > hay.len() {
        return None;
    }
    (start..=hay.len() - needle.len()).find(|&i| hay[i..i + needle.len()] == *needle)
}

/// Python `sub in s`.
pub fn contains(hay: &str, needle: &str) -> bool {
    hay.contains(needle)
}
