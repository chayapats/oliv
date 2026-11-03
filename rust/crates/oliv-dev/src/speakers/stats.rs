//! Aggregates for per-speaker and multi-reader runs. Everything here works on
//! scores and labels only; transcripts never reach a summary or report.
use serde_json::{Value, json};
use std::collections::BTreeMap;

/// Meaning match: LaBSE cosine of word-segmented texts at or above this.
pub const THRESHOLD: f64 = 0.80;
const BOOTSTRAP_ROUNDS: usize = 2000;

#[derive(Clone, Debug)]
pub struct Clip {
    pub speaker: String,
    /// Kit id, or FLEURS sentence id: clips with the same value share content.
    pub sentence: String,
    pub group: String,
    pub sim: f64,
    pub raw_sim: f64,
    pub wer: f64,
    pub cer: f64,
    pub raw_wer: f64,
    pub raw_cer: f64,
    pub latency_s: f64,
    /// The cleanup model failed (for example timed out); the text is the
    /// speech model's, lightly post-processed.
    pub cleanup_failed: bool,
}
impl Clip {
    pub fn from_json(v: &Value) -> Result<Self, String> {
        let text = |k: &str| {
            v[k].as_str()
                .map(str::to_owned)
                .ok_or(format!("Result clip has no {k}"))
        };
        let num = |k: &str| v[k].as_f64().ok_or(format!("Result clip has no {k}"));
        Ok(Self {
            speaker: text("speaker")?,
            sentence: text("sentence")?,
            group: text("group")?,
            sim: num("sim")?,
            raw_sim: num("raw_sim")?,
            wer: num("wer")?,
            cer: num("cer")?,
            raw_wer: num("raw_wer")?,
            raw_cer: num("raw_cer")?,
            latency_s: num("latency_s")?,
            cleanup_failed: !v["cleanup_error"].is_null(),
        })
    }
    pub fn pass(&self, raw: bool) -> bool {
        (if raw { self.raw_sim } else { self.sim }) >= THRESHOLD
    }
    fn cer_of(&self, raw: bool) -> f64 {
        if raw { self.raw_cer } else { self.cer }
    }
}

