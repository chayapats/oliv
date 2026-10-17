//! Native port of the Thai ContextASR Bench scorer (`scorer/norm.py`, `tok.py`,
//! `metrics.py`, `score.py`; Apache-2.0, wayu-ai/thai-contextasr-bench at
//! 84e3099). Normalization, tokenization, alignment tie-breaking, attribution and
//! the seeded bootstrap follow the stdlib (no `kaldialign`) reference exactly.
use super::mt::PyRandom;
use caseless::default_case_fold_str;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use unicode_normalization::UnicodeNormalization;

const VOWELS: &str = "\u{e31}\u{e34}\u{e35}\u{e36}\u{e37}\u{e38}\u{e39}\u{e47}";
const NASAL: &str = "\u{e4d}\u{e4e}";
const TONES: &str = "\u{e48}\u{e49}\u{e4a}\u{e4b}";
const SILENCERS: &str = "\u{e3a}\u{e4c}";
const LEAD_VOWELS: &str = "เแโใไ";
const DEP_VOWELS: &str =
    "\u{e30}\u{e31}\u{e32}\u{e33}\u{e34}\u{e35}\u{e36}\u{e37}\u{e38}\u{e39}\u{e45}\u{e47}";
const TONES_KARAN: &str = "\u{e48}\u{e49}\u{e4a}\u{e4b}\u{e4c}\u{e4d}";
const CONS: &str = "กขฃคฅฆงจฉชซฌญฎฏฐฑฒณดตถทธนบปผฝพฟภมยรลวศษสหฬอฮ";
const CLUSTER_SECOND: &str = "รลว";
const CLUSTER_FIRST: &str = "กขคจตทปพผส";

fn mark_priority(c: char) -> Option<u8> {
    [VOWELS, NASAL, TONES, SILENCERS]
        .iter()
        .position(|set| set.contains(c))
        .map(|p| p as u8)
}

/// Python `str.isspace`, which also covers the ASCII separators 0x1C-0x1F.
fn is_py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

fn reorder_marks(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut run: Vec<char> = Vec::new();
    for ch in text.chars() {
        if mark_priority(ch).is_some() {
            run.push(ch);
        } else {
            run.sort_by_key(|c| mark_priority(*c));
            out.extend(run.drain(..));
            out.push(ch);
        }
    }
    run.sort_by_key(|c| mark_priority(*c));
    out.extend(run);
    out
}

fn last_syllable_start(out: &[char], j: usize) -> usize {
    let is = |set: &str, c: char| set.contains(c);
    let mut i = j;
    while i > 0 && is(TONES_KARAN, out[i - 1]) {
        i -= 1;
    }
    if i > 0 && is(CONS, out[i - 1]) {
        i -= 1;
    }
    while i > 0 && (is(DEP_VOWELS, out[i - 1]) || is(TONES_KARAN, out[i - 1]) || out[i - 1] == 'อ')
    {
        i -= 1;
    }
    if i > 0 && is(CONS, out[i - 1]) {
        i -= 1;
        if i > 0 && is(CLUSTER_SECOND, out[i]) && is(CLUSTER_FIRST, out[i - 1]) {
            i -= 1;
        }
    }
    if i > 0 && is(LEAD_VOWELS, out[i - 1]) {
        i -= 1;
    }
    if i > 1 && out[i - 1] == 'ำ' && is(CONS, out[i - 2]) {
        i -= 2;
    }
    if i < j { i } else { j }
}

fn expand_yamok(text: &str) -> String {
    let mut out: Vec<char> = Vec::with_capacity(text.len());
    for ch in text.chars() {
        if ch == 'ๆ' {
            let mut j = out.len();
            while j > 0 && out[j - 1] == ' ' {
                j -= 1;
            }
            let i = last_syllable_start(&out, j);
            let copy: Vec<char> = out[i..j].to_vec();
            out.extend(copy);
        } else {
            out.push(ch);
        }
    }
    out.into_iter().collect()
}

