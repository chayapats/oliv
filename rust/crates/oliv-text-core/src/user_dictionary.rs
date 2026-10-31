//! The user's personal dictionary (Wispr Flow parity), shared by the Mac app
//! and the OLIV server so both apply it identically.
//!
//! An entry is either *vocabulary* (`correction == None`: bias recognition and
//! fuzzy-snap toward `word`) or a *correction* (`correction == Some(heard)`:
//! replace what was heard with exactly `word`). Build a [`UserDictionary`] once
//! per request from the raw entries, then use its passes:
//!
//! - [`UserDictionary::apply_corrections`]: literal corrections before the LLM.
//! - [`UserDictionary::apply_numerals`]: alphanumeric words spoken with Thai
//!   numerals (`SHA สองห้าหก` → `SHA256`), before and after the LLM.
//! - [`UserDictionary::apply_with_legacy`]: corrections merged with legacy
//!   `replacements` after the LLM.
//! - [`UserDictionary::lost_words`]: detects an LLM that rewrote a word the
//!   user fixed (e.g. romanized a Thai name), so the caller can fall back.
//!
//! Matching rules: longest key first, claimed spans never overlap, a match
//! that would split a real Thai word is rejected, Latin matches must sit on
//! word boundaries and ignore case, Thai matches are exact. Output is always
//! the entry's exact `word`.

use std::collections::HashSet;

use num_bigint::BigInt;

use crate::data::is_thai_word;
use crate::dictionary::{apply_table, token_spans};
use crate::pyu::{casefold, collapse_blanks, has_thai, is_space, is_thai, strip};
use crate::wordtonum::thaiword_to_num;

/// Longest accepted `word` / `correction`, in chars (Thai phrases run long).
pub const MAX_FIELD_CHARS: usize = 100;

/// One raw dictionary entry as stored or sent by a client.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub word: String,
    pub correction: Option<String>,
    pub enabled: bool,
    pub starred: bool,
}

/// The trimmed field when it is usable: non-empty, at most
/// [`MAX_FIELD_CHARS`], and carrying at least one letter or digit (Thai
/// included) rather than only punctuation or symbols.
pub fn clean_field(s: &str) -> Option<&str> {
    let t = strip(s);
    let ok = !t.is_empty()
        && t.chars().count() <= MAX_FIELD_CHARS
        && t.chars().any(|c| c.is_alphanumeric() || is_thai(c));
    ok.then_some(t)
}

/// Identity of a word for de-duplication: Latin compares case-insensitively,
/// anything containing Thai compares exactly.
pub fn dedupe_key(s: &str) -> String {
    let t = strip(s);
    if has_thai(t) {
        t.to_string()
    } else {
        casefold(t)
    }
}

/// A compiled dictionary: only enabled, valid entries, ready to apply.
#[derive(Clone, Debug, Default)]
pub struct UserDictionary {
    /// Enabled words, starred first, deduped; the STT/fuzzy vocabulary.
    vocabulary: Vec<String>,
    /// `heard → word`, longest `heard` first.
    corrections: Vec<Key>,
    /// Alphanumeric words (`SHA256`) reachable through Thai numerals.
    numerals: Vec<NumeralWord>,
}