fn mean(values: impl IntoIterator<Item = f64>) -> f64 {
    let (sum, n) = values
        .into_iter()
        .fold((0.0, 0usize), |(s, n), v| (s + v, n + 1));
    if n == 0 { 0.0 } else { sum / n as f64 }
}
fn pct(count: usize, n: usize) -> f64 {
    if n == 0 {
        0.0
    } else {
        100.0 * count as f64 / n as f64
    }
}
/// Linear interpolation between closest ranks (numpy's default).
pub fn percentile(values: &[f64], q: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let pos = q.clamp(0.0, 1.0) * (sorted.len() - 1) as f64;
    let (lo, hi) = (pos.floor() as usize, pos.ceil() as usize);
    sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Summary {
    pub n: usize,
    /// Percent of clips with a meaning match, after cleanup and from the speech model alone.
    pub matched: f64,
    pub raw_matched: f64,
    pub sim: f64,
    pub wer: f64,
    pub cer: f64,
    pub raw_wer: f64,
    pub raw_cer: f64,
    pub latency_median: f64,
    pub latency_p90: f64,
    pub cleanup_failed: usize,
}
impl Summary {
    pub fn of(clips: &[&Clip]) -> Option<Self> {
        if clips.is_empty() {
            return None;
        }
        let latency: Vec<f64> = clips.iter().map(|c| c.latency_s).collect();
        Some(Self {
            n: clips.len(),
            matched: pct(clips.iter().filter(|c| c.pass(false)).count(), clips.len()),
            raw_matched: pct(clips.iter().filter(|c| c.pass(true)).count(), clips.len()),
            sim: mean(clips.iter().map(|c| c.sim)),
            wer: mean(clips.iter().map(|c| c.wer)),
            cer: mean(clips.iter().map(|c| c.cer)),
            raw_wer: mean(clips.iter().map(|c| c.raw_wer)),
            raw_cer: mean(clips.iter().map(|c| c.raw_cer)),
            latency_median: percentile(&latency, 0.5),
            latency_p90: percentile(&latency, 0.9),
            cleanup_failed: clips.iter().filter(|c| c.cleanup_failed).count(),
        })
    }
    pub fn to_json(&self) -> Value {
        json!({"n":self.n,"meaning_match_pct":self.matched,"stt_only_meaning_match_pct":self.raw_matched,
            "mean_similarity":self.sim,"mean_wer":self.wer,"mean_cer":self.cer,
            "stt_only_mean_wer":self.raw_wer,"stt_only_mean_cer":self.raw_cer,
            "latency_median_s":self.latency_median,"latency_p90_s":self.latency_p90,
            "cleanup_failed":self.cleanup_failed})
    }
}

/// Deterministic generator for bootstrap resampling (splitmix64).
struct Rng(u64);
impl Rng {
    fn below(&mut self, n: usize) -> usize {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        ((z ^ (z >> 31)) % n as u64) as usize
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Paired {
    pub sentences: usize,
    pub pairs: usize,
    pub baseline_matched: f64,
    pub other_matched: f64,
    /// Other minus baseline, percentage points, with a sentence-cluster bootstrap 95% CI.
    pub delta: f64,
    pub ci: (f64, f64),
    /// Sentences the baseline matched and the other voice did not, and the reverse.
    pub lost: usize,
    pub gained: usize,
    pub delta_cer: f64,
    pub delta_wer: f64,
}
impl Paired {
    /// `others` (one or several voices) against `baseline`, on sentences both
    /// recorded. Each pair is one other-voice clip next to the baseline clip of
    /// the same sentence.
    pub fn of(baseline: &[&Clip], others: &[&Clip], seed: u64) -> Option<Self> {
        let base: BTreeMap<&str, &Clip> =
            baseline.iter().map(|c| (c.sentence.as_str(), *c)).collect();
        let mut clusters: BTreeMap<&str, Vec<(&Clip, &Clip)>> = BTreeMap::new();
        for o in others {
            if let Some(b) = base.get(o.sentence.as_str()) {
                clusters
                    .entry(o.sentence.as_str())
                    .or_default()
                    .push((b, o));
            }
        }
        let pairs: Vec<(&Clip, &Clip)> = clusters.values().flatten().copied().collect();
        if pairs.is_empty() {
            return None;
        }
        let rate = |pairs: &[(&Clip, &Clip)], other: bool| {
            pct(
                pairs
                    .iter()
                    .filter(|(b, o)| if other { o.pass(false) } else { b.pass(false) })
                    .count(),
                pairs.len(),
            )
        };
        let keys: Vec<&str> = clusters.keys().copied().collect();
        let mut rng = Rng(seed);
        let mut deltas = Vec::with_capacity(BOOTSTRAP_ROUNDS);
        for _ in 0..BOOTSTRAP_ROUNDS {
            let sample: Vec<(&Clip, &Clip)> = (0..keys.len())
                .flat_map(|_| clusters[keys[rng.below(keys.len())]].iter().copied())
                .collect();
            deltas.push(rate(&sample, true) - rate(&sample, false));
        }
        Some(Self {
            sentences: clusters.len(),
            pairs: pairs.len(),
            baseline_matched: rate(&pairs, false),
            other_matched: rate(&pairs, true),
            delta: rate(&pairs, true) - rate(&pairs, false),
            ci: (percentile(&deltas, 0.025), percentile(&deltas, 0.975)),
            lost: pairs
                .iter()
                .filter(|(b, o)| b.pass(false) && !o.pass(false))
                .count(),
            gained: pairs
                .iter()
                .filter(|(b, o)| !b.pass(false) && o.pass(false))
                .count(),
            delta_cer: mean(pairs.iter().map(|(b, o)| o.cer - b.cer)),
            delta_wer: mean(pairs.iter().map(|(b, o)| o.wer - b.wer)),
        })
    }
    pub fn to_json(&self) -> Value {
        json!({"sentences":self.sentences,"pairs":self.pairs,"baseline_meaning_match_pct":self.baseline_matched,
            "meaning_match_pct":self.other_matched,"delta_pp":self.delta,"delta_ci95_pp":[self.ci.0,self.ci.1],
            "lost":self.lost,"gained":self.gained,"delta_mean_cer":self.delta_cer,"delta_mean_wer":self.delta_wer})
    }
}

/// How much the result depends on the voice when the words are the same:
/// recordings of one sentence by different readers.
#[derive(Debug, Clone, PartialEq)]
pub struct Spread {
    /// Sentences with at least two readers, and their recordings.
    pub sentences: usize,
    pub recordings: usize,
    pub all_match: f64,
    pub none_match: f64,
    pub disagree: f64,
    /// Mean CER of each sentence's best, average and worst reading.
    pub best_cer: f64,
    pub mean_cer: f64,
    pub worst_cer: f64,
    /// Share of CER variance between readers of the same sentence (the rest is
    /// between sentences).
    pub within_share: f64,
    pub cer_p50: f64,
    pub cer_p90: f64,
    pub cer_max: f64,
    pub over_10: f64,
    pub over_20: f64,
}
impl Spread {
    pub fn of(clips: &[&Clip], raw: bool) -> Option<Self> {
        let mut by_sentence: BTreeMap<&str, Vec<&Clip>> = BTreeMap::new();
        for c in clips {
            by_sentence.entry(c.sentence.as_str()).or_default().push(c);
        }
        by_sentence.retain(|_, v| v.len() >= 2);
        if by_sentence.is_empty() {
            return None;
        }
        let groups: Vec<Vec<f64>> = by_sentence
            .values()
            .map(|v| v.iter().map(|c| c.cer_of(raw)).collect())
            .collect();
        let all: Vec<f64> = groups.iter().flatten().copied().collect();
        let grand = mean(all.iter().copied());
        let (mut within, mut between) = (0.0, 0.0);
        for g in &groups {
            let m = mean(g.iter().copied());
            within += g.iter().map(|x| (x - m).powi(2)).sum::<f64>();
            between += g.len() as f64 * (m - grand).powi(2);
        }
        let n = by_sentence.len();
        let count = |f: &dyn Fn(&Vec<&Clip>) -> bool| by_sentence.values().filter(|v| f(v)).count();
        let all_match = count(&|v| v.iter().all(|c| c.pass(raw)));
        let none_match = count(&|v| v.iter().all(|c| !c.pass(raw)));
        Some(Self {
            sentences: n,
            recordings: all.len(),
            all_match: pct(all_match, n),
            none_match: pct(none_match, n),
            disagree: pct(n - all_match - none_match, n),
            best_cer: mean(
                groups
                    .iter()
                    .map(|g| g.iter().copied().fold(f64::INFINITY, f64::min)),
            ),
            mean_cer: grand,
            worst_cer: mean(groups.iter().map(|g| g.iter().copied().fold(0.0, f64::max))),
            within_share: if within + between > 0.0 {
                within / (within + between)
            } else {
                0.0
            },
            cer_p50: percentile(&all, 0.5),
            cer_p90: percentile(&all, 0.9),
            cer_max: all.iter().copied().fold(0.0, f64::max),
            over_10: pct(all.iter().filter(|x| **x > 0.10).count(), all.len()),
            over_20: pct(all.iter().filter(|x| **x > 0.20).count(), all.len()),
        })
    }
    pub fn to_json(&self) -> Value {
        json!({"sentences":self.sentences,"recordings":self.recordings,
            "every_reader_matches_pct":self.all_match,"no_reader_matches_pct":self.none_match,
            "readers_disagree_pct":self.disagree,"best_reader_mean_cer":self.best_cer,
            "mean_cer":self.mean_cer,"worst_reader_mean_cer":self.worst_cer,
            "cer_variance_within_sentence_share":self.within_share,"cer_p50":self.cer_p50,
            "cer_p90":self.cer_p90,"cer_max":self.cer_max,"cer_over_0_10_pct":self.over_10,
            "cer_over_0_20_pct":self.over_20})
    }
}

/// Speaker metadata shown in reports. Names are pseudonyms chosen by the maintainer.
#[derive(Clone, Debug)]
pub struct Speaker {
    pub name: String,
    pub baseline: bool,
    pub synthetic: bool,
    pub mic: String,
    pub room: String,
    pub missing: usize,
}
impl Speaker {
    pub fn from_json(v: &Value) -> Result<Self, String> {
        Ok(Self {
            name: v["name"].as_str().ok_or("Speaker has no name")?.to_owned(),
            baseline: v["baseline"] == true,
            synthetic: v["synthetic"] == true,
            mic: v["mic"].as_str().unwrap_or("").to_owned(),
            room: v["room"].as_str().unwrap_or("").to_owned(),
            missing: v["missing"].as_u64().unwrap_or(0) as usize,
        })
    }
    fn label(&self) -> String {
        let mut label = cell(&self.name);
        if self.baseline {
            label.push_str(" (baseline)");
        }
        if self.synthetic {
            label.push_str(" (synthetic)");
        }
        label
    }
}

/// Table-safe text for maintainer-supplied labels.
fn cell(text: &str) -> String {
    text.replace(['|', '<', '>'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
fn p(value: f64) -> String {
    format!("{value:.1}%")
}
fn signed(value: f64, digits: usize) -> String {
    let text = format!("{value:+.digits$}");
    if text
        .trim_start_matches(['+', '-'])
        .chars()
        .all(|c| c == '0' || c == '.')
    {
        format!("{:.digits$}", 0.0)
    } else {
        text
    }
}

/// A group of the kit: key, label and the corpus buckets it draws from.
pub struct Group<'a> {
    pub key: &'a str,
    pub label: &'a str,
    pub buckets: Vec<&'a str>,
}

/// summary.json and report.md content for a per-speaker run.
pub fn speakers_report(
    meta: &Value,
    speakers: &[Speaker],
    clips: &[Clip],
    groups: &[Group],
) -> (Value, String) {
    let of = |name: &str| -> Vec<&Clip> { clips.iter().filter(|c| c.speaker == name).collect() };
    let baseline = speakers.iter().find(|s| s.baseline);
    let base_clips = baseline.map(|b| of(&b.name)).unwrap_or_default();
    let people: Vec<&Speaker> = speakers
        .iter()
        .filter(|s| !s.baseline && !s.synthetic)
        .collect();
    let seed = 2026;
    let mut md = String::from("# OLIV accuracy by speaker\n\n");
    md.push_str(&run_line(meta));
    md.push_str(
        "Meaning match: LaBSE similarity to the reference of at least 0.80, after Thai word \
segmentation. \"Speech model only\" scores the transcript before cleanup. WER and CER use \
OLIV's newmm/NFC normalisation. Latency is the median time per clip from audio file to \
final text, including audio conversion.\n\n",
    );
    md.push_str("| Speaker | Mic / room | Clips | Meaning match | Speech model only | WER | CER | Median latency |\n|---|---|---:|---:|---:|---:|---:|---:|\n");
    let mut per_speaker = serde_json::Map::new();
    for s in speakers {
        let Some(sum) = Summary::of(&of(&s.name)) else {
            continue;
        };
        let setting = [cell(&s.mic), cell(&s.room)]
            .into_iter()
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join(", ");
        md.push_str(&format!(
            "| {} | {} | {}{} | {} | {} | {:.3} | {:.3} | {:.2} s |\n",
            s.label(),
            if setting.is_empty() {
                "–".into()
            } else {
                setting
            },
            sum.n,
            if s.missing > 0 {
                format!(" ({} missing)", s.missing)
            } else {
                String::new()
            },
            p(sum.matched),
            p(sum.raw_matched),
            sum.wer,
            sum.cer,
            sum.latency_median
        ));
        let mut entry = sum.to_json();
        entry["baseline"] = s.baseline.into();
        entry["synthetic"] = s.synthetic.into();
        entry["missing"] = s.missing.into();
        per_speaker.insert(s.name.clone(), entry);
    }
    let failed: Vec<String> = speakers
        .iter()
        .filter_map(|s| {
            let n = of(&s.name).iter().filter(|c| c.cleanup_failed).count();
            (n > 0).then(|| format!("{} {n}", s.label()))
        })
        .collect();
    if !failed.is_empty() {
        md.push_str(&format!(
            "\nCleanup failed (the cleanup model errored or timed out) on: {}. Those clips keep the speech model's text.\n",
            failed.join(", ")
        ));
    }
    let mut comparisons = serde_json::Map::new();
    if let Some(b) = baseline {
        let mut rows: Vec<(String, Vec<&Clip>)> = speakers
            .iter()
            .filter(|s| !s.baseline)
            .map(|s| (s.label(), of(&s.name)))
            .collect();
        if people.len() >= 2 {
            rows.push((
                format!("All {} people, pooled", people.len()),
                people.iter().flat_map(|s| of(&s.name)).collect(),
            ));
        }
        let mut table = String::new();
        for (label, other) in &rows {
            let Some(pair) = Paired::of(&base_clips, other, seed) else {
                continue;
            };
            table.push_str(&format!(
                "| {} | {} | {} | {} | {} ({} to {}) | {} / {} | {} | {} |\n",
                label,
                pair.sentences,
                p(pair.baseline_matched),
                p(pair.other_matched),
                signed(pair.delta, 1),
                signed(pair.ci.0, 1),
                signed(pair.ci.1, 1),
                pair.lost,
                pair.gained,
                signed(pair.delta_cer, 3),
                signed(pair.delta_wer, 3)
            ));
            comparisons.insert(label.clone(), pair.to_json());
        }
        if !table.is_empty() {
            md.push_str(&format!(
                "\n## Against {} on the same sentences\n\nEach row pairs a speaker's clip with {}'s recording of the same sentence. \
Δ is in percentage points with a 95% bootstrap interval over sentences. \"Lost\" counts clips whose sentence {} got right and the speaker did not; \
\"gained\" the reverse.\n\n| Speaker | Sentences | {} | Speaker | Δ meaning match (95% CI) | Lost / gained | Δ CER | Δ WER |\n|---|---:|---:|---:|---:|---:|---:|---:|\n",
                cell(&b.name), cell(&b.name), cell(&b.name), cell(&b.name)
            ));
            md.push_str(&table);
        }
    }
    let mut by_group = serde_json::Map::new();
    let shown: Vec<&Speaker> = speakers
        .iter()
        .filter(|s| clips.iter().any(|c| c.speaker == s.name))
        .collect();
    let header = |title: &str| {
        let mut h = format!("\n### {title}\n\n| Group (corpus buckets) |");
        for s in &shown {
            h.push_str(&format!(" {} |", s.label()));
        }
        h.push_str("\n|---|");
        h.push_str(&"---:|".repeat(shown.len()));
        h.push('\n');
        h
    };
    let mut match_table = header("Meaning match by group (clips)");
    let mut cer_table = header("CER by group");
    for g in groups {
        let mut match_row = format!("| {} ({}) |", g.label, g.buckets.join(", "));
        let mut cer_row = match_row.clone();
        let mut entry = serde_json::Map::new();
        for s in &shown {
            let selected: Vec<&Clip> = clips
                .iter()
                .filter(|c| c.speaker == s.name && c.group == g.key)
                .collect();
            match Summary::of(&selected) {
                Some(sum) => {
                    match_row.push_str(&format!(" {} ({}) |", p(sum.matched), sum.n));
                    cer_row.push_str(&format!(" {:.3} |", sum.cer));
                    entry.insert(s.name.clone(), sum.to_json());
                }
                None => {
                    match_row.push_str(" – |");
                    cer_row.push_str(" – |");
                }
            }
        }
        match_table.push_str(&match_row);
        match_table.push('\n');
        cer_table.push_str(&cer_row);
        cer_table.push('\n');
        by_group.insert(g.key.to_owned(), Value::Object(entry));
    }
    md.push_str("\n## By group\n");
    md.push_str(&match_table);
    md.push_str(&cer_table);
    md.push_str(
        "\nGroups hold a handful of sentences each, so one clip moves a cell by many points. \
Read groups for direction, not size. Synthetic voices are a pipeline check, not an estimate \
for people, and are left out of the pooled row.\n",
    );
    let summary = json!({"kind":"speakers","meta":meta,"speakers":per_speaker,
        "against_baseline":comparisons,"by_group":by_group});
    (summary, md)
}

/// summary.json and report.md content for the FLEURS multi-reader proxy.
pub fn fleurs_report(meta: &Value, clips: &[Clip]) -> (Value, String) {
    let all: Vec<&Clip> = clips.iter().collect();
    let mut md = String::from("# OLIV on many Thai voices: FLEURS proxy\n\n");
    md.push_str(&run_line(meta));
    md.push_str(&format!(
        "FLEURS Thai test split (CC-BY-4.0), {} sentences sampled with seed {} out of {} that have two or more readers; \
every recording of each sampled sentence: {} recordings. FLEURS has each sentence read by up to three different \
native speakers and does not publish speaker IDs, so this report compares readers of the same sentence rather than \
named speakers. Content is read Wikipedia-style Thai with little English, unlike OLIV's dictation corpus.\n\n",
        meta["sentences_sampled"], meta["seed"].as_str().unwrap_or(""), meta["sentences_with_readers"], clips.len()
    ));
    let mut summary = json!({"kind":"fleurs","meta":meta});
    md.push_str("| Pipeline | Recordings | Meaning match | WER | CER | Median latency |\n|---|---:|---:|---:|---:|---:|\n");
    if let Some(sum) = Summary::of(&all) {
        md.push_str(&format!(
            "| Full pipeline (speech model + OLIV cleanup) | {} | {} | {:.3} | {:.3} | {:.2} s |\n| Speech model only | {} | {} | {:.3} | {:.3} | – |\n",
            sum.n, p(sum.matched), sum.wer, sum.cer, sum.latency_median,
            sum.n, p(sum.raw_matched), sum.raw_wer, sum.raw_cer
        ));
        summary["overall"] = sum.to_json();
        if sum.cleanup_failed > 0 {
            md.push_str(&format!(
                "\nCleanup failed (the cleanup model errored or timed out) on {} recordings; they keep the speech model's text.\n",
                sum.cleanup_failed
            ));
        }
    }
    let spreads: Vec<(&str, Option<Spread>)> = vec![
        ("full", Spread::of(&all, false)),
        ("stt_only", Spread::of(&all, true)),
    ];
    md.push_str("\n## Same sentence, different readers\n\n| | Full pipeline | Speech model only |\n|---|---:|---:|\n");
    type Row = (&'static str, fn(&Spread) -> String);
    let rows: [Row; 10] = [
        ("Sentences (with 2+ readers)", |s| s.sentences.to_string()),
        ("Every reader gets the meaning", |s| p(s.all_match)),
        ("Readers disagree (voice decides)", |s| p(s.disagree)),
        ("No reader gets the meaning", |s| p(s.none_match)),
        ("CER, best reader of each sentence", |s| {
            format!("{:.3}", s.best_cer)
        }),
        ("CER, all readers", |s| format!("{:.3}", s.mean_cer)),
        ("CER, worst reader of each sentence", |s| {
            format!("{:.3}", s.worst_cer)
        }),
        ("Share of CER variance between readers", |s| {
            p(100.0 * s.within_share)
        }),
        ("CER median / 90th percentile", |s| {
            format!("{:.3} / {:.3}", s.cer_p50, s.cer_p90)
        }),
        ("Recordings with CER above 0.10 / 0.20", |s| {
            format!("{} / {}", p(s.over_10), p(s.over_20))
        }),
    ];
    for (label, f) in rows {
        md.push_str(&format!("| {label} |"));
        for (_, s) in &spreads {
            md.push_str(&format!(" {} |", s.as_ref().map_or("–".into(), f)));
        }
        md.push('\n');
    }
    for (key, s) in &spreads {
        if let Some(s) = s {
            summary[format!("readers_{key}")] = s.to_json();
        }
    }
    md.push_str(
        "\n\"Share of CER variance between readers\" splits the variance of per-recording CER into the part \
between readers of the same sentence (voice, microphone and room) and the part between sentences \
(content). A low share means the words, not the voice, decide most errors.\n",
    );
    (summary, md)
}

fn run_line(meta: &Value) -> String {
    let short = |k: &str, n: usize| {
        meta[k]
            .as_str()
            .map(|s| s.chars().take(n).collect::<String>())
            .unwrap_or_else(|| "unknown".into())
    };
    format!(
        "Run {} on {}, macOS {}, OLIV commit {}{}, speech engine `{}`, cleanup `{}`.\n\n",
        short("date", 10),
        short("chip", 40),
        short("macos", 12),
        short("git_commit", 7),
        if meta["git_dirty"] == true {
            " with local changes"
        } else {
            ""
        },
        short("engine", 40),
        short("cleanup_repo", 60),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clip(speaker: &str, sentence: &str, group: &str, sim: f64, cer: f64) -> Clip {
        Clip {
            speaker: speaker.into(),
            sentence: sentence.into(),
            group: group.into(),
            sim,
            raw_sim: sim - 0.1,
            wer: cer * 2.0,
            cer,
            raw_wer: cer * 3.0,
            raw_cer: cer + 0.05,
            latency_s: 1.0,
            cleanup_failed: false,
        }
    }

    #[test]
    fn summary_counts_threshold_inclusive_and_interpolates_latency() {
        let mut slow = clip("a", "s2", "g", 0.79, 0.3);
        slow.latency_s = 3.0;
        let clips = [clip("a", "s1", "g", 0.80, 0.1), slow];
        let s = Summary::of(&clips.iter().collect::<Vec<_>>()).unwrap();
        assert_eq!(s.n, 2);
        assert_eq!(s.matched, 50.0);
        assert_eq!(s.raw_matched, 0.0);
        assert!((s.cer - 0.2).abs() < 1e-12);
        assert_eq!(s.latency_median, 2.0);
        assert!((s.latency_p90 - 2.8).abs() < 1e-12);
        assert!(Summary::of(&[]).is_none());
    }

    #[test]
    fn paired_uses_only_shared_sentences_and_counts_flips() {
        let base = [
            clip("dev", "s1", "g", 0.9, 0.0),
            clip("dev", "s2", "g", 0.9, 0.1),
            clip("dev", "s3", "g", 0.5, 0.4),
            clip("dev", "s4", "g", 0.9, 0.0),
        ];
        let other = [
            clip("x", "s1", "g", 0.9, 0.1),
            clip("x", "s2", "g", 0.6, 0.3),
            clip("x", "s3", "g", 0.85, 0.2),
            clip("x", "s9", "g", 0.1, 1.0),
        ];
        let b: Vec<&Clip> = base.iter().collect();
        let o: Vec<&Clip> = other.iter().collect();
        let p = Paired::of(&b, &o, 7).unwrap();
        assert_eq!((p.sentences, p.pairs), (3, 3));
        assert!((p.baseline_matched - 200.0 / 3.0).abs() < 1e-9);
        assert!((p.other_matched - 200.0 / 3.0).abs() < 1e-9);
        assert!(p.delta.abs() < 1e-9);
        assert_eq!((p.lost, p.gained), (1, 1));
        assert!((p.delta_cer - (0.1 + 0.2 - 0.2) / 3.0).abs() < 1e-12);
        assert!(p.ci.0 <= p.delta && p.delta <= p.ci.1);
        assert_eq!(
            p,
            Paired::of(&b, &o, 7).unwrap(),
            "seeded bootstrap is deterministic"
        );
        assert!(Paired::of(&b, &o[3..], 7).is_none());
    }

    #[test]
    fn identical_voices_have_a_zero_width_interval() {
        let base = [
            clip("dev", "s1", "g", 0.9, 0.0),
            clip("dev", "s2", "g", 0.2, 0.5),
        ];
        let other = [
            clip("x", "s1", "g", 0.9, 0.0),
            clip("x", "s2", "g", 0.2, 0.5),
        ];
        let p = Paired::of(
            &base.iter().collect::<Vec<_>>(),
            &other.iter().collect::<Vec<_>>(),
            1,
        )
        .unwrap();
        assert_eq!((p.delta, p.ci), (0.0, (0.0, 0.0)));
    }

    #[test]
    fn spread_separates_reader_and_sentence_variance() {
        // s1: readers disagree; s2: identical readers; s3 has one reader and is ignored.
        let clips = [
            clip("r1", "s1", "g", 0.9, 0.0),
            clip("r2", "s1", "g", 0.5, 0.2),
            clip("r3", "s2", "g", 0.9, 0.1),
            clip("r4", "s2", "g", 0.9, 0.1),
            clip("r5", "s3", "g", 0.1, 0.9),
        ];
        let refs: Vec<&Clip> = clips.iter().collect();
        let s = Spread::of(&refs, false).unwrap();
        assert_eq!((s.sentences, s.recordings), (2, 4));
        assert_eq!((s.all_match, s.disagree, s.none_match), (50.0, 50.0, 0.0));
        assert!((s.best_cer - 0.05).abs() < 1e-12);
        assert!((s.worst_cer - 0.15).abs() < 1e-12);
        // within: (0.1² + 0.1²) = 0.02; between: 2·(0.1−0.1)² + 2·(0.1−0.1)² = 0.
        assert!((s.within_share - 1.0).abs() < 1e-12);
        assert_eq!(s.over_10, 25.0);
        let raw = Spread::of(&refs, true).unwrap();
        assert!(
            (raw.best_cer - 0.10).abs() < 1e-12,
            "raw CER is 0.05 higher"
        );
        assert!(Spread::of(&refs[4..], false).is_none());
    }

    #[test]
    fn reports_carry_numbers_and_labels_only() {
        let speakers = vec![
            Speaker {
                name: "developer".into(),
                baseline: true,
                synthetic: false,
                mic: "built-in".into(),
                room: "office".into(),
                missing: 0,
            },
            Speaker {
                name: "s1".into(),
                baseline: false,
                synthetic: false,
                mic: "AirPods | <b>".into(),
                room: String::new(),
                missing: 2,
            },
            Speaker {
                name: "tts-kanya".into(),
                baseline: false,
                synthetic: true,
                mic: String::new(),
                room: String::new(),
                missing: 0,
            },
        ];
        let clips = vec![
            clip("developer", "th01", "everyday", 0.95, 0.0),
            clip("developer", "nm01", "numbers", 0.9, 0.1),
            clip("s1", "th01", "everyday", 0.7, 0.3),
            clip("tts-kanya", "th01", "everyday", 0.9, 0.0),
            Clip {
                cleanup_failed: true,
                ..clip("tts-kanya", "nm01", "numbers", 0.9, 0.0)
            },
        ];
        let groups = [
            Group {
                key: "everyday",
                label: "Everyday",
                buckets: vec!["th"],
            },
            Group {
                key: "numbers",
                label: "Numbers",
                buckets: vec!["nm"],
            },
        ];
        let (summary, md) = speakers_report(
            &json!({"git_commit":"abcdef123","engine":"typhoon-turbo-mlx"}),
            &speakers,
            &clips,
            &groups,
        );
        assert!(md.contains("| developer (baseline) | built-in, office | 2 | 100.0%"));
        assert!(
            md.contains("| s1 | AirPods b | 1 (2 missing) | 0.0%"),
            "{md}"
        );
        assert!(
            md.contains("| s1 | 1 | 100.0% | 0.0% | -100.0 (-100.0 to -100.0) | 1 / 0 |"),
            "{md}"
        );
        assert!(md.contains("tts-kanya (synthetic)"));
        assert!(md.contains(
            "Cleanup failed (the cleanup model errored or timed out) on: tts-kanya (synthetic) 1."
        ));
        assert_eq!(summary["speakers"]["tts-kanya"]["cleanup_failed"], 1);
        assert!(
            !md.contains("people, pooled"),
            "one person and one synthetic voice are not pooled"
        );
        assert!(
            md.contains("| Numbers (nm) | 100.0% (1) | – | 100.0% (1) |"),
            "{md}"
        );
        assert!(!md.contains("<b>"));
        assert_eq!(summary["against_baseline"]["s1"]["lost"], 1);
        assert_eq!(summary["by_group"]["numbers"]["developer"]["n"], 1);

        let readers = vec![
            clip("a", "1", "fleurs", 0.9, 0.05),
            clip("b", "1", "fleurs", 0.7, 0.25),
        ];
        let (summary, md) = fleurs_report(
            &json!({"sentences_sampled":1,"seed":"2026","sentences_with_readers":10}),
            &readers,
        );
        assert!(
            md.contains("| Readers disagree (voice decides) | 100.0% |"),
            "{md}"
        );
        assert_eq!(summary["overall"]["n"], 2);
        assert_eq!(summary["readers_full"]["readers_disagree_pct"], 100.0);
    }

    #[test]
    fn signed_values_never_show_negative_zero() {
        assert_eq!(signed(-0.00001, 3), "0.000");
        assert_eq!(signed(0.26, 1), "+0.3");
        assert_eq!(signed(-1.26, 1), "-1.3");
    }
}
