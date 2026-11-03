//! `pipeline._guardrail` and its checks: sanitize the LLM generation, falling back
//! to the post-dictionary text on anything suspicious.

use std::collections::HashSet;
use std::sync::LazyLock;

use crate::data::is_thai_word;
use crate::dictionary::CANONICAL_CASE;
use crate::dictionary::token_spans;
use crate::gate::latin_spans;
use crate::metrics;
use crate::phonetic::{correct_with_thai_vocab, thai_fold};
use crate::pyu::{has_thai, is_space, is_thai, lower, remove_ws, strip};
use crate::script::adds_foreign;
use crate::tokenize::word_tokenize;

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

/// Latin spans in `dict_text` that fail to survive into the candidate.
pub fn lost_spans(dict_text: &str, cand: &str, allow_asr_repair: bool) -> Vec<String> {
    let cand_low = lower(cand);
    let cand_nows = remove_ws(&cand_low);
    let cand_spans = latin_spans(&cand_low);
    let cand_span_chars: Vec<Vec<char>> = cand_spans.iter().map(|t| chars(t)).collect();
    let mut lost = Vec::new();
    for s in latin_spans(dict_text) {
        let sl = lower(s);
        if cand_nows.contains(&sl) {
            continue;
        }
        let slc = chars(&sl);
        if slc.len() >= 4 && cand_span_chars.iter().any(|t| within_one_edit(&slc, t)) {
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

fn real_thai_words(text: &str) -> Vec<String> {
    word_tokenize(text, false)
        .into_iter()
        .filter(|t| has_thai(t) && is_thai_word(t))
        .collect()
}

/// `(lost_long_content, invented_content)` between dict_text and candidate.
pub fn thai_divergence(dict_text: &str, cand: &str) -> (usize, usize) {
    let cand_nows = remove_ws(cand);
    let lost = real_thai_words(dict_text)
        .iter()
        .filter(|t| t.chars().count() >= R2_MIN_WORD_LEN && !cand_nows.contains(t.as_str()))
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

/// `(final, flag)`: the stripped generation, or dict_text with the reason it tripped.
pub fn guardrail(dict_text: &str, generation: &str) -> (String, &'static str) {
    let c = strip_out(generation);
    let fallback = |flag| (dict_text.to_string(), flag);
    if c.is_empty() {
        return fallback("empty->dict");
    }
    // Not in the Python reference: letters of another script (a Hangul or Lao
    // syllable inside a Thai name) are never a restoration.
    if adds_foreign(dict_text, &c) {
        return fallback("script->dict");
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
    if !invented_translation_gloss(dict_text, &c).is_empty() {
        return fallback("translate->dict");
    }
    (c, "ok")
}

/// Flag for a generation that passed the guardrail but rewrote a listed term.
pub const RESTRICTED_FLAG: &str = "ok-termKept";

/// Revert any edit the cleanup model made to a listed Thai-script vocabulary
/// term present in `dict_text`: the user's list states the spelling they want
/// (ยูทูบ stays ยูทูบ, a re-spelled name stays as listed). Every other edit is
/// kept: on Thai ContextASR Bench, reverting the model's Thai-only edits as
/// well raised CER on ordinary speech, because its deletions mostly remove
/// repeated or hallucinated ASR text. Returns the text and the edits reverted.
pub fn protect_listed_terms(dict_text: &str, cand: &str, vocab: &[String]) -> (String, usize) {
    let a: Vec<char> = dict_text.chars().collect();
    let mut protected = vec![false; a.len()];
    for term in vocab.iter().map(|t| strip(t)).filter(|t| has_thai(t)) {
        mark(&a, &term.chars().collect::<Vec<_>>(), &mut protected);
    }
    if !protected.contains(&true) {
        return (cand.to_string(), 0);
    }
    let b: Vec<char> = cand.chars().collect();
    let runs = align(&a, &b);
    let revert: Vec<bool> = runs
        .iter()
        .map(|(eq, run)| !eq && run.a.iter().any(|&k| protected[k]))
        .collect();
    rebuild(&a, &b, &runs, &revert)
}

/// Sets `marks` over every occurrence of `term` in `text`.
fn mark(text: &[char], term: &[char], marks: &mut [bool]) {
    if term.is_empty() || term.len() > text.len() {
        return;
    }
    for i in 0..=text.len() - term.len() {
        if text[i..i + term.len()] == *term {
            marks[i..i + term.len()].iter_mut().for_each(|p| *p = true);
        }
    }
}

/// One edit of the alignment between dict text `a` and candidate `b`: where
/// it starts in `a`, the indices it covers on each side, those of `b` it wrote
/// (inserted or substituted, not matched), and its cost in letters:
/// insertions, deletions and substitutions, not counting whitespace.
struct Edit {
    at: usize,
    a: Vec<usize>,
    b: Vec<usize>,
    written: Vec<usize>,
    cost: usize,
}

/// Character alignment of `a` and `b` (Levenshtein) as alternating equal runs
/// (`true`) and edits; edits split by one or two coincidentally equal letters
/// form one edit.
fn align(a: &[char], b: &[char]) -> Vec<(bool, Edit)> {
    let (n, m) = (a.len(), b.len());
    let w = m + 1;
    let mut dp = vec![0u32; (n + 1) * w];
    for (j, cell) in dp.iter_mut().take(w).enumerate() {
        *cell = j as u32;
    }
    for i in 1..=n {
        dp[i * w] = i as u32;
        for j in 1..=m {
            let sub = dp[(i - 1) * w + j - 1] + u32::from(a[i - 1] != b[j - 1]);
            dp[i * w + j] = sub.min(dp[(i - 1) * w + j] + 1).min(dp[i * w + j - 1] + 1);
        }
    }
    // Backtrace into (dict index, cand index) steps; None marks a gap.
    let mut steps: Vec<(Option<usize>, Option<usize>)> = Vec::with_capacity(n.max(m));
    let (mut i, mut j) = (n, m);
    while i > 0 || j > 0 {
        if i > 0
            && j > 0
            && dp[i * w + j] == dp[(i - 1) * w + j - 1] + u32::from(a[i - 1] != b[j - 1])
        {
            steps.push((Some(i - 1), Some(j - 1)));
            i -= 1;
            j -= 1;
        } else if i > 0 && dp[i * w + j] == dp[(i - 1) * w + j] + 1 {
            steps.push((Some(i - 1), None));
            i -= 1;
        } else {
            steps.push((None, Some(j - 1)));
            j -= 1;
        }
    }
    steps.reverse();
    // Runs of (equal, dict indices, cand indices).
    let mut runs: Vec<(bool, Edit)> = Vec::new();
    let mut at = 0;
    for (x, y) in steps {
        let equal = matches!((x, y), (Some(x), Some(y)) if a[x] == b[y]);
        let absorb = !equal
            && runs.len() >= 2
            && runs[runs.len() - 1].0
            && runs[runs.len() - 1].1.a.len() <= 2;
        if absorb {
            let (_, e) = runs.pop().unwrap();
            let last = &mut runs.last_mut().unwrap().1;
            last.a.extend(e.a);
            last.b.extend(e.b);
            last.cost += e.cost;
        }
        let written = if equal { None } else { y };
        let blank = x.is_none_or(|x| is_space(a[x])) && y.is_none_or(|y| is_space(b[y]));
        let cost = usize::from(!equal && !blank);
        match runs.last_mut() {
            Some((eq, run)) if *eq == equal => {
                run.a.extend(x);
                run.b.extend(y);
                run.written.extend(written);
                run.cost += cost;
            }
            _ => runs.push((
                equal,
                Edit {
                    at,
                    a: x.into_iter().collect(),
                    b: y.into_iter().collect(),
                    written: written.into_iter().collect(),
                    cost,
                },
            )),
        }
        if let Some(x) = x {
            at = x + 1;
        }
    }
    runs
}

/// `b` with every run flagged in `revert` put back to `a`'s text; returns the
/// text and the number of edits reverted.
fn rebuild(a: &[char], b: &[char], runs: &[(bool, Edit)], revert: &[bool]) -> (String, usize) {
    let mut out = String::with_capacity(a.len().max(b.len()) * 3);
    for ((_, run), &back) in runs.iter().zip(revert) {
        if back {
            out.extend(run.a.iter().map(|&k| a[k]));
        } else {
            out.extend(run.b.iter().map(|&k| b[k]));
        }
    }
    (out, revert.iter().filter(|&&r| r).count())
}

/// Flag for a generation that passed the guardrail but rewrote Thai speech.
pub const THAI_KEPT_FLAG: &str = "ok-thaiKept";

/// Letters of Pali and Sanskrit spelling (ณ ศ ษ ฐ ฒ ภ ...). Thai names and
/// native words use them (ณัฐพงศ์, ศาสนา); transliterated English does not.
fn is_pali_letter(c: char) -> bool {
    "ฆฌญฎฏฐฑฒณศษภ".contains(c)
}

/// The largest Thai edit kept without a closer look, in letters changed: a
/// letter or two (เจส → เศส, รุกรัน → รุกราน, ลูก → รูป).
const THAI_EDIT_MAX_CHARS: usize = 2;
/// A small edit or deletion this close to a reverted rewrite (a short word
/// between them, no space) belongs to it: เจ็ดร้อยหกสิบ → เจ็ดสิบหก aligns
/// as a substitution, หก, then a deletion.
const THAI_EDIT_GAP: usize = 4;

/// Revert what the cleanup model did to Thai speech beyond its job, which is
/// writing Thai-spelled English in English:
///
/// - a Thai rewrite changing more than [`THAI_EDIT_MAX_CHARS`] letters that
///   is not a re-spelling of the same word: a misheard name turned into other
///   words (on FLEURS Thai มาเทอรี่ → มาเจอรีวิว, "came to meet" + "review";
///   เกรทยามาส, Great Yarmouth, → กระท่อม, "cottage"), a number changed;
/// - Latin written over a span spelled with Pali letters, a Thai word or name
///   romanized (ศาสนคริสต์ → Christian, ณัฐพงศ์ → Nattapong).
///
/// Deletions are kept (they remove repeated or hallucinated ASR text), as are
/// one- or two-letter spelling repairs, re-spellings of the same word, and
/// edits that write a term from `vocab`. Returns the text and the edits
/// reverted.
pub fn keep_thai_speech(dict_text: &str, cand: &str, vocab: &[String]) -> (String, usize) {
    let a: Vec<char> = dict_text.chars().collect();
    let b: Vec<char> = cand.chars().collect();
    let mut listed = vec![false; b.len()];
    let low: Vec<char> = b.iter().map(char::to_ascii_lowercase).collect();
    for term in vocab.iter().map(|t| strip(t)) {
        let term: Vec<char> = term.chars().map(|c| c.to_ascii_lowercase()).collect();
        mark(&low, &term, &mut listed);
    }
    let spans = token_spans(dict_text);
    let runs = align(&a, &b);
    let mut revert: Vec<bool> = runs
        .iter()
        .map(|(eq, run)| {
            if *eq || run.b.iter().any(|&k| listed[k]) {
                return false;
            }
            let new: Vec<char> = run.b.iter().map(|&k| b[k]).collect();
            let old: Vec<char> = run.a.iter().map(|&k| a[k]).collect();
            if new.iter().any(char::is_ascii_alphabetic) {
                return old.iter().copied().any(is_pali_letter);
            }
            // ๆ (mai yamok) only abbreviates a repeated word (ต่างต่าง → ต่างๆ).
            if old.iter().any(char::is_ascii_alphabetic)
                || !run.written.iter().any(|&k| is_thai(b[k]) && b[k] != 'ๆ')
                || run.cost <= THAI_EDIT_MAX_CHARS
            {
                return false;
            }
            !respells(&a, &spans, run, &new)
        })
        .collect();
    // Small Thai edits and deletions next to a reverted rewrite are part of it.
    let thai_only = |run: &Edit| {
        !run.a.iter().any(|&k| a[k].is_ascii_alphabetic())
            && !run
                .b
                .iter()
                .any(|&k| b[k].is_ascii_alphabetic() || listed[k])
    };
    let close = |run: &Edit| run.a.len() <= THAI_EDIT_GAP && !run.a.iter().any(|&k| is_space(a[k]));
    for i in 0..runs.len() {
        if !revert[i] {
            continue;
        }
        for step in [-2isize, 2] {
            let mut k = i as isize + step;
            while k >= 0
                && (k as usize) < runs.len()
                && close(&runs[(k - step / 2) as usize].1)
                && thai_only(&runs[k as usize].1)
            {
                revert[k as usize] = true;
                k += step;
            }
        }
    }
    rebuild(&a, &b, &runs, &revert)
}

/// Whether an edit only re-spells the dict-text words it touches: with the
/// edit applied they keep their royin sound skeleton (สาด → สัตว์, ย่า → หญ้า)
/// or differ only in silent letters (พัน → พันธุ์), or the Thai-script
/// vocabulary matcher takes them for the same word spelled another way
/// (เมลเบิล / เมลเบิร์น).
fn respells(a: &[char], spans: &[(usize, usize, String)], run: &Edit, new: &[char]) -> bool {
    let (lo, hi) = match (run.a.first(), run.a.last()) {
        (Some(&lo), Some(&hi)) => (lo, hi + 1),
        _ => (run.at, run.at),
    };
    // The words the edit touches and one more on each side, so a one-word
    // window does not make a two-letter re-spelling look like a rewrite.
    let first = spans.iter().position(|s| s.1 > lo).unwrap_or(spans.len());
    let last = spans.iter().rposition(|s| s.0 < hi).unwrap_or(0);
    let start = spans
        .get(first.saturating_sub(1))
        .map_or(lo, |s| s.0.min(lo));
    let end = spans
        .get(last + 1)
        .or(spans.get(last))
        .map_or(hi, |s| s.1.max(hi));
    let words: String = a[start..end].iter().collect();
    let edited: String = a[start..lo]
        .iter()
        .chain(new.iter().filter(|c| !is_space(**c)))
        .chain(&a[hi..end])
        .collect();
    if edited.chars().any(|c| c.is_ascii_alphanumeric()) {
        return false;
    }
    let sound = thai_fold(&words);
    (!sound.is_empty() && sound == thai_fold(&edited))
        || unsilenced(&words) == unsilenced(&edited)
        || correct_with_thai_vocab(&words, &[edited]).1 > 0
}

/// Thai text without the letters thanthakhat (์) silences: the consonant it
/// sits on and a vowel mark on that consonant, as in the vocabulary matcher's
/// spelling key.
fn unsilenced(text: &str) -> Vec<char> {
    let mut out: Vec<char> = Vec::with_capacity(text.len());
    for c in text.chars() {
        if c == '\u{e4c}' {
            while out
                .last()
                .is_some_and(|p| matches!(p, '\u{e34}'..='\u{e39}'))
            {
                out.pop();
            }
            out.pop();
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod protect_tests {
    use super::protect_listed_terms;
    fn r(dict: &str, cand: &str, vocab: &[&str]) -> (String, usize) {
        let vocab: Vec<String> = vocab.iter().map(|s| s.to_string()).collect();
        protect_listed_terms(dict, cand, &vocab)
    }
    #[test]
    fn listed_thai_terms_keep_their_spelling() {
        let (t, n) = r("เปิดยูทูบดู log", "เปิด YouTube ดู log", &["ยูทูบ"]);
        assert_eq!((t.as_str(), n), ("เปิดยูทูบดู log", 1));
        let (t, n) = r("คุณธีรศิลป์ยิงเข้า", "คุณทีรศิลป์ยิงเข้า", &["ธีรศิลป์", "Grafana"]);
        assert_eq!((t.as_str(), n), ("คุณธีรศิลป์ยิงเข้า", 1));
    }
    #[test]
    fn other_edits_are_kept() {
        // Restorations, spelling repairs and deletions away from listed terms.
        let cand = "restart server แล้วไปเมลเบิร์น";
        assert_eq!(r("รีสตาร์ทเซิร์ฟเวอร์แล้วไปเมลเบิ้ลครับ", cand, &["ยูทูบ"]).0, cand);
        let (t, n) = r(
            "เปิดยูทูบแล้ว restart เซิร์ฟเวอร์",
            "เปิดยูทูบแล้ว restart server",
            &["ยูทูบ"],
        );
        assert_eq!((t.as_str(), n), ("เปิดยูทูบแล้ว restart server", 0));
        assert_eq!(r("เปิดยูทูบดู", "เปิด YouTube ดู", &[]).0, "เปิด YouTube ดู");
    }
}

#[cfg(test)]
mod thai_speech_tests {
    use super::keep_thai_speech;
    fn k(dict: &str, cand: &str, vocab: &[&str]) -> (String, usize) {
        let vocab: Vec<String> = vocab.iter().map(|s| s.to_string()).collect();
        keep_thai_speech(dict, cand, &vocab)
    }

    #[test]
    fn rewritten_thai_speech_is_put_back() {
        // FLEURS Thai: a misheard surname turned into มาเจอ ("came to meet")
        // and รีวิว ("review"); both edits are one rewrite of the name.
        let dict = "เมื่อวานนี้มาเทอรี่ได้สาบาน";
        let (t, n) = k(dict, "เมื่อวานนี้มาเจอรีวิวได้สาบาน", &[]);
        assert_eq!((t.as_str(), n), (dict, 2));
        // A number the model changed, and a word it replaced with another.
        let dict = "ส่งไฟล์มาเจ็ดร้อยหกสิบหน้า";
        assert_eq!(k(dict, "ส่งไฟล์มาเจ็ดสิบหกหน้า", &[]).0, dict);
        // FLEURS Thai: a garbled place name and a garbled word replaced by
        // other Thai words.
        let dict = "รักษาในโรงพยาบาลในเกรทยามาส";
        assert_eq!(k(dict, "รักษาในโรงพยาบาลในกระท่อม", &[]).0, dict);
        let dict = "ในหมู่นักสะสมสแตมบางคน";
        assert_eq!(k(dict, "ในหมู่นักสะสมตามคน", &[]).0, dict);
    }

    #[test]
    fn romanized_thai_names_are_put_back() {
        let dict = "นัดคุณณัฐพงศ์ไว้บ่ายสอง";
        let (t, n) = k(dict, "นัดคุณ Nattapong ไว้บ่ายสอง", &[]);
        assert_eq!((t.as_str(), n), (dict, 1));
        // FLEURS Thai: ศาสนคริสต์ written as "Christian".
        assert_eq!(
            k("ในช่วงก่อนศาสนคริสต์", "ในช่วงก่อน Christian", &[]).0,
            "ในช่วงก่อนศาสนคริสต์"
        );
        // A listed Latin spelling is what the user asked for.
        let cand = "นัดคุณ Nattapong ไว้บ่ายสอง";
        assert_eq!(k(dict, cand, &["Nattapong"]), (cand.to_string(), 0));
    }

    #[test]
    fn restorations_repairs_and_deletions_are_kept() {
        for (dict, cand) in [
            // Thai-spelled English restored, including a listed brand.
            ("รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อก", "restart server แล้วเช็ค log"),
            ("ส่งเอกสารให้ทีมแอนโทรปิก", "ส่งเอกสารให้ทีม Anthropic"),
            // FLEURS Thai: spelling repairs of a letter or two, homophone
            // re-spellings and a repeated word removed.
            ("ปกครองโดยชาวฝรั่งเจส", "ปกครองโดยชาวฝรั่งเศส"),
            ("ทำงานร่วมกับผู้รุกรัน", "ทำงานร่วมกับผู้รุกราน"),
            ("จนกระทั่งมีการลบลูกภาพ", "จนกระทั่งมีการลบรูปภาพ"),
            ("เพื่อดูชมสาดป่าในทุ่งย่าสวรรค์", "เพื่อดูชมสัตว์ป่าในทุ่งหญ้าสวรรค์"),
            ("สิ่งปลูกสร้างต่างต่าง", "สิ่งปลูกสร้างต่าง"),
            ("มโนภาพของเทพต่างต่าง", "มโนภาพของเทพต่างๆ"),
            ("รู้จักพันไม้ในป่า", "รู้จักพันธุ์ไม้ในป่า"),
            ("ไปเมลเบิลกันครับ", "ไปเมลเบิร์นกันครับ"),
        ] {
            assert_eq!(k(dict, cand, &[]), (cand.to_string(), 0), "{dict}");
        }
        // A listed Thai spelling the model wrote.
        let cand = "ขอบคุณคุณเกริกไกรมาก";
        assert_eq!(
            k("ขอบคุณคุณเกลือไกลมาก", cand, &["เกริกไกร"]),
            (cand.to_string(), 0)
        );
    }
}
