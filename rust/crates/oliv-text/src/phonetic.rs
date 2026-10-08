//! `benchmark/phonetic.py`: vocab-aware phonetic correction and LLM vocab hints.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use crate::data::{THAI_STOPWORDS, is_thai_word};
use crate::dictionary::token_spans;
use crate::pyu::{collapse_blanks, has_thai, is_alpha, is_blank, is_space, is_upper, lower, strip};

const DIGRAPHS: [(&str, &str); 8] = [
    ("kh", "k"),
    ("th", "t"),
    ("ph", "p"),
    ("ch", "c"),
    ("ck", "k"),
    ("gh", "g"),
    ("wh", "w"),
    ("qu", "kw"),
];

/// Phonetic skeleton: lowercase, a-z only, de-aspirate, l->r, vowel runs -> 'a',
/// collapse doubled letters.
pub fn fold(s: &str) -> String {
    let mut s: String = lower(s)
        .chars()
        .filter(|c| c.is_ascii_lowercase())
        .collect();
    for (a, b) in DIGRAPHS {
        s = s.replace(a, b);
    }
    s = s.replace('l', "r");
    let mut out = String::with_capacity(s.len());
    let mut prev_vowel = false;
    for c in s.chars() {
        let v = "aeiou".contains(c);
        if v && prev_vowel {
            continue;
        }
        out.push(if v { 'a' } else { c });
        prev_vowel = v;
    }
    // re.sub(r"(.)\1+", r"\1", s)
    let mut dedup = String::with_capacity(out.len());
    for c in out.chars() {
        if !dedup.ends_with(c) {
            dedup.push(c);
        }
    }
    dedup
}

static ROYIN_CACHE: LazyLock<Mutex<HashMap<String, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// `_royin`: royin romanization, "" on failure (cached like the lru_cache).
fn royin(thai: &str) -> String {
    if let Some(r) = ROYIN_CACHE.lock().unwrap().get(thai) {
        return r.clone();
    }
    let r = crate::royin::romanize(thai).unwrap_or_default();
    let mut cache = ROYIN_CACHE.lock().unwrap();
    if cache.len() >= 4096 {
        cache.clear();
    }
    cache.insert(thai.to_string(), r.clone());
    r
}

pub fn thai_fold(thai: &str) -> String {
    fold(&royin(thai))
}

fn thai_letter_name(c: char) -> Option<&'static str> {
    Some(match c {
        'a' => "เอ",
        'b' => "บี",
        'c' => "ซี",
        'd' => "ดี",
        'e' => "อี",
        'f' => "เอฟ",
        'g' => "จี",
        'h' => "เอช",
        'i' => "ไอ",
        'j' => "เจ",
        'k' => "เค",
        'l' => "แอล",
        'm' => "เอ็ม",
        'n' => "เอ็น",
        'o' => "โอ",
        'p' => "พี",
        'q' => "คิว",
        'r' => "อาร์",
        's' => "เอส",
        't' => "ที",
        'u' => "ยู",
        'v' => "วี",
        'w' => "ดับเบิลยู",
        'x' => "เอกซ์",
        'y' => "วาย",
        'z' => "แซด",
        _ => return None,
    })
}

fn acronym_fold(term: &str) -> String {
    fold(
        &lower(term)
            .chars()
            .filter_map(thai_letter_name)
            .map(royin)
            .collect::<String>(),
    )
}

fn is_acronym(term: &str) -> bool {
    let t = term.replace('.', "");
    let n = t.chars().count();
    (2..=5).contains(&n) && is_upper(&t) && t.chars().all(is_alpha)
}

fn lev(a: &[char], b: &[char]) -> usize {
    if a == b {
        return 0;
    }
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.iter().enumerate() {
        let mut cur = vec![i + 1];
        for (j, cb) in b.iter().enumerate() {
            let v = (prev[j + 1] + 1)
                .min(cur[j] + 1)
                .min(prev[j] + usize::from(ca != cb));
            cur.push(v);
        }
        prev = cur;
    }
    prev[b.len()]
}

pub(crate) fn norm_dist(a: &str, b: &str) -> f64 {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let m = a.len().max(b.len());
    if m == 0 {
        1.0
    } else {
        lev(&a, &b) as f64 / m as f64
    }
}

fn consonant_coverage(term: &str, token_fold: &str) -> f64 {
    let mut cand: Vec<char> = fold(term).chars().filter(|&c| c != 'a').collect();
    cand.sort_unstable();
    cand.dedup();
    if cand.is_empty() {
        return 1.0;
    }
    let have = cand.iter().filter(|c| token_fold.contains(**c)).count();
    have as f64 / cand.len() as f64
}