impl UserDictionary {
    pub fn new(entries: &[Entry]) -> Self {
        let enabled = || entries.iter().filter(|e| e.enabled);

        let mut seen = HashSet::new();
        let mut vocabulary = Vec::new();
        // Starred first; within each group the user's order.
        for e in enabled()
            .filter(|e| e.starred)
            .chain(enabled().filter(|e| !e.starred))
        {
            if let Some(w) = clean_field(&e.word)
                && seen.insert(dedupe_key(w))
            {
                vocabulary.push(w.to_string());
            }
        }

        let mut seen = HashSet::new();
        let mut corrections = Vec::new();
        for e in enabled() {
            let (Some(word), Some(heard)) = (
                clean_field(&e.word),
                e.correction.as_deref().and_then(clean_field),
            ) else {
                continue;
            };
            // One target per heard phrase: the first entry wins.
            if seen.insert(dedupe_key(heard)) {
                corrections.push(Key::user(heard, word));
            }
        }
        corrections.sort_by_key(|k| std::cmp::Reverse(k.chars.len()));

        let numerals = vocabulary
            .iter()
            .filter_map(|w| NumeralWord::new(w))
            .collect();
        Self {
            vocabulary,
            corrections,
            numerals,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.vocabulary.is_empty()
    }

    /// Some enabled entry rewrites what was heard.
    pub fn has_corrections(&self) -> bool {
        !self.corrections.is_empty()
    }

    /// Some enabled word is reachable through Thai numerals (`SHA256`).
    pub fn has_numerals(&self) -> bool {
        !self.numerals.is_empty()
    }

    /// Enabled words, starred first. `initial_prompt` truncates from the end,
    /// so this order keeps starred words in the STT prompt.
    pub fn vocabulary(&self) -> &[String] {
        &self.vocabulary
    }

    /// Dictionary words first, then legacy vocabulary terms not already
    /// present. With an empty dictionary this is `legacy` unchanged.
    pub fn merged_vocabulary(&self, legacy: &[String]) -> Vec<String> {
        if self.is_empty() {
            return legacy.to_vec();
        }
        let mut seen: HashSet<String> = self.vocabulary.iter().map(|w| dedupe_key(w)).collect();
        let mut out = self.vocabulary.clone();
        for t in legacy.iter().map(|t| strip(t)) {
            if !t.is_empty() && seen.insert(dedupe_key(t)) {
                out.push(t.to_string());
            }
        }
        out
    }

    /// Literal `heard → word` corrections (the pre-LLM pass).
    pub fn apply_corrections(&self, text: &str) -> (String, usize) {
        let refs: Vec<&Key> = self.corrections.iter().collect();
        apply_keys(text, &refs)
    }

    /// Corrections merged with the legacy `replacements` table (the post-LLM
    /// pass). Longest key wins; on equal length the dictionary entry wins.
    /// Legacy keys keep their original exact, Python-parity semantics, and
    /// with an empty dictionary this is exactly `dictionary::apply_table`.
    pub fn apply_with_legacy(&self, text: &str, legacy: &[(String, String)]) -> (String, usize) {
        if self.corrections.is_empty() {
            let table: Vec<(&str, &str)> = legacy
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str()))
                .collect();
            return apply_table(text, &table);
        }
        let legacy: Vec<Key> = legacy.iter().map(|(k, v)| Key::legacy(k, v)).collect();
        let mut keys: Vec<&Key> = self.corrections.iter().chain(&legacy).collect();
        // Stable: equal lengths keep dictionary-before-legacy order.
        keys.sort_by_key(|k| std::cmp::Reverse(k.chars.len()));
        apply_keys(text, &keys)
    }

    /// The pre-LLM correction pass when a legacy `replacements` table runs
    /// after cleanup: dictionary corrections, longest key first, but a legacy
    /// key's source that is at least as long keeps its span (claimed, left
    /// unchanged) for the post pass, as one longest-match plan over both
    /// tables would. Also returns the outputs it wrote, for
    /// [`Self::apply_after_cleanup`].
    pub fn apply_corrections_before(
        &self,
        text: &str,
        legacy: &[(String, String)],
    ) -> (String, usize, Vec<String>) {
        if self.corrections.is_empty() {
            return (text.to_string(), 0, Vec::new());
        }
        let guards: Vec<Key> = legacy
            .iter()
            .filter(|(k, _)| !k.is_empty())
            .map(|(k, _)| Key::guard(k))
            .collect();
        let mut keys: Vec<&Key> = self.corrections.iter().chain(&guards).collect();
        // Stable: on equal length the dictionary entry wins, as in apply_with_legacy.
        keys.sort_by_key(|k| std::cmp::Reverse(k.chars.len()));
        apply_keys_traced(text, &keys)
    }

    /// The post-cleanup pass: corrections merged with the legacy table, one
    /// longest-match plan, except inside the exact outputs the pre-LLM pass
    /// wrote (`produced`): those are never corrected again (no `foo→bar→baz`,
    /// no `ไทย→ประเทศไทย` twice). A correction whose source overlaps one of
    /// those outputs has had its turn, so it stays out of this pass even when
    /// cleanup re-cased or re-spaced the output. Anything else the cleanup
    /// model newly produced is corrected.
    pub fn apply_after_cleanup(
        &self,
        text: &str,
        legacy: &[(String, String)],
        produced: &[String],
    ) -> (String, usize) {
        if produced.is_empty() {
            return self.apply_with_legacy(text, legacy);
        }
        let mut seen = HashSet::new();
        let mut guards: Vec<Key> = produced
            .iter()
            .filter(|p| !p.is_empty() && seen.insert(p.as_str()))
            .map(|p| Key::guard(p))
            .collect();
        guards.sort_by_key(|k| std::cmp::Reverse(k.chars.len()));
        let legacy: Vec<Key> = legacy.iter().map(|(k, v)| Key::legacy(k, v)).collect();
        let mut rest: Vec<&Key> = self
            .corrections
            .iter()
            .filter(|k| !overlaps_output(k, produced))
            .chain(&legacy)
            .collect();
        rest.sort_by_key(|k| std::cmp::Reverse(k.chars.len()));
        let keys: Vec<&Key> = guards.iter().chain(rest).collect();
        apply_keys(text, &keys)
    }

    /// Map alphanumeric words spoken as `<letters> <Thai numerals>` to the
    /// exact word, when the numerals' value equals the word's digits:
    /// `SHA สองห้าหก` / `SHA สองร้อยห้าสิบหก` / `SHA256 สองห้าหก` → `SHA256`.
    pub fn apply_numerals(&self, text: &str) -> (String, usize) {
        if text.is_empty() || self.numerals.is_empty() {
            return (text.to_string(), 0);
        }
        let t: Vec<char> = text.chars().collect();
        let mut claimed = vec![false; t.len()];
        let mut spans: Vec<Span> = Vec::new();
        // Longer words first so overlapping entries resolve deterministically;
        // per word, the bare prefix ("SHA สองห้าหก") and the redundant full
        // mention ("SHA256 สองห้าหก").
        let mut words: Vec<&NumeralWord> = self.numerals.iter().collect();
        words.sort_by_key(|w| std::cmp::Reverse(w.word.len()));
        for w in words {
            for (pattern, full) in [(&w.prefix, false), (&w.chars, true)] {
                let mut start = 0;
                while let Some(i) = find_insensitive(&t, pattern, start) {
                    start = i + 1;
                    let j = i + pattern.len();
                    // Not glued to a longer Latin run ("xSHA"); a full mention
                    // must also end there ("SHA2560" is another token).
                    if (i > 0 && t[i - 1].is_ascii_alphanumeric())
                        || (full && j < t.len() && t[j].is_ascii_alphanumeric())
                    {
                        continue;
                    }
                    let Some(end) = match_numeral_phrase(&t, j, &w.digits) else {
                        continue;
                    };
                    if claimed[i..end].iter().any(|&c| c) {
                        continue;
                    }
                    claimed[i..end].iter_mut().for_each(|c| *c = true);
                    spans.push(Span {
                        start: i,
                        end,
                        value: &w.word,
                        gap: Gap::Script,
                    });
                }
            }
        }
        let n = spans.len();
        (splice(&t, spans), n)
    }

    /// Dictionary words present in `before` (the text sent to the LLM) but
    /// missing from `after` (its reply). Non-empty means the LLM rewrote a word
    /// the user fixed (romanized a Thai name, re-cased a product): callers
    /// should keep `before` instead of the reply.
    pub fn lost_words<'a>(&'a self, before: &str, after: &str) -> Vec<&'a str> {
        let before: Vec<char> = before.chars().collect();
        let after: Vec<char> = after.chars().collect();
        self.vocabulary
            .iter()
            .filter(|w| {
                let w: Vec<char> = w.chars().collect();
                contains_term(&before, &w) && !contains_term(&after, &w)
            })
            .map(String::as_str)
            .collect()
    }
}