/// `norm.normalize`: canonicalize encoding artifacts, never pronunciation.
pub fn normalize(text: &str) -> String {
    let text: String = text
        .nfc()
        .filter(|c| {
            !matches!(
                c,
                '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{feff}' | '\u{ad}'
            )
        })
        .collect();
    let text = text.replace("\u{e4d}\u{e32}", "\u{e33}").replace("เเ", "แ");
    let text: String = text
        .chars()
        .map(|c| match c {
            '๐'..='๙' => char::from(b'0' + (c as u32 - '๐' as u32) as u8),
            _ => c,
        })
        .collect();
    let text = default_case_fold_str(&expand_yamok(&reorder_marks(&text)));
    text.split(is_py_space)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// `tok.tokenize`: one token per Thai code point, one per Latin/digit word.
pub fn tokenize(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut word = String::new();
    for ch in text.chars() {
        if ('\u{e00}'..='\u{e7f}').contains(&ch) {
            if !word.is_empty() {
                tokens.push(std::mem::take(&mut word));
            }
            tokens.push(ch.to_string());
        } else if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
            word.push(ch);
        } else if !word.is_empty() {
            tokens.push(std::mem::take(&mut word));
        }
    }
    if !word.is_empty() {
        tokens.push(word);
    }
    tokens
}

pub fn form_str(form: &str) -> String {
    tokenize(&normalize(form)).concat()
}

/// Edit distance over tokens.
fn distance(a: &[String], b: &[String]) -> usize {
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, left) in a.iter().enumerate() {
        let mut cur = Vec::with_capacity(b.len() + 1);
        cur.push(i + 1);
        for (j, right) in b.iter().enumerate() {
            cur.push(
                (prev[j] + usize::from(left != right))
                    .min(prev[j + 1] + 1)
                    .min(cur[j] + 1),
            );
        }
        prev = cur;
    }
    prev[b.len()]
}

/// `metrics.align` fallback: (ref, hyp) pairs, `None` for a gap; backtrace
/// prefers diagonal, then deletion, then insertion.
fn align<'a>(r: &'a [String], h: &'a [String]) -> Vec<(Option<&'a str>, Option<&'a str>)> {
    let (n, m) = (r.len(), h.len());
    let w = m + 1;
    let mut dp = vec![0usize; (n + 1) * w];
    for (j, cell) in dp.iter_mut().take(w).enumerate() {
        *cell = j;
    }
    for i in 1..=n {
        dp[i * w] = i;
        for j in 1..=m {
            let sub = dp[(i - 1) * w + j - 1] + usize::from(r[i - 1] != h[j - 1]);
            dp[i * w + j] = sub.min(dp[(i - 1) * w + j] + 1).min(dp[i * w + j - 1] + 1);
        }
    }
    let mut out = Vec::with_capacity(n.max(m));
    let (mut i, mut j) = (n, m);
    while i > 0 || j > 0 {
        if i > 0
            && j > 0
            && dp[i * w + j] == dp[(i - 1) * w + j - 1] + usize::from(r[i - 1] != h[j - 1])
        {
            out.push((Some(r[i - 1].as_str()), Some(h[j - 1].as_str())));
            i -= 1;
            j -= 1;
        } else if i > 0 && dp[i * w + j] == dp[(i - 1) * w + j] + 1 {
            out.push((Some(r[i - 1].as_str()), None));
            i -= 1;
        } else {
            out.push((None, Some(h[j - 1].as_str())));
            j -= 1;
        }
    }
    out.reverse();
    out
}

