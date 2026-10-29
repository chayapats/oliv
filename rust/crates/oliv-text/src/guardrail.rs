//! `pipeline._guardrail` and its checks: sanitize the LLM generation, falling back
//! to the post-dictionary text on anything suspicious.

use std::collections::HashSet;
use std::sync::LazyLock;

use crate::data::is_thai_word;
use crate::dictionary::CANONICAL_CASE;
use crate::gate::latin_spans;
use crate::metrics;
use crate::pyu::{has_thai, lower, remove_ws, strip};
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
        let t: Vec<char> = term.chars().collect();
        if t.is_empty() || t.len() > a.len() {
            continue;
        }
        for i in 0..=a.len() - t.len() {
            if a[i..i + t.len()] == t[..] {
                protected[i..i + t.len()].iter_mut().for_each(|p| *p = true);
            }
        }
    }
    if !protected.contains(&true) {
        return (cand.to_string(), 0);
    }
    let b: Vec<char> = cand.chars().collect();
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
    // Runs of (equal, dict indices, cand indices); edits split by one or two
    // coincidentally equal letters form one edit.
    let mut runs: Vec<(bool, Vec<usize>, Vec<usize>)> = Vec::new();
    for (x, y) in steps {
        let equal = matches!((x, y), (Some(x), Some(y)) if a[x] == b[y]);
        let absorb = !equal
            && runs.len() >= 2
            && runs[runs.len() - 1].0
            && runs[runs.len() - 1].1.len() <= 2;
        if absorb {
            let (_, ea, eb) = runs.pop().unwrap();
            let last = runs.last_mut().unwrap();
            last.1.extend(ea);
            last.2.extend(eb);
        }
        match runs.last_mut() {
            Some(run) if run.0 == equal => {
                run.1.extend(x);
                run.2.extend(y);
            }
            _ => runs.push((equal, x.into_iter().collect(), y.into_iter().collect())),
        }
    }
    let mut out = String::with_capacity(cand.len().max(dict_text.len()));
    let mut reverted = 0;
    for (equal, ga, gb) in runs {
        if !equal && ga.iter().any(|&k| protected[k]) {
            out.extend(ga.iter().map(|&k| a[k]));
            reverted += 1;
        } else {
            out.extend(gb.iter().map(|&k| b[k]));
        }
    }
    (out, reverted)
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