// ---------------------------------------------------------------------------
// Literal matching

#[derive(Clone, Debug)]
struct Key {
    chars: Vec<char>,
    value: String,
    /// Dictionary keys: case-insensitive, Latin word boundaries, script-aware
    /// spacing. Legacy replacement keys: exact, no boundary, always spaced
    /// (the Python-parity `apply_table` behavior).
    user: bool,
    /// Claims its matches without changing them (protects a correction's
    /// output from later keys).
    guard: bool,
}

impl Key {
    fn user(heard: &str, word: &str) -> Self {
        Key {
            chars: heard.chars().collect(),
            value: word.to_string(),
            user: true,
            guard: false,
        }
    }

    fn legacy(heard: &str, word: &str) -> Self {
        Key {
            chars: heard.chars().collect(),
            value: word.to_string(),
            user: false,
            guard: false,
        }
    }

    /// Exact (case-sensitive, no boundary rule); claims, never changes.
    fn guard(word: &str) -> Self {
        Key {
            chars: word.chars().collect(),
            value: word.to_string(),
            user: false,
            guard: true,
        }
    }
}

/// Whether applying `key` could rewrite one of `produced`: its source is
/// inside an output or wraps one, on the matcher's Latin word boundaries and
/// ignoring case. A case-only correction to that same output can't chain, and
/// repairs an LLM that undid it.
fn overlaps_output(key: &Key, produced: &[String]) -> bool {
    let fold = |s: &str| casefold(s).chars().collect::<Vec<char>>();
    let source = fold(&key.chars.iter().collect::<String>());
    produced.iter().any(|p| {
        let output = fold(p);
        if source == output {
            key.value != *p
        } else {
            contains_term(&output, &source) || contains_term(&source, &output)
        }
    })
}