/// One entity with every creditable surface form.
#[derive(Clone, Debug)]
pub struct Entity {
    pub forms: Vec<String>,
    pub listed_form: Option<String>,
}
impl Entity {
    pub fn norm_forms(&self) -> Vec<String> {
        let mut seen = HashSet::new();
        self.forms
            .iter()
            .map(|f| form_str(f))
            .filter(|s| !s.is_empty() && seen.insert(s.clone()))
            .collect()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ErrCounts {
    pub sub: usize,
    pub ins: usize,
    pub dele: usize,
    pub refn: usize,
}
impl ErrCounts {
    pub fn err(&self) -> usize {
        self.sub + self.ins + self.dele
    }
    pub fn rate(&self) -> f64 {
        if self.refn == 0 {
            0.0
        } else {
            self.err() as f64 / self.refn as f64
        }
    }
    fn add(&mut self, o: &ErrCounts) {
        self.sub += o.sub;
        self.ins += o.ins;
        self.dele += o.dele;
        self.refn += o.refn;
    }
    fn json(&self) -> Value {
        json!({"sub":self.sub,"ins":self.ins,"dele":self.dele,"ref":self.refn})
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct UttScore {
    pub overall: ErrCounts,
    pub biased: ErrCounts,
    pub unbiased: ErrCounts,
    pub gold_total: usize,
    pub gold_recalled: usize,
    pub distractors_fired: usize,
    pub distractors_total: usize,
    pub script_expected: usize,
    pub script_compliant: usize,
    /// OLIV addition: gold entities that carry a listed form, recalled or not.
    pub listed_total: usize,
    /// OLIV addition: per-gold-entity recall flags, in annotation order.
    pub recalled: Vec<bool>,
    /// OLIV addition: per-gold-entity "listed form reproduced" flags.
    pub listed_hit: Vec<bool>,
    /// OLIV addition: listed distractor strings that fired.
    pub fired: Vec<String>,
}

type Slot = (usize, usize, Vec<Vec<String>>);

fn entity_slots(ref_toks: &[String], gold: &[Entity]) -> Vec<Slot> {
    let mut slots = Vec::new();
    let mut taken = vec![false; ref_toks.len()];
    for e in gold {
        let mut forms: Vec<Vec<String>> = e.forms.iter().map(|f| tokenize(&normalize(f))).collect();
        // Stable, like Python's sorted(..., reverse=True).
        forms.sort_by_key(|f| std::cmp::Reverse(f.len()));
        let mut found = None;
        'forms: for form in &forms {
            let k = form.len();
            if k == 0 || k > ref_toks.len() {
                continue;
            }
            for i in 0..=ref_toks.len() - k {
                if ref_toks[i..i + k] == form[..] && !taken[i..i + k].iter().any(|t| *t) {
                    found = Some((i, k));
                    break 'forms;
                }
            }
        }
        if let Some((i, k)) = found {
            taken[i..i + k].iter_mut().for_each(|t| *t = true);
            slots.push((i, k, forms.into_iter().filter(|f| !f.is_empty()).collect()));
        }
    }
    slots.sort_by_key(|s| s.0);
    slots
}

/// `_ref_variants`: dual-form reference substitutions, identity first, in
/// `itertools.product` order; identity only beyond 32 combinations.
fn ref_variants(ref_toks: &[String], slots: &[Slot]) -> Vec<(Vec<String>, BTreeSet<usize>)> {
    let mut choices: Vec<Vec<&[String]>> = slots
        .iter()
        .map(|(start, len, forms)| {
            let ident = &ref_toks[*start..start + len];
            std::iter::once(ident)
                .chain(forms.iter().map(Vec::as_slice).filter(|f| *f != ident))
                .collect()
        })
        .collect();
    let combos = choices
        .iter()
        .fold(1usize, |acc, c| acc.saturating_mul(c.len().max(1)));
    if combos > 32 {
        choices.iter_mut().for_each(|c| c.truncate(1));
    }
    let mut out = Vec::new();
    let mut idx = vec![0usize; choices.len()];
    loop {
        let mut toks = Vec::new();
        let mut spans = BTreeSet::new();
        let mut prev = 0;
        for (s, (start, len, _)) in slots.iter().enumerate() {
            toks.extend_from_slice(&ref_toks[prev..*start]);
            let form = choices[s][idx[s]];
            spans.extend(toks.len()..toks.len() + form.len());
            toks.extend_from_slice(form);
            prev = start + len;
        }
        toks.extend_from_slice(&ref_toks[prev..]);
        out.push((toks, spans));
        // Odometer with the last slot varying fastest.
        let mut k = choices.len();
        loop {
            if k == 0 {
                return out;
            }
            k -= 1;
            idx[k] += 1;
            if idx[k] < choices[k].len() {
                break;
            }
            idx[k] = 0;
        }
    }
}

fn insert_run_in_list(run: &[&str], list_forms: &HashSet<String>) -> bool {
    let s: String = run.concat();
    s.chars().count() >= 2
        && list_forms
            .iter()
            .any(|f| f.contains(&s) || s.contains(f.as_str()))
}

/// `metrics.score_utterance`. `gold` are entities in the reference; `bias` is
/// everything shown to the system, with gold entities first (`gold_in_bias` of them).
pub fn score_utterance(
    reference: &str,
    hypothesis: &str,
    gold: &[Entity],
    bias: &[Entity],
    gold_in_bias: usize,
) -> UttScore {
    let base_ref = tokenize(&normalize(reference));
    let hyp = tokenize(&normalize(hypothesis));
    let slots = entity_slots(&base_ref, gold);
    let mut best: Option<(usize, Vec<String>, BTreeSet<usize>)> = None;
    for (toks, spans) in ref_variants(&base_ref, &slots) {
        let err = distance(&toks, &hyp);
        if best.as_ref().is_none_or(|b| err < b.0) {
            best = Some((err, toks, spans));
        }
    }
    let (_, ref_toks, bias_spans) = best.unwrap();
    let ali = align(&ref_toks, &hyp);
    let list_forms: HashSet<String> = bias.iter().flat_map(Entity::norm_forms).collect();

    let mut s = UttScore {
        overall: ErrCounts {
            refn: ref_toks.len(),
            ..Default::default()
        },
        biased: ErrCounts {
            refn: bias_spans.len(),
            ..Default::default()
        },
        unbiased: ErrCounts {
            refn: ref_toks.len() - bias_spans.len(),
            ..Default::default()
        },
        ..Default::default()
    };
    let mut ref_idx = 0;
    let mut run: Vec<&str> = Vec::new();
    let flush = |run: &mut Vec<&str>, s: &mut UttScore| {
        if run.is_empty() {
            return;
        }
        let biased = insert_run_in_list(run, &list_forms);
        let target = if biased {
            &mut s.biased
        } else {
            &mut s.unbiased
        };
        target.ins += run.len();
        s.overall.ins += run.len();
        run.clear();
    };
    for (r, h) in ali {
        let Some(r) = r else {
            run.push(h.unwrap());
            continue;
        };
        flush(&mut run, &mut s);
        let in_span = bias_spans.contains(&ref_idx);
        let target = if in_span {
            &mut s.biased
        } else {
            &mut s.unbiased
        };
        match h {
            None => {
                target.dele += 1;
                s.overall.dele += 1;
            }
            Some(h) if h != r => {
                target.sub += 1;
                s.overall.sub += 1;
            }
            _ => {}
        }
        ref_idx += 1;
    }
    flush(&mut run, &mut s);

    let hyp_str: String = hyp.concat();
    let ref_str: String = base_ref.concat();
    s.gold_total = gold.len();
    let gold_forms: Vec<String> = gold.iter().flat_map(Entity::norm_forms).collect();
    for e in gold {
        let recalled = e.norm_forms().iter().any(|f| hyp_str.contains(f.as_str()));
        s.recalled.push(recalled);
        if e.listed_form.is_some() {
            s.listed_total += 1;
        }
        let mut hit = false;
        if recalled {
            s.gold_recalled += 1;
            if let Some(listed) = &e.listed_form {
                s.script_expected += 1;
                hit = hyp_str.contains(&form_str(listed));
                s.script_compliant += usize::from(hit);
            }
        }
        s.listed_hit.push(hit);
    }
    for e in &bias[gold_in_bias..] {
        let forms: Vec<String> = e
            .norm_forms()
            .into_iter()
            .filter(|f| {
                !gold_forms
                    .iter()
                    .any(|g| g.contains(f.as_str()) || f.contains(g.as_str()))
            })
            .collect();
        if forms.is_empty() {
            continue;
        }
        s.distractors_total += 1;
        if forms.iter().any(|f| hyp_str.contains(f.as_str()))
            && !forms.iter().any(|f| ref_str.contains(f.as_str()))
        {
            s.distractors_fired += 1;
            s.fired.push(e.forms[0].clone());
        }
    }
    s
}

pub fn ratio(n: usize, d: usize) -> Option<f64> {
    (d > 0).then(|| n as f64 / d as f64)
}

/// Totals over utterances (`metrics.aggregate`).
pub fn total<'a>(scores: impl IntoIterator<Item = &'a UttScore>) -> UttScore {
    let mut t = UttScore::default();
    for u in scores {
        t.overall.add(&u.overall);
        t.biased.add(&u.biased);
        t.unbiased.add(&u.unbiased);
        t.gold_total += u.gold_total;
        t.gold_recalled += u.gold_recalled;
        t.distractors_fired += u.distractors_fired;
        t.distractors_total += u.distractors_total;
        t.script_expected += u.script_expected;
        t.script_compliant += u.script_compliant;
        t.listed_total += u.listed_total;
    }
    t
}

pub fn aggregate(scores: &[&UttScore]) -> Value {
    let t = total(scores.iter().copied());
    json!({
        "cer": t.overall.rate(), "b_cer": t.biased.rate(), "u_cer": t.unbiased.rate(),
        "entity_recall": ratio(t.gold_recalled, t.gold_total),
        "script_compliance": ratio(t.script_compliant, t.script_expected),
        "distractor_fire_rate": ratio(t.distractors_fired, t.distractors_total),
        "counts": {"overall": t.overall.json(), "biased": t.biased.json(), "unbiased": t.unbiased.json(),
            "gold": [t.gold_recalled, t.gold_total], "fired": [t.distractors_fired, t.distractors_total]},
        // OLIV additions (not in the upstream report):
        "listed_form_accuracy": ratio(t.script_compliant, t.listed_total),
        "listed": [t.script_compliant, t.listed_total],
    })
}

/// Python `round(x, 4)` for the finite values the scorer produces.
fn round4(x: f64) -> f64 {
    format!("{x:.4}").parse().unwrap()
}

/// `score.bootstrap_ci`: 1,000 seeded utterance resamples, 2.5/97.5 percentiles.
pub fn bootstrap_ci(scores: &[&UttScore], stat: impl Fn(&UttScore) -> Option<f64>) -> Value {
    if scores.is_empty() {
        return Value::Null;
    }
    let mut rng = PyRandom::new(2026);
    let mut vals = Vec::with_capacity(1000);
    for _ in 0..1000 {
        let t = total((0..scores.len()).map(|_| scores[rng.randrange(scores.len())]));
        if let Some(v) = stat(&t) {
            vals.push(v);
        }
    }
    if vals.is_empty() {
        return Value::Null;
    }
    vals.sort_by(f64::total_cmp);
    let n = vals.len() as f64;
    json!([
        round4(vals[(0.025 * n) as usize]),
        round4(vals[(0.975 * n) as usize])
    ])
}

/// Upstream report for one condition, plus `n_utts` and `ci95`.
pub fn condition_report(scores: &[&UttScore]) -> Value {
    let mut agg = aggregate(scores);
    agg["n_utts"] = scores.len().into();
    agg["ci95"] = json!({
        "cer": bootstrap_ci(scores, |t| Some(t.overall.rate())),
        "b_cer": bootstrap_ci(scores, |t| Some(t.biased.rate())),
        "entity_recall": bootstrap_ci(scores, |t| ratio(t.gold_recalled, t.gold_total)),
    });
    agg
}

/// One bias list row of `data/bias_lists.jsonl.gz`.
#[derive(Clone, Debug, Default)]
pub struct BiasList {
    pub entries: Vec<String>,
    /// span_text -> listed form, in file order.
    pub gold_listed: BTreeMap<String, String>,
}

/// One utterance of `data/utterances.jsonl`.
#[derive(Clone, Debug)]
pub struct Utterance {
    pub id: String,
    pub text: String,
    pub split: String,
    pub entity_free: bool,
    /// (span_text, all forms) per gold entity.
    pub entities: Vec<(String, Vec<String>)>,
}
impl Utterance {
    pub fn from_json(v: &Value) -> Result<Self, String> {
        let s = |k: &str| {
            v[k].as_str()
                .map(str::to_owned)
                .ok_or(format!("utterance missing {k}"))
        };
        let strs = |e: &Value, k: &str| -> Vec<String> {
            match &e[k] {
                Value::String(s) => vec![s.clone()],
                Value::Array(a) => a
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect(),
                _ => vec![],
            }
        };
        let entities = v["entities"]
            .as_array()
            .ok_or("utterance missing entities")?
            .iter()
            .map(|e| {
                // `score.entity_forms`: th, latin, th alts, latin alts; empty dropped.
                let forms = ["form_th", "form_latin", "form_th_alt", "latin_alts"]
                    .iter()
                    .flat_map(|k| strs(e, k))
                    .filter(|f| !f.is_empty())
                    .collect();
                Ok((
                    e["span_text"]
                        .as_str()
                        .ok_or("entity missing span_text")?
                        .to_owned(),
                    forms,
                ))
            })
            .collect::<Result<_, String>>()?;
        Ok(Self {
            id: s("utt_id")?,
            text: s("text")?,
            split: s("split").unwrap_or_default(),
            entity_free: v["entity_free"] == true,
            entities,
        })
    }
}

/// `score.score_report` for one (utterance, condition, hypothesis).
pub fn score_pair(
    u: &Utterance,
    condition: &str,
    list: Option<&BiasList>,
    hypothesis: &str,
) -> UttScore {
    let empty = BiasList::default();
    let list = list.unwrap_or(&empty);
    let gold: Vec<Entity> = u
        .entities
        .iter()
        .map(|(span, forms)| Entity {
            forms: forms.clone(),
            listed_form: list.gold_listed.get(span).cloned(),
        })
        .collect();
    let mut bias: Vec<Entity> = if condition.starts_with("bias") || condition.starts_with("flip") {
        gold.clone()
    } else {
        vec![]
    };
    let gold_in_bias = bias.len();
    let gold_vals: HashSet<&String> = list.gold_listed.values().collect();
    let mut seen = HashSet::new();
    for s in &list.entries {
        if !gold_vals.contains(s) && seen.insert(s) {
            bias.push(Entity {
                forms: vec![s.clone()],
                listed_form: None,
            });
        }
    }
    score_utterance(&u.text, hypothesis, &gold, &bias, gold_in_bias)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn ent(forms: &[&str], listed: Option<&str>) -> Entity {
        Entity {
            forms: forms.iter().map(|s| s.to_string()).collect(),
            listed_form: listed.map(str::to_owned),
        }
    }
    #[test]
    fn normalization_canonicalizes_encoding_only() {
        // ํ+า -> ำ, เเ -> แ, Thai digits, zero-width, tone-before-vowel order.
        assert_eq!(normalize("น\u{e4d}\u{e32}"), "นำ");
        assert_eq!(normalize("เเม่"), "แม่");
        assert_eq!(normalize("๑๒3"), "123");
        assert_eq!(normalize("ก\u{200b}ข"), "กข");
        assert_eq!(normalize("ก\u{e48}\u{e34}"), "ก\u{e34}\u{e48}");
        // Tone marks are real errors and survive.
        assert_ne!(normalize("ไก่"), normalize("ไก"));
        assert_eq!(normalize("  Grab\u{1f}TAXI  "), "grab taxi");
    }
    #[test]
    fn yamok_repeats_the_preceding_word() {
        assert_eq!(normalize("เด็กๆ"), "เด็กเด็ก");
        assert_eq!(normalize("ต่างๆ"), normalize("ต่างต่าง"));
        assert_eq!(normalize("เรื่อยๆ"), "เรื่อยเรื่อย");
        assert_eq!(normalize("จริงๆ"), "จริงจริง");
    }
    #[test]
    fn tokenizer_splits_thai_chars_and_latin_words() {
        assert_eq!(tokenize("ไป grab-taxi 7"), ["ไ", "ป", "grab", "taxi", "7"]);
        assert_eq!(form_str("Grab Taxi"), "grabtaxi");
    }
    #[test]
    fn alignment_prefers_substitution_then_deletion() {
        let t = |s: &str| tokenize(s);
        let (r, h) = (t("กขค"), t("กค"));
        let a = align(&r, &h);
        assert_eq!(
            a,
            vec![
                (Some("ก"), Some("ก")),
                (Some("ข"), None),
                (Some("ค"), Some("ค"))
            ]
        );
        assert_eq!(distance(&t("กขค"), &t("กงคจ")), 2);
    }
    #[test]
    fn dual_form_entity_scores_zero_in_either_script() {
        let gold = [ent(&["แกร็บ", "Grab"], Some("Grab"))];
        let thai = score_utterance("เรียกแกร็บไป", "เรียกแกร็บไป", &gold, &gold, 1);
        let latin = score_utterance("เรียกแกร็บไป", "เรียก Grab ไป", &gold, &gold, 1);
        assert_eq!(thai.overall.err(), 0);
        assert_eq!(latin.overall.err(), 0);
        assert_eq!((latin.gold_recalled, latin.script_compliant), (1, 1));
        assert_eq!((thai.gold_recalled, thai.script_compliant), (1, 0));
        assert_eq!(latin.biased.refn, 1);
    }
    #[test]
    fn insertions_matching_the_list_count_as_biased() {
        let bias = [ent(&["Netflix"], None)];
        let s = score_utterance("ไปกิน", "ไปกิน netflix", &[], &bias, 0);
        assert_eq!((s.biased.ins, s.unbiased.ins), (1, 0));
        assert_eq!((s.distractors_fired, s.distractors_total), (1, 1));
        assert_eq!(s.fired, ["Netflix"]);
    }
    #[test]
    fn distractor_nested_in_gold_is_not_measured() {
        let gold = [ent(&["เดทไลน์", "deadline"], None)];
        let bias = [gold[0].clone(), ent(&["ไลน์"], None)];
        let s = score_utterance("ส่งก่อนเดทไลน์", "ส่งก่อนเดทไลน์", &gold, &bias, 1);
        assert_eq!(s.distractors_total, 0);
    }
    #[test]
    fn python_rounding_and_empty_rates() {
        assert_eq!(round4(0.123456), 0.1235);
        assert_eq!(ErrCounts::default().rate(), 0.0);
        assert_eq!(ratio(1, 0), None);
    }
}
