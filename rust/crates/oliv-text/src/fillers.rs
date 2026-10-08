//! `sidecar_server.remove_fillers`: drop standalone filler words before cleanup.

use std::sync::LazyLock;

use crate::pyu::{collapse_blanks, is_thai, strip};

/// `_FILLERS` in the regex alternation order (`sorted(key=len, reverse=True)`, stable).
static FILLERS: LazyLock<Vec<Vec<char>>> = LazyLock::new(|| {
    let mut v: Vec<Vec<char>> = [
        // Thai
        "อืมม",
        "อืม",
        "เอ่อ",
        "เอ้อ",
        "อ่าา",
        "อ่า",
        "เอิ่ม",
        "หืม",
        // English
        "uhh",
        "erm",
        "hmm",
        "um",
        "uh",
        "er",
    ]
    .iter()
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

/// Returns `(new_text, n_removed)`; byte-identical passthrough when nothing fires.
pub fn remove_fillers(text: &str) -> (String, usize) {
    let t: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut n = 0;
    let mut i = 0;
    while i < t.len() {
        let behind_ok = i == 0 || !is_glue(t[i - 1]);
        let hit = behind_ok
            .then(|| {
                FILLERS.iter().find(|f| {
                    matches_at(&t, i, f) && t.get(i + f.len()).is_none_or(|&c| !is_glue(c))
                })
            })
            .flatten();
        match hit {
            Some(f) => {
                n += 1;
                i += f.len();
            }
            None => {
                out.push(t[i]);
                i += 1;
            }
        }
    }
    if n == 0 {
        return (text.to_string(), 0);
    }
    (strip(&collapse_blanks(&out)).to_string(), n)
}
