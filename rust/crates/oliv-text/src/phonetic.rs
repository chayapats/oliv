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

/// Whether Thai text is the acronym read letter by letter (เอพีไอ for API).
fn spells_letters(thai: &str, term: &str) -> bool {
    let spelled: String = lower(term).chars().filter_map(thai_letter_name).collect();
    let key = |s: &str| thai_spelling_key(&s.chars().filter(|c| !is_space(*c)).collect::<Vec<_>>());
    !spelled.is_empty() && key(thai) == key(&spelled)
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

/// Whether a Latin term can be matched by its folded sound. The fold keeps
/// ASCII letters only, so a term with Thai (หุ้นกู้ THANA) or other non-ASCII
/// letters (Chișinău) would be matched on a fragment of itself; and a 3-letter
/// skeleton (Nan) matches syllables of unrelated words once a vocabulary is
/// long. Measured on Thai ContextASR Bench distractor lists.
fn foldable_term(term: &str) -> bool {
    !term.is_empty()
        && term
            .chars()
            .all(|c| !c.is_alphabetic() || c.is_ascii_alphabetic())
}
const MIN_WORD_FOLD_LEN: usize = 4;

pub fn correct_with_vocab(text: &str, vocab_terms: &[String]) -> VocabResult {
    if text.is_empty() || vocab_terms.is_empty() || !has_thai(text) {
        return (text.to_string(), 0, Vec::new());
    }
    let word_folds: Vec<(&str, String)> = vocab_terms
        .iter()
        .filter(|t| foldable_term(t) && !is_acronym(t))
        .map(|t| (t.as_str(), fold(t)))
        .filter(|(_, f)| f.chars().count() >= MIN_WORD_FOLD_LEN)
        .collect();
    let acro_folds: Vec<(&str, String)> = vocab_terms
        .iter()
        .filter(|t| foldable_term(t) && is_acronym(t))
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
                // Like the word path, an acronym never replaces real Thai words
                // (เพื่อน, กิน, ศูนย์) unless they spell its letters out.
                if !any_suspicious && !spells_letters(&toks.concat(), term) {
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
        .filter(|t| foldable_term(t) && !is_acronym(t) && !done.contains(&t.as_str()))
        .map(|t| (t.as_str(), fold(t)))
        .filter(|(_, f)| f.chars().count() >= MIN_WORD_FOLD_LEN)
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

/// A vocabulary term written in Thai script (no Latin letters or digits).
fn is_thai_term(term: &str) -> bool {
    has_thai(term) && !term.chars().any(|c| c.is_ascii_alphanumeric())
}

/// Spelling key for comparing Thai spellings of one sound: a consonant silenced
/// by thanthakhat (์) is dropped and homophonous consonants share one letter,
/// so พงศ์/พงษ์, บดิน/บดินทร์ and ทีรสิน/ธีรศิลป์ differ little. Vowels and tone
/// marks are kept: they distinguish real words.
fn thai_spelling_key(chars: &[char]) -> Vec<char> {
    let mut out: Vec<char> = Vec::with_capacity(chars.len());
    for &c in chars {
        if c == '\u{e4c}' {
            // Drop the silenced consonant (and a vowel mark sitting on it).
            while out
                .last()
                .is_some_and(|p| matches!(p, '\u{e34}'..='\u{e39}'))
            {
                out.pop();
            }
            out.pop();
            continue;
        }
        out.push(match c {
            'ฐ' | 'ฑ' | 'ฒ' | 'ธ' | 'ถ' => 'ท',
            'ศ' | 'ษ' | 'ซ' => 'ส',
            'ณ' => 'น',
            'ฬ' => 'ล',
            'ภ' | 'ผ' => 'พ',
            'ฝ' => 'ฟ',
            'ฏ' => 'ต',
            'ฎ' => 'ด',
            'ข' | 'ฃ' | 'ฅ' | 'ฆ' => 'ค',
            'ฉ' | 'ฌ' => 'ช',
            'ญ' => 'ย',
            'ฮ' => 'ห',
            _ => c,
        });
    }
    out
}

/// Edit distance between spelling keys where replacing one consonant with a
/// different one costs 2: royin conflates จ/ช, ก/ค, ป/พ, but Thai does not.
fn thai_spelling_distance(a: &[char], b: &[char]) -> usize {
    let consonant = |c: char| ('ก'..='ฮ').contains(&c);
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, &ca) in a.iter().enumerate() {
        let mut cur = vec![i + 1];
        for (j, &cb) in b.iter().enumerate() {
            let sub = match (ca == cb, consonant(ca) && consonant(cb)) {
                (true, _) => 0,
                (false, true) => 2,
                (false, false) => 1,
            };
            cur.push((prev[j] + sub).min(prev[j + 1] + 1).min(cur[j] + 1));
        }
        prev = cur;
    }
    prev[b.len()]
}

const THAI_TERM_MIN_CHARS: usize = 3;
/// Weighted spelling-key distance allowed when the royin skeletons match:
/// at most 2, and at most a third of the key.
const THAI_SURFACE_MAX: f64 = 0.34;
const THAI_SURFACE_MAX_EDITS: usize = 2;
/// Tighter bounds when the skeletons differ by a small edit.
const THAI_NEAR_FOLD_MAX: f64 = 0.15;
const THAI_NEAR_FOLD_MIN_LEN: usize = 6;
const THAI_NEAR_SURFACE_MAX: f64 = 0.25;
/// Terms with a short spelling key never replace a single real Thai word: the
/// skeleton ignores tone and vowel length, so กอง/ก้อง or สอง/สิงห์ would collide.
const THAI_SHORT_TERM_MAX: usize = 4;
const THAI_WINDOW_MAX_TOKENS: usize = 8;
/// Keys this short must match exactly (ต้า must not become a listed ต้อ).
const THAI_EXACT_KEY_MAX: usize = 3;

/// Thai-script vocabulary: re-spell a Thai span that sounds like a listed Thai
/// term (same royin skeleton) and is spelled almost the same — a homophone
/// spelling (พงศ์/พงษ์), a dropped or added silent letter, a vowel-length slip.
/// The Latin-term path in [`correct_with_vocab`] is unchanged; text already
/// matching a listed term is protected from other terms.
pub fn correct_with_thai_vocab(text: &str, vocab_terms: &[String]) -> VocabResult {
    let terms: Vec<(&str, Vec<char>, Vec<char>, String)> = vocab_terms
        .iter()
        .map(|t| strip(t))
        .filter(|t| is_thai_term(t))
        .map(|t| {
            let chars: Vec<char> = t.chars().filter(|c| !is_space(*c)).collect();
            let fold = thai_fold(&chars.iter().collect::<String>());
            (t, thai_spelling_key(&chars), chars, fold)
        })
        .filter(|(_, _, chars, fold)| chars.len() >= THAI_TERM_MIN_CHARS && !fold.is_empty())
        .collect();
    if text.is_empty() || terms.is_empty() || !has_thai(text) {
        return (text.to_string(), 0, Vec::new());
    }
    let longest = terms.iter().map(|t| t.2.len()).max().unwrap_or(0);
    let spans = token_spans(text);
    let idx: Vec<usize> = (0..spans.len())
        .filter(|&k| !is_blank(&spans[k].2))
        .collect();
    // (score, start, end, replacement); a negative score protects an exact match.
    let mut proposals: Vec<(f64, usize, usize, Option<&str>)> = Vec::new();
    for a in 0..idx.len() {
        let mut surface: Vec<char> = Vec::new();
        for w in 1..=THAI_WINDOW_MAX_TOKENS {
            if a + w > idx.len() {
                break;
            }
            let tok = spans[idx[a + w - 1]].2.as_str();
            if !tok.chars().all(crate::pyu::is_thai) {
                break;
            }
            surface.extend(tok.chars());
            if surface.len() > longest + 3 {
                break;
            }
            let toks: Vec<&str> = (0..w).map(|k| spans[idx[a + k]].2.as_str()).collect();
            if toks.iter().all(|t| THAI_STOPWORDS.contains(t)) {
                continue;
            }
            let (start, end) = (spans[idx[a]].0, spans[idx[a + w - 1]].1);
            let mut key = None;
            let mut fold = None;
            for (term, term_key, chars, term_fold) in &terms {
                if surface == *chars {
                    proposals.push((-1.0, start, end, None));
                    continue;
                }
                if surface.len().abs_diff(chars.len()) > 3 {
                    continue;
                }
                if w == 1 && term_key.len() <= THAI_SHORT_TERM_MAX && is_thai_word(toks[0]) {
                    continue;
                }
                let key: &Vec<char> = key.get_or_insert_with(|| thai_spelling_key(&surface));
                let edits = thai_spelling_distance(key, term_key);
                let dist = edits as f64 / key.len().max(term_key.len()).max(1) as f64;
                if edits > THAI_SURFACE_MAX_EDITS
                    || dist > THAI_SURFACE_MAX
                    || (edits > 0 && term_key.len() <= THAI_EXACT_KEY_MAX)
                {
                    continue;
                }
                let wf: &String = fold.get_or_insert_with(|| thai_fold(&toks.concat()));
                let ok = if wf == term_fold {
                    true
                } else {
                    term_fold.chars().count() >= THAI_NEAR_FOLD_MIN_LEN
                        && norm_dist(wf, term_fold) <= THAI_NEAR_FOLD_MAX
                        && dist <= THAI_NEAR_SURFACE_MAX
                };
                if ok {
                    proposals.push((dist, start, end, Some(*term)));
                }
            }
        }
    }
    if !proposals.iter().any(|p| p.3.is_some()) {
        return (text.to_string(), 0, Vec::new());
    }
    proposals.sort_by(|p, q| p.0.total_cmp(&q.0).then((q.2 - q.1).cmp(&(p.2 - p.1))));
    let t: Vec<char> = text.chars().collect();
    let mut claimed = vec![false; t.len()];
    let mut chosen: Vec<(usize, usize, &str)> = Vec::new();
    for &(_, s, e, term) in &proposals {
        if claimed[s..e].iter().any(|&c| c) {
            continue;
        }
        claimed[s..e].iter_mut().for_each(|c| *c = true);
        if let Some(term) = term {
            chosen.push((s, e, term));
        }
    }
    chosen.sort();
    let mut out = String::with_capacity(text.len());
    let mut subs = Vec::new();
    let mut pos = 0;
    for &(s, e, term) in &chosen {
        out.extend(&t[pos..s]);
        out.push_str(term);
        subs.push((t[s..e].iter().collect(), term.to_string()));
        pos = e;
    }
    out.extend(&t[pos..]);
    (out, chosen.len(), subs)
}

/// Minimum skeleton length for [`correct_with_latin_names`].
const NAME_MIN_FOLD: usize = 5;
const NAME_MAX_TOKENS: usize = 4;

/// Latin-script vocabulary entries spoken as Thai words: a Thai span whose royin
/// skeleton equals a listed Latin name exactly is written the listed way
/// (คลองเตย → Khlong Toei). [`correct_with_vocab`] only rewrites spans holding a
/// non-dictionary token; this covers names built from real Thai words, so it
/// demands an exact skeleton, a long term, and an unambiguous best match.
pub fn correct_with_latin_names(text: &str, vocab_terms: &[String]) -> VocabResult {
    let folds: Vec<(&str, String)> = vocab_terms
        .iter()
        .map(|t| strip(t))
        .filter(|t| {
            !t.is_empty()
                && !has_thai(t)
                && t.chars().any(|c| c.is_ascii_alphabetic())
                && !is_acronym(t)
        })
        .map(|t| (t, fold(t)))
        .filter(|(_, f)| f.chars().count() >= NAME_MIN_FOLD)
        .collect();
    if text.is_empty() || folds.is_empty() || !has_thai(text) {
        return (text.to_string(), 0, Vec::new());
    }
    let spans = token_spans(text);
    let idx: Vec<usize> = (0..spans.len())
        .filter(|&k| !is_blank(&spans[k].2))
        .collect();
    let mut proposals: Vec<(usize, usize, &str)> = Vec::new();
    for a in 0..idx.len() {
        for w in 1..=NAME_MAX_TOKENS {
            if a + w > idx.len() {
                break;
            }
            let toks: Vec<&str> = (0..w).map(|k| spans[idx[a + k]].2.as_str()).collect();
            if !toks.iter().all(|t| t.chars().all(crate::pyu::is_thai)) {
                break;
            }
            if has_stopword(&toks) {
                continue;
            }
            let surface = toks.concat();
            if surface.chars().count() < 4 {
                continue;
            }
            let wf = thai_fold(&surface);
            let matches: Vec<&str> = folds
                .iter()
                .filter(|(_, f)| *f == wf)
                .map(|(t, _)| *t)
                .collect();
            // Two different listed names with this sound: ambiguous, leave it.
            if let [term] = matches[..] {
                proposals.push((spans[idx[a]].0, spans[idx[a + w - 1]].1, term));
            }
        }
    }
    if proposals.is_empty() {
        return (text.to_string(), 0, Vec::new());
    }
    // Longest spans first, then leftmost.
    proposals.sort_by(|p, q| (q.1 - q.0).cmp(&(p.1 - p.0)).then(p.0.cmp(&q.0)));
    let t: Vec<char> = text.chars().collect();
    let mut claimed = vec![false; t.len()];
    let mut chosen = Vec::new();
    for &(s, e, term) in &proposals {
        if !claimed[s..e].iter().any(|&c| c) {
            claimed[s..e].iter_mut().for_each(|c| *c = true);
            chosen.push((s, e, term));
        }
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

#[cfg(test)]
mod thai_vocab_tests {
    use super::{
        correct_with_latin_names, correct_with_thai_vocab, correct_with_vocab, thai_spelling_key,
    };
    #[test]
    fn acronyms_never_replace_real_thai_words() {
        let fix = |text: &str, vocab: &[&str]| {
            let vocab: Vec<String> = vocab.iter().map(|s| s.to_string()).collect();
            correct_with_vocab(text, &vocab).0
        };
        // Stock-ticker entries seen firing on distractor lists.
        assert_eq!(
            fix("ไปกินข้าวกับเพื่อนนะ", &["PROEN", "KEEL"]),
            "ไปกินข้าวกับเพื่อนนะ"
        );
        assert_eq!(fix("อันนี้เป็นวิธีที่ดี", &["NEO", "VT"]), "อันนี้เป็นวิธีที่ดี");
        // Spelled-out acronyms still snap.
        assert_eq!(fix("เรียกเอพีไอก่อน", &["API"]), "เรียก API ก่อน");
    }
    #[test]
    fn latin_path_skips_unfoldable_and_tiny_terms() {
        let fix = |text: &str, vocab: &[&str]| {
            let vocab: Vec<String> = vocab.iter().map(|s| s.to_string()).collect();
            correct_with_vocab(text, &vocab).0
        };
        // False snaps seen on distractor lists: a fragment of ออริจินัล, a
        // mixed-script entry and a term whose fold drops letters.
        assert_eq!(
            fix("รสชาติออริจินัลต้องแบบนี้", &["Nan", "Naiin"]),
            "รสชาติออริจินัลต้องแบบนี้"
        );
        assert_eq!(fix("ลิตเติ้ล โกลาบา", &["หุ้นกู้ THANA"]), "ลิตเติ้ล โกลาบา");
        assert_eq!(fix("คุณจัญญาก็เตรียม", &["Chișinău"]), "คุณจัญญาก็เตรียม");
        // A real transliteration still snaps.
        assert_eq!(
            fix("Grafana, คูเบอร์เนติส", &["Kubernetes", "Nan"]),
            "Grafana, Kubernetes"
        );
    }
    #[test]
    fn latin_listed_names_follow_the_list() {
        let fix = |text: &str, vocab: &[&str]| {
            let vocab: Vec<String> = vocab.iter().map(|s| s.to_string()).collect();
            correct_with_latin_names(text, &vocab).0
        };
        assert_eq!(
            fix("ตลาดคลองเตยเลย", &["Khlong Toei"]),
            "ตลาด Khlong Toei เลย"
        );
        // Short or acronym terms and unrelated text are left alone.
        assert_eq!(fix("ไปกินข้าววันนี้", &["Wan", "Khao", "BTS"]), "ไปกินข้าววันนี้");
        assert_eq!(fix("ตลาดคลองเตยเลย", &["Grafana"]), "ตลาดคลองเตยเลย");
    }
    #[test]
    fn spelling_key_merges_homophone_letters_and_silent_consonants() {
        let key = |s: &str| {
            thai_spelling_key(&s.chars().collect::<Vec<_>>())
                .into_iter()
                .collect::<String>()
        };
        assert_eq!(key("พงศ์"), key("พงษ์"));
        assert_eq!(key("ธีรศิลป์"), "ทีรสิล");
        assert_eq!(key("บดินทร์"), "บดินท");
        assert_ne!(key("ก้อง"), key("กอง"));
    }
    fn fix(text: &str, vocab: &[&str]) -> String {
        let vocab: Vec<String> = vocab.iter().map(|s| s.to_string()).collect();
        correct_with_thai_vocab(text, &vocab).0
    }
    #[test]
    fn respells_listed_thai_names() {
        assert_eq!(fix("ไปลงสถานีบางแคร์นะครับ", &["บางแค"]), "ไปลงสถานีบางแคนะครับ");
        assert_eq!(fix("คุณณรงค์พงศ์มาแล้ว", &["ณรงค์พงษ์"]), "คุณณรงค์พงษ์มาแล้ว");
        assert_eq!(fix("ไปเมลเบิลกัน", &["เมลเบิร์น"]), "ไปเมลเบิร์นกัน");
    }
    #[test]
    fn leaves_unrelated_and_short_real_words() {
        // Tone differs and กอง is a common word: never re-spelled to a short name.
        assert_eq!(fix("หัวหน้ากองสารคดี", &["ก้อง"]), "หัวหน้ากองสารคดี");
        assert_eq!(fix("วันนี้อากาศดีมาก", &["บางแค", "สมชาย"]), "วันนี้อากาศดีมาก");
        // Over-biasing cases seen on dis@50: a common word or a different consonant.
        assert_eq!(fix("แต่เดี๋ยวไปดู", &["เดียร์"]), "แต่เดี๋ยวไปดู");
        assert_eq!(fix("ครั้งสองแสน", &["สิงห์"]), "ครั้งสองแสน");
        assert_eq!(fix("ที่พี่เจมส์ส่ง", &["พี่แชมป์"]), "ที่พี่เจมส์ส่ง");
        // Latin and mixed-script terms belong to the Latin path.
        assert_eq!(fix("บางแคร์", &["Bang Khae", "กองทุน KKP"]), "บางแคร์");
    }
    #[test]
    fn exact_matches_are_protected() {
        let vocab: Vec<String> = ["บางแค", "บางแคร์"].iter().map(|s| s.to_string()).collect();
        let (text, n, _) = correct_with_thai_vocab("สถานีบางแคร์", &vocab);
        assert_eq!((text.as_str(), n), ("สถานีบางแคร์", 0));
    }
}