fn apply_keys(text: &str, keys: &[&Key]) -> (String, usize) {
    let (t, n, _) = apply_keys_traced(text, keys);
    (t, n)
}

/// [`apply_keys`], also returning the values it wrote (one per replacement).
fn apply_keys_traced(text: &str, keys: &[&Key]) -> (String, usize, Vec<String>) {
    if text.is_empty() || keys.is_empty() {
        return (text.to_string(), 0, Vec::new());
    }
    let tokens = token_spans(text);
    let splits_thai_word = |p: usize| {
        tokens
            .iter()
            .take_while(|(s, _, _)| *s < p)
            .any(|(s, e, tok)| *s < p && p < *e && is_thai_word(tok))
    };
    let t: Vec<char> = text.chars().collect();
    let mut claimed = vec![false; t.len()];
    let mut spans: Vec<Span> = Vec::new();
    for key in keys {
        let mut start = 0;
        loop {
            let found = if key.user {
                find_insensitive(&t, &key.chars, start)
            } else {
                crate::pyu::find_chars(&t, &key.chars, start)
            };
            let Some(i) = found else { break };
            start = i + 1;
            let j = i + key.chars.len();
            if claimed[i..j].iter().any(|&c| c)
                || splits_thai_word(i)
                || splits_thai_word(j)
                || (key.user && !on_latin_boundary(&t, i, j))
            {
                continue;
            }
            claimed[i..j].iter_mut().for_each(|c| *c = true);
            if key.guard {
                continue;
            }
            // Already exactly right (e.g. the post-LLM pass re-meeting its own
            // output): keep the span claimed, but change and count nothing.
            if key.user && t[i..j].iter().copied().eq(key.value.chars()) {
                continue;
            }
            let gap = if key.user { Gap::Script } else { Gap::Always };
            spans.push(Span {
                start: i,
                end: j,
                value: &key.value,
                gap,
            });
        }
    }
    let n = spans.len();
    let written = spans.iter().map(|s| s.value.to_string()).collect();
    (splice(&t, spans), n, written)
}