const FUZZY_MAX: f64 = 0.20;
const FUZZY_MARGIN: f64 = 0.15;
const ACRO_MAX: f64 = 0.15;
const MIN_FOLD_LEN: usize = 3;
const CONS_COVERAGE: f64 = 0.6;
const HINT_MAX: f64 = 0.40;

fn has_stopword(toks: &[&str]) -> bool {
    toks.iter().any(|t| THAI_STOPWORDS.contains(t))
}

/// `sorted(((_norm_dist(wf, f), term) for term, f in word_folds))`
fn scored<'a>(wf: &str, word_folds: &[(&'a str, String)]) -> Vec<(f64, &'a str)> {
    let mut v: Vec<(f64, &str)> = word_folds
        .iter()
        .map(|(t, f)| (norm_dist(wf, f), *t))
        .collect();
    v.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(b.1)));
    v
}

fn first_char(s: &str) -> Option<char> {
    s.chars().next()
}

/// `^[A-Za-z][A-Za-z0-9]*$` (Python `$` also accepts one trailing "\n").
fn is_latin_tok(t: &str) -> bool {
    let t = t.strip_suffix('\n').unwrap_or(t);
    let mut cs = t.chars();
    cs.next().is_some_and(|c| c.is_ascii_alphabetic()) && cs.all(|c| c.is_ascii_alphanumeric())
}

/// Result of `correct_with_vocab`: new text, number fired, `(thai_span, term)` subs.
pub type VocabResult = (String, usize, Vec<(String, String)>);

pub fn correct_with_vocab(text: &str, vocab_terms: &[String]) -> VocabResult {
    if text.is_empty() || vocab_terms.is_empty() || !has_thai(text) {
        return (text.to_string(), 0, Vec::new());
    }
    let word_folds: Vec<(&str, String)> = vocab_terms
        .iter()
        .filter(|t| !t.is_empty() && !is_acronym(t))
        .map(|t| (t.as_str(), fold(t)))
        .filter(|(_, f)| f.chars().count() >= MIN_FOLD_LEN)
        .collect();
    let acro_folds: Vec<(&str, String)> = vocab_terms
        .iter()
        .filter(|t| is_acronym(t))
        .map(|t| (t.as_str(), acronym_fold(t)))
        .collect();

    let spans = token_spans(text);
    let idx: Vec<usize> = (0..spans.len())
        .filter(|&k| !is_blank(&spans[k].2))
        .collect();

    let mut proposals: Vec<(f64, usize, usize, &str)> = Vec::new();
    for a in 0..idx.len() {
        for w in 1..=5 {
            if a + w > idx.len() {
                break;
            }
            let toks: Vec<&str> = (0..w).map(|k| spans[idx[a + k]].2.as_str()).collect();
            if !toks.iter().all(|t| has_thai(t)) {
                continue;
            }
            if has_stopword(&toks) {
                continue;
            }
            let start = spans[idx[a]].0;
            let end = spans[idx[a + w - 1]].1;
            let wf = thai_fold(&toks.concat());
            if wf.chars().count() < MIN_FOLD_LEN {
                continue;
            }
            let first = first_char(&wf);
            let any_suspicious = toks.iter().any(|t| !is_thai_word(t));

            for (term, af) in &acro_folds {
                if af.is_empty() || first_char(af) != first {
                    continue;
                }
                let d = norm_dist(&wf, af);
                if d <= ACRO_MAX {
                    proposals.push((d, start, end, term));
                }
            }

            if any_suspicious && !word_folds.is_empty() {
                let sc = scored(&wf, &word_folds);
                let (d1, best) = sc[0];
                if d1 <= FUZZY_MAX
                    && !best.is_empty()
                    && first_char(&fold(best)) == first
                    && consonant_coverage(best, &wf) >= CONS_COVERAGE
                    && !(sc.len() >= 2 && sc[1].0 - d1 < FUZZY_MARGIN)
                {
                    proposals.push((d1, start, end, best));
                }
            }
        }
    }

    // Latin ASR garble windows.
    let latin_idx: Vec<usize> = idx
        .iter()
        .copied()
        .filter(|&k| is_latin_tok(&spans[k].2))
        .collect();
    for a in 0..latin_idx.len() {
        for w in 1..=3 {
            if a + w > latin_idx.len() {
                break;
            }
            let pos_ids = &latin_idx[a..a + w];
            let (lo, hi) = (pos_ids[0], pos_ids[w - 1]);
            let between: Vec<usize> = idx
                .iter()
                .copied()
                .filter(|&k| lo <= k && k <= hi)
                .collect();
            if between != pos_ids {
                continue;
            }
            let toks: String = pos_ids.iter().map(|&i| spans[i].2.as_str()).collect();
            let start = spans[pos_ids[0]].0;
            let end = spans[pos_ids[w - 1]].1;
            let wf = fold(&toks);
            if wf.chars().count() < MIN_FOLD_LEN || word_folds.is_empty() {
                continue;
            }
            let first = first_char(&wf);
            let sc = scored(&wf, &word_folds);
            let (d1, best) = sc[0];
            if d1 <= 0.30
                && !best.is_empty()
                && first_char(&fold(best)) == first
                && consonant_coverage(best, &wf) >= CONS_COVERAGE
                && !(sc.len() >= 2 && sc[1].0 - d1 < FUZZY_MARGIN)
            {
                proposals.push((d1, start, end, best));
            }
        }
    }

    if proposals.is_empty() {
        return (text.to_string(), 0, Vec::new());
    }

    // best (lowest score, then longest span) first; stable like Python's sort
    proposals.sort_by(|p, q| p.0.total_cmp(&q.0).then((q.2 - q.1).cmp(&(p.2 - p.1))));
    let t: Vec<char> = text.chars().collect();
    let mut claimed = vec![false; t.len()];
    let mut chosen: Vec<(usize, usize, &str)> = Vec::new();
    for &(_, s, e, term) in &proposals {
        if claimed[s..e].iter().any(|&c| c) {
            continue;
        }
        claimed[s..e].iter_mut().for_each(|c| *c = true);
        chosen.push((s, e, term));
    }
    if chosen.is_empty() {
        return (text.to_string(), 0, Vec::new());
    }

    chosen.sort();
    let mut out = String::with_capacity(text.len() + 16);
    let mut subs = Vec::new();
    let mut pos = 0;
    for &(s, e, term) in &chosen {
        out.extend(&t[pos..s]);
        if out.chars().next_back().is_some_and(|c| !is_space(c)) {
            out.push(' ');
        }
        out.push_str(term);
        if e < t.len() && !is_space(t[e]) {
            out.push(' ');
        }
        subs.push((t[s..e].iter().collect(), term.to_string()));
        pos = e;
    }
    out.extend(&t[pos..]);
    (
        strip(&collapse_blanks(&out)).to_string(),
        chosen.len(),
        subs,
    )
}

