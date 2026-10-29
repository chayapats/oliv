//! `pipeline.normalize_thai_spacing`.

use crate::pyu::is_thai;

/// Thai non-spacing marks (above/below vowels, tone marks), which cannot start a word.
pub fn is_thai_mark(c: char) -> bool {
    matches!(c, '\u{0e31}' | '\u{0e34}'..='\u{0e3a}' | '\u{0e47}'..='\u{0e4e}')
}

/// Insert a space at every glued Thai<->ASCII-letter boundary, then drop every
/// `[ \t]+` run that sits between two Thai chars. Idempotent.
///
/// Unlike Oliv, a letter glued before a Thai mark stays glued: `โปรเจกtnี้` must
/// not leave an orphan `ี้` (KNOWN_DIFFS.md §11).
pub fn normalize_thai_spacing(text: &str) -> String {
    // _THAI_LATIN_GLUE_RE.sub(" ", text)
    let mut glued = String::with_capacity(text.len() + 8);
    let mut prev: Option<char> = None;
    for c in text.chars() {
        if let Some(p) = prev
            && ((is_thai(p) && c.is_ascii_alphabetic())
                || (p.is_ascii_alphabetic() && is_thai(c) && !is_thai_mark(c)))
        {
            glued.push(' ');
        }
        glued.push(c);
        prev = Some(c);
    }

    // _THAI_THAI_SPACE_RE.sub("", text)
    let t: Vec<char> = glued.chars().collect();
    let mut out = String::with_capacity(glued.len());
    let mut i = 0;
    while i < t.len() {
        if matches!(t[i], ' ' | '\t') {
            let mut j = i;
            while j < t.len() && matches!(t[j], ' ' | '\t') {
                j += 1;
            }
            let thai_both = i > 0 && is_thai(t[i - 1]) && j < t.len() && is_thai(t[j]);
            if !thai_both {
                out.extend(&t[i..j]);
            }
            i = j;
        } else {
            out.push(t[i]);
            i += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_space_before_a_thai_mark() {
        assert_eq!(normalize_thai_spacing("โปรเจกtnี้"), "โปรเจก tnี้");
        assert_eq!(normalize_thai_spacing("ใช้APIนี้"), "ใช้ API นี้");
        assert_eq!(normalize_thai_spacing("ok่"), "ok่");
    }
}