/// A Latin-edged match must not continue a longer Latin/digit run on either
/// side ("teh" must not fire inside "tehran"). Thai edges are left to the
/// segmentation guard.
fn on_latin_boundary(t: &[char], i: usize, j: usize) -> bool {
    let latin = |c: char| c.is_ascii_alphanumeric();
    let left_ok = !(latin(t[i]) && i > 0 && latin(t[i - 1]));
    let right_ok = !(latin(t[j - 1]) && j < t.len() && latin(t[j]));
    left_ok && right_ok
}

/// Exact-case occurrence of `term` on Latin word boundaries ("AI" is not in
/// "MAIL").
fn contains_term(t: &[char], term: &[char]) -> bool {
    let mut start = 0;
    while let Some(i) = crate::pyu::find_chars(t, term, start) {
        if on_latin_boundary(t, i, i + term.len()) {
            return true;
        }
        start = i + 1;
    }
    false
}

fn find_insensitive(hay: &[char], needle: &[char], start: usize) -> Option<usize> {
    if needle.is_empty() || needle.len() > hay.len() {
        return None;
    }
    let eq = |a: char, b: char| a == b || a.to_lowercase().eq(b.to_lowercase());
    (start..=hay.len() - needle.len()).find(|&i| {
        hay[i..i + needle.len()]
            .iter()
            .zip(needle)
            .all(|(&h, &n)| eq(h, n))
    })
}

// ---------------------------------------------------------------------------
// Splicing

#[derive(Clone, Copy)]
enum Gap {
    /// Pad with a space whenever the neighbor is not a space (built-in and
    /// legacy tables, which map Thai into Latin).
    Always,
    /// Pad only where two letters/digits meet and at least one is Latin:
    /// "ชอบKoolifyมาก" → "ชอบ Koolify มาก", but Thai next to Thai stays
    /// unspaced and punctuation stays attached.
    Script,
}

struct Span<'a> {
    start: usize,
    end: usize,
    value: &'a str,
    gap: Gap,
}

/// Whether to pad between `outside` (the neighboring text char) and `inside`
/// (the replacement's edge char).
fn needs_gap(gap: Gap, outside: char, inside: char) -> bool {
    match gap {
        Gap::Always => !is_space(outside),
        Gap::Script => {
            let letter = |c: char| c.is_alphanumeric() || is_thai(c);
            letter(outside)
                && letter(inside)
                && (outside.is_ascii_alphanumeric() || inside.is_ascii_alphanumeric())
        }
    }
}

/// Replace non-overlapping spans, padding per their [`Gap`] policy.
fn splice(t: &[char], mut spans: Vec<Span>) -> String {
    if spans.is_empty() {
        return t.iter().collect();
    }
    spans.sort_by_key(|s| s.start);
    let mut out = String::with_capacity(t.len() + 16);
    let mut pos = 0;
    for s in &spans {
        out.extend(&t[pos..s.start]);
        if let (Some(prev), Some(first)) = (out.chars().next_back(), s.value.chars().next())
            && needs_gap(s.gap, prev, first)
        {
            out.push(' ');
        }
        out.push_str(s.value);
        if let (Some(last), Some(&next)) = (s.value.chars().next_back(), t.get(s.end))
            && needs_gap(s.gap, last, next)
        {
            out.push(' ');
        }
        pos = s.end;
    }
    out.extend(&t[pos..]);
    strip(&collapse_blanks(&out)).to_string()
}

// ---------------------------------------------------------------------------
// Alphanumeric words spoken with Thai numerals
//
// A vocabulary word like `SHA256` is unreachable by fuzzy matching when the
// digits are spoken in Thai ("SHA สองห้าหก"): the scripts share nothing to
// compare. Instead, find the word's Latin prefix followed by a Thai numeral
// phrase and check the phrase's VALUE equals the word's digits. Both styles
// count: place value ("สองร้อยห้าสิบหก") and digit by digit ("สองห้าหก").