/// Vocab terms that plausibly appear but were too mangled to auto-replace.
pub fn vocab_hint(text: &str, vocab_terms: &[String]) -> Vec<String> {
    if text.is_empty() || vocab_terms.is_empty() || !has_thai(text) {
        return Vec::new();
    }
    let (_, _, subs) = correct_with_vocab(text, vocab_terms);
    let done: Vec<&str> = subs.iter().map(|(_, en)| en.as_str()).collect();
    let word_folds: Vec<(&str, String)> = vocab_terms
        .iter()
        .filter(|t| !t.is_empty() && !is_acronym(t) && !done.contains(&t.as_str()))
        .map(|t| (t.as_str(), fold(t)))
        .filter(|(_, f)| f.chars().count() >= MIN_FOLD_LEN)
        .collect();
    let spans = token_spans(text);
    let idx: Vec<usize> = (0..spans.len())
        .filter(|&k| !is_blank(&spans[k].2))
        .collect();
    let mut hinted: Vec<String> = Vec::new();
    for a in 0..idx.len() {
        for w in 1..=5 {
            if a + w > idx.len() {
                break;
            }
            let toks: Vec<&str> = (0..w).map(|k| spans[idx[a + k]].2.as_str()).collect();
            if !toks.iter().all(|t| has_thai(t)) || has_stopword(&toks) {
                continue;
            }
            if !toks.iter().any(|t| !is_thai_word(t)) {
                continue;
            }
            let wf = thai_fold(&toks.concat());
            if wf.chars().count() < MIN_FOLD_LEN {
                continue;
            }
            for (term, f) in &word_folds {
                if first_char(f) == first_char(&wf)
                    && norm_dist(&wf, f) <= HINT_MAX
                    && consonant_coverage(term, &wf) >= CONS_COVERAGE
                    && !hinted.iter().any(|h| h == term)
                {
                    hinted.push(term.to_string());
                }
            }
        }
    }
    hinted
}
