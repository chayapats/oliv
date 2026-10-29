//! Word lists from pythainlp 5.3.4 (`server/data/`), loaded once.

use std::collections::HashSet;
use std::sync::LazyLock;

use crate::trie::Trie;

const WORDS_TH: &str = include_str!("../data/words_th.txt");
const STOPWORDS_TH: &str = include_str!("../data/stopwords_th.txt");

/// Lines of a pythainlp corpus file: UTF-8 (BOM dropped), split on newlines,
/// blank lines dropped, no strip.
fn corpus_lines(s: &str) -> impl Iterator<Item = &str> {
    s.strip_prefix('\u{feff}')
        .unwrap_or(s)
        .lines()
        .filter(|l| !l.is_empty())
}

/// `thai_words()`: the newmm dictionary and the real-word set in one.
pub static THAI_WORDS: LazyLock<Trie> = LazyLock::new(|| Trie::new(corpus_lines(WORDS_TH)));

/// `thai_stopwords()`.
pub static THAI_STOPWORDS: LazyLock<HashSet<&'static str>> =
    LazyLock::new(|| corpus_lines(STOPWORDS_TH).collect());

pub fn is_thai_word(w: &str) -> bool {
    THAI_WORDS.contains(w)
}