#[derive(Clone, Debug)]
struct NumeralWord {
    word: String,
    chars: Vec<char>,
    prefix: Vec<char>,
    digits: BigInt,
}

impl NumeralWord {
    /// `SHA256` → prefix `SHA`, digits 256. Only ASCII letters followed by
    /// ASCII digits qualify (`SHA-256`, `Grafana`, `256` do not).
    fn new(word: &str) -> Option<Self> {
        let split = word.find(|c: char| !c.is_ascii_alphabetic())?;
        let (letters, digits) = word.split_at(split);
        if letters.is_empty() || digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        Some(NumeralWord {
            word: word.to_string(),
            chars: word.chars().collect(),
            prefix: letters.chars().collect(),
            digits: BigInt::parse_bytes(digits.as_bytes(), 10)?,
        })
    }
}

/// Thai digit words for digit-by-digit numbers, longest first so "เอ็ด"
/// and "ศูนย์" win over shorter prefixes. "ยี่" only ever means 20, so it is
/// not a lone digit.
const DIGIT_WORDS: [(&str, char); 11] = [
    ("ศูนย์", '0'),
    ("หนึ่ง", '1'),
    ("เจ็ด", '7'),
    ("เก้า", '9'),
    ("เอ็ด", '1'),
    ("สอง", '2'),
    ("สาม", '3'),
    ("แปด", '8'),
    ("สี่", '4'),
    ("ห้า", '5'),
    ("หก", '6'),
];

/// Value of a Thai numeral phrase: place value first, then digit by digit.
/// The whole string must parse.
fn parse_thai_numerals(s: &str) -> Option<BigInt> {
    if s.is_empty() {
        return None;
    }
    if let Ok(v) = thaiword_to_num(s) {
        return Some(v);
    }
    let mut digits = String::new();
    let mut rest = s;
    while !rest.is_empty() {
        let (w, d) = DIGIT_WORDS.iter().find(|(w, _)| rest.starts_with(w))?;
        digits.push(*d);
        rest = &rest[w.len()..];
    }
    BigInt::parse_bytes(digits.as_bytes(), 10)
}

/// From `j`, skip spaces and match the longest leading Thai numeral phrase
/// whose value is `digits`; returns its end. A match that leaves a still
/// numeric remainder is rejected, so "SHA สอง" never eats the head of a
/// spoken "SHA สองร้อย".
fn match_numeral_phrase(t: &[char], j: usize, digits: &BigInt) -> Option<usize> {
    let k = (j..t.len()).find(|&i| !is_space(t[i])).unwrap_or(t.len());
    let m = (k..t.len()).find(|&i| !is_thai(t[i])).unwrap_or(t.len());
    (k + 1..=m).rev().find(|&end| {
        let phrase: String = t[k..end].iter().collect();
        let rest: String = t[end..m].iter().collect();
        parse_thai_numerals(&phrase).is_some_and(|v| v == *digits)
            && (rest.is_empty() || parse_thai_numerals(&rest).is_none())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digit_words_longest_first() {
        let lens: Vec<usize> = DIGIT_WORDS.iter().map(|(w, _)| w.len()).collect();
        assert!(lens.windows(2).all(|p| p[0] >= p[1]), "{lens:?}");
    }

    #[test]
    fn parses_both_numeral_styles() {
        assert_eq!(parse_thai_numerals("สองร้อยห้าสิบหก"), Some(256.into()));
        assert_eq!(parse_thai_numerals("สองห้าหก"), Some(256.into()));
        assert_eq!(parse_thai_numerals("ศูนย์เจ็ด"), Some(7.into()));
        assert_eq!(parse_thai_numerals("ครับ"), None);
        assert_eq!(parse_thai_numerals(""), None);
    }

    #[test]
    fn numeral_word_shape() {
        assert!(NumeralWord::new("SHA256").is_some());
        assert!(NumeralWord::new("H100").is_some());
        for w in ["H", "Grafana", "SHA-256", "256", "SHA256x"] {
            assert!(NumeralWord::new(w).is_none(), "{w}");
        }
    }
}
