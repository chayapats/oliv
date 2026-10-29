//! Metrics files for a ContextASR run: upstream-compatible `metrics.json`, plus
//! OLIV stage attribution, latency, WER, `metrics.csv`, `scores.jsonl` (per pair,
//! for paired comparisons) and a Markdown report without transcripts.
use super::mt::PyRandom;
use super::score::{self, UttScore, ratio};
use super::{Dataset, read_jsonl, sha256_hex};
use crate::Result;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fmt::Write as _;
use std::path::Path;

struct Row {
    utt_id: String,
    condition: String,
    split: String,
    text: String,
    detail: Value,
}

struct Scored {
    row: Row,
    fin: UttScore,
    raw: Option<UttScore>,
    words: (usize, usize),
}

fn word_counts(reference: &str, hypothesis: &str) -> (usize, usize) {
    use oliv_pipeline::metrics::{normalize, tokenize};
    let r = tokenize(&normalize(reference));
    let h = tokenize(&normalize(hypothesis));
    (crate::metrics::distance(&r, &h), r.len())
}

fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
    Some(sorted[rank - 1])
}

fn stats(mut values: Vec<f64>) -> Value {
    values.retain(|v| v.is_finite());
    values.sort_by(f64::total_cmp);
    if values.is_empty() {
        return Value::Null;
    }
    json!({"median": percentile(&values, 0.5), "p95": percentile(&values, 0.95),
        "mean": values.iter().sum::<f64>() / values.len() as f64, "n": values.len()})
}

fn num(v: &Value) -> Option<f64> {
    v.as_f64()
}

fn score_rows(data: &Dataset, rows: Vec<Row>) -> Result<Vec<Scored>> {
    let mut seen = HashSet::new();
    rows.into_iter()
        .map(|row| {
            if !seen.insert((row.utt_id.clone(), row.condition.clone())) {
                return Err(format!(
                    "Duplicate hypothesis for {} / {}",
                    row.utt_id, row.condition
                )
                .into());
            }
            let u = data
                .utterance(&row.utt_id)
                .ok_or_else(|| format!("Unknown utterance {}", row.utt_id))?;
            let list = data.list(&row.utt_id, &row.condition);
            if row.condition != "none" && list.is_none() {
                return Err(
                    format!("No frozen list for {} / {}", row.utt_id, row.condition).into(),
                );
            }
            let fin = score::score_pair(u, &row.condition, list, &row.text);
            let raw = row.detail["raw"]
                .as_str()
                .map(|raw| score::score_pair(u, &row.condition, list, raw));
            let words = word_counts(&u.text, &row.text);
            Ok(Scored {
                row,
                fin,
                raw,
                words,
            })
        })
        .collect()
}

fn condition_metrics(data: &Dataset, rows: &[&Scored]) -> Value {
    let fin: Vec<&UttScore> = rows.iter().map(|s| &s.fin).collect();
    let mut m = score::condition_report(&fin);
    let (wd, wr) = rows
        .iter()
        .fold((0, 0), |a, s| (a.0 + s.words.0, a.1 + s.words.1));
    m["wer"] = json!(ratio(wd, wr));
    // Entity-free utterances: pure over-biasing control.
    let free: Vec<&UttScore> = rows
        .iter()
        .filter(|s| data.utterance(&s.row.utt_id).is_some_and(|u| u.entity_free))
        .map(|s| &s.fin)
        .collect();
    m["entity_free"] =
        json!({"n": free.len(), "cer": score::total(free.iter().copied()).overall.rate()});
    let mut by_split = serde_json::Map::new();
    let splits: BTreeSet<&str> = rows
        .iter()
        .map(|s| s.row.utt_id.split('-').next().unwrap_or(""))
        .collect();
    for split in splits {
        let part: Vec<&UttScore> = rows
            .iter()
            .filter(|s| s.row.utt_id.starts_with(&format!("{split}-")))
            .map(|s| &s.fin)
            .collect();
        let t = score::total(part.iter().copied());
        by_split.insert(split.into(), json!({"n": part.len(), "cer": t.overall.rate(), "b_cer": t.biased.rate(),
            "entity_recall": ratio(t.gold_recalled, t.gold_total), "script_compliance": ratio(t.script_compliant, t.script_expected)}));
    }
    m["by_id_prefix"] = Value::Object(by_split);
    if rows.iter().any(|s| s.raw.is_some()) {
        let raw: Vec<&UttScore> = rows.iter().filter_map(|s| s.raw.as_ref()).collect();
        let mut stage = score::aggregate(&raw);
        stage.as_object_mut().unwrap().remove("counts");
        m["asr_stage"] = stage;
        let mut flow = BTreeMap::from([("kept", 0), ("gained", 0), ("lost", 0), ("missed", 0)]);
        let (mut listed_gained, mut listed_lost, mut fires_added, mut fires_removed) = (0, 0, 0, 0);
        for s in rows {
            let Some(raw) = &s.raw else { continue };
            for (r, f) in raw.recalled.iter().zip(&s.fin.recalled) {
                *flow
                    .get_mut(match (r, f) {
                        (true, true) => "kept",
                        (false, true) => "gained",
                        (true, false) => "lost",
                        (false, false) => "missed",
                    })
                    .unwrap() += 1;
            }
            for (r, f) in raw.listed_hit.iter().zip(&s.fin.listed_hit) {
                listed_gained += usize::from(!r && *f);
                listed_lost += usize::from(*r && !f);
            }
            fires_added += s
                .fin
                .fired
                .iter()
                .filter(|x| !raw.fired.contains(x))
                .count();
            fires_removed += raw
                .fired
                .iter()
                .filter(|x| !s.fin.fired.contains(x))
                .count();
        }
        m["cleanup_attribution"] = json!({"gold_entities": flow, "listed_form_gained": listed_gained,
            "listed_form_lost": listed_lost, "fires_introduced": fires_added, "fires_removed": fires_removed,
            "utterances_changed": rows.iter().filter(|s| s.row.detail["raw"].as_str().is_some_and(|r| r != s.row.text)).count(),
            "utterances_cer_worse": rows.iter().filter(|s| s.raw.as_ref().is_some_and(|r| s.fin.overall.err() > r.overall.err())).count(),
            "utterances_cer_better": rows.iter().filter(|s| s.raw.as_ref().is_some_and(|r| s.fin.overall.err() < r.overall.err())).count()});
    }
    let d = |k: &str| {
        rows.iter()
            .filter_map(|s| num(&s.row.detail[k]))
            .collect::<Vec<_>>()
    };
    if rows.iter().any(|s| s.row.detail.get("t_stt").is_some()) {
        let e2e: Vec<f64> = rows
            .iter()
            .filter_map(|s| {
                Some(num(&s.row.detail["t_stt"])? + num(&s.row.detail["t_cleanup"]).unwrap_or(0.0))
            })
            .collect();
        let llm: Vec<f64> = rows
            .iter()
            .filter(|s| s.row.detail["llm_ran"] == true)
            .filter_map(|s| num(&s.row.detail["t_llm"]))
            .collect();
        m["latency_s"] = json!({"end_to_end": stats(e2e), "stt": stats(d("t_stt")), "cleanup": stats(d("t_cleanup")),
            "llm_when_run": stats(llm), "request_wall": stats(d("t_wall"))});
        let mut flags: BTreeMap<String, usize> = BTreeMap::new();
        for s in rows {
            if let Some(f) = s.row.detail["guardrail_flag"]
                .as_str()
                .filter(|f| !f.is_empty())
            {
                *flags.entry(f.into()).or_default() += 1;
            }
        }
        let count = |f: &dyn Fn(&Value) -> bool| rows.iter().filter(|s| f(&s.row.detail)).count();
        m["pipeline"] = json!({
            "llm_ran": count(&|d| d["llm_ran"] == true), "guardrail_flags": flags,
            "vocab_fired_rows": count(&|d| d["vocab_fired"].as_u64().unwrap_or(0) > 0),
            "vocab_fired_total": rows.iter().filter_map(|s| s.row.detail["vocab_fired"].as_u64()).sum::<u64>(),
            "no_speech": count(&|d| d["no_speech"] == true), "errors": count(&|d| d.get("error").is_some()),
            "stt_redecoded": count(&|d| d["stt_redecoded"] == true),
        });
    }
    m
}

fn pair_hash(rows: &[Scored]) -> String {
    let mut keys: Vec<String> = rows
        .iter()
        .map(|s| format!("{}\t{}", s.row.utt_id, s.row.condition))
        .collect();
    keys.sort();
    sha256_hex(keys.join("\n").as_bytes())
}

fn build(data: &Dataset, rows: Vec<Row>, header: Value, out: &Path) -> Result<Value> {
    let scored = score_rows(data, rows)?;
    if scored.is_empty() {
        return Err("No hypotheses to score".into());
    }
    let mut by_cond: BTreeMap<&str, Vec<&Scored>> = BTreeMap::new();
    for s in &scored {
        by_cond.entry(&s.row.condition).or_default().push(s);
    }
    let mut conditions = serde_json::Map::new();
    for (c, rows) in &by_cond {
        conditions.insert((*c).into(), condition_metrics(data, rows));
    }
    let get = |c: &str, k: &str| conditions.get(c).and_then(|m| m[k].as_f64());
    let delta = |a: Option<f64>, b: Option<f64>| Some(a? - b?);
    let deltas = json!({
        "recall_bias0_minus_none": delta(get("bias@0", "entity_recall"), get("none", "entity_recall")),
        "recall_bias50_minus_none": delta(get("bias@50", "entity_recall"), get("none", "entity_recall")),
        "cer_bias0_minus_none": delta(get("bias@0", "cer"), get("none", "cer")),
        "cer_bias50_minus_none": delta(get("bias@50", "cer"), get("none", "cer")),
        "cer_dis50_minus_none": delta(get("dis@50", "cer"), get("none", "cer")),
    });
    let mut metrics = header;
    metrics["scorer"] = json!({"port_of": "wayu-ai/thai-contextasr-bench scorer/ (stdlib alignment)",
        "upstream_revision": super::UPSTREAM_REVISION, "wer": "OLIV newmm words after OLIV metrics::normalize"});
    metrics["n_pairs"] = scored.len().into();
    metrics["pairs_sha256"] = pair_hash(&scored).into();
    metrics["conditions"] = Value::Object(conditions);
    metrics["deltas"] = deltas;
    std::fs::create_dir_all(out)?;
    std::fs::write(
        out.join("metrics.json"),
        serde_json::to_vec_pretty(&metrics)?,
    )?;

    let mut lines = String::new();
    for s in &scored {
        let f = &s.fin;
        let mut row = json!({"utt_id": s.row.utt_id, "condition": s.row.condition, "split": s.row.split,
            "overall": [f.overall.err(), f.overall.refn], "biased": [f.biased.err(), f.biased.refn],
            "unbiased": [f.unbiased.err(), f.unbiased.refn], "gold": [f.gold_recalled, f.gold_total],
            "expected": f.script_expected, "listed": [f.script_compliant, f.listed_total],
            "fired": [f.distractors_fired, f.distractors_total], "fired_forms": f.fired, "words": [s.words.0, s.words.1]});
        let d = &s.row.detail;
        if let Some(t) = d["t_stt"].as_f64() {
            row["t_e2e"] = json!(t + d["t_cleanup"].as_f64().unwrap_or(0.0));
            row["llm_ran"] = d["llm_ran"].clone();
        }
        if let Some(r) = &s.raw {
            row["raw_overall"] = json!([r.overall.err(), r.overall.refn]);
            row["raw_gold"] = json!([r.gold_recalled, r.gold_total]);
            row["raw_fired_forms"] = json!(r.fired);
        }
        writeln!(lines, "{}", serde_json::to_string(&row)?)?;
    }
    std::fs::write(out.join("scores.jsonl"), lines)?;
    // Per gold entity outcomes for failure analysis (quotes entity strings only).
    let mut entities = String::new();
    for s in &scored {
        let u = data.utterance(&s.row.utt_id).unwrap();
        let list = data.list(&s.row.utt_id, &s.row.condition);
        for (i, (span, forms)) in u.entities.iter().enumerate() {
            let listed = list.and_then(|l| l.gold_listed.get(span));
            let row = json!({"utt_id": s.row.utt_id, "condition": s.row.condition, "span": span, "forms": forms,
                "listed": listed, "listed_script": listed.map(|l| if l.chars().any(|c| ('\u{e00}'..='\u{e7f}').contains(&c)) { "thai" } else { "latin" }),
                "recalled": s.fin.recalled[i], "listed_hit": s.fin.listed_hit[i],
                "raw_recalled": s.raw.as_ref().map(|r| r.recalled[i]), "raw_listed_hit": s.raw.as_ref().map(|r| r.listed_hit[i])});
            writeln!(entities, "{}", serde_json::to_string(&row)?)?;
        }
    }
    std::fs::write(out.join("entities.jsonl"), entities)?;
    std::fs::write(out.join("metrics.csv"), csv(&metrics))?;
    std::fs::write(out.join("report.md"), markdown(&metrics))?;
    for (c, m) in metrics["conditions"].as_object().unwrap() {
        println!(
            "{c:>8}: CER {:.4} | B-CER {:.4} | U-CER {:.4} | recall {} | listed {} | fires {} | n={}",
            m["cer"].as_f64().unwrap_or(0.0),
            m["b_cer"].as_f64().unwrap_or(0.0),
            m["u_cer"].as_f64().unwrap_or(0.0),
            pct(&m["entity_recall"]),
            pct(&m["script_compliance"]),
            pct3(&m["distractor_fire_rate"]),
            m["n_utts"]
        );
    }
    println!("Wrote {}", out.join("report.md").display());
    Ok(metrics)
}

pub fn score_run(data: &Dataset, dir: &Path) -> Result<()> {
    let run: Value = serde_json::from_slice(&std::fs::read(dir.join("run.json"))?)?;
    let config = &run["config"];
    let rows: Vec<Row> = read_jsonl(&dir.join("details.jsonl"))?
        .into_iter()
        .map(|d| Row {
            utt_id: d["utt_id"].as_str().unwrap_or("").into(),
            condition: d["condition"].as_str().unwrap_or("").into(),
            split: d["split"].as_str().unwrap_or("").into(),
            text: d["text"].as_str().unwrap_or("").into(),
            detail: d,
        })
        .collect();
    let conditions: Vec<String> = config["conditions"]
        .as_array()
        .ok_or("run.json lacks conditions")?
        .iter()
        .filter_map(|c| c.as_str().map(str::to_owned))
        .collect();
    let selected = data.select(
        config["limit"].as_u64().unwrap_or(0) as usize,
        config["seed"].as_str().unwrap_or("2026"),
    );
    let planned = data.pairs(&selected, &conditions).len();
    let mut header =
        json!({"label": run["label"], "config": config, "environment": run["environment"]});
    header["planned_pairs"] = planned.into();
    header["complete"] = (rows.len() == planned).into();
    if rows.len() != planned {
        eprintln!(
            "Warning: {} of {planned} planned pairs are present; metrics are partial",
            rows.len()
        );
    }
    build(data, rows, header, dir).map(|_| ())
}

pub fn score_hyps(data: &Dataset, hyps: &Path, out: &Path) -> Result<()> {
    let rows = read_jsonl(hyps)?
        .into_iter()
        .map(|h| {
            let utt_id: String = h["utt_id"].as_str().ok_or("hyp missing utt_id")?.into();
            let split = data
                .utterance(&utt_id)
                .map(|u| u.split.clone())
                .unwrap_or_default();
            Ok(Row {
                condition: h["condition"]
                    .as_str()
                    .ok_or("hyp missing condition")?
                    .into(),
                text: h["text"].as_str().ok_or("hyp missing text")?.into(),
                utt_id,
                split,
                detail: Value::Null,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let label = hyps
        .parent()
        .and_then(|p| p.file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    build(
        data,
        rows,
        json!({"label": label, "hyps": hyps, "lists_sha256": data.lists_sha256}),
        out,
    )
    .map(|_| ())
}

/// Percent with three decimals: fire rates are fractions of a percent.
fn pct3(v: &Value) -> String {
    v.as_f64()
        .map_or("—".into(), |x| format!("{:.3}", 100.0 * x))
}
fn pct(v: &Value) -> String {
    v.as_f64()
        .map_or("—".into(), |x| format!("{:.1}", 100.0 * x))
}
fn secs(v: &Value) -> String {
    v.as_f64().map_or("—".into(), |x| format!("{x:.3}"))
}

const CSV_COLUMNS: [&str; 12] = [
    "cer",
    "b_cer",
    "u_cer",
    "wer",
    "entity_recall",
    "script_compliance",
    "listed_form_accuracy",
    "distractor_fire_rate",
    "latency_median_s",
    "latency_p95_s",
    "n_utts",
    "llm_ran",
];

fn csv(metrics: &Value) -> String {
    let mut out = format!("condition,{}\n", CSV_COLUMNS.join(","));
    for (c, m) in metrics["conditions"].as_object().unwrap() {
        let cell = |k: &str| -> String {
            let v = match k {
                "latency_median_s" => &m["latency_s"]["end_to_end"]["median"],
                "latency_p95_s" => &m["latency_s"]["end_to_end"]["p95"],
                "llm_ran" => &m["pipeline"]["llm_ran"],
                _ => &m[k],
            };
            if v.is_null() {
                String::new()
            } else {
                v.to_string()
            }
        };
        let cells: Vec<String> = CSV_COLUMNS.iter().map(|k| cell(k)).collect();
        writeln!(out, "{c},{}", cells.join(",")).unwrap();
    }
    out
}

fn markdown(metrics: &Value) -> String {
    let mut md = String::new();
    let config = &metrics["config"];
    let env = &metrics["environment"];
    writeln!(
        md,
        "# Thai ContextASR Bench — {}\n",
        metrics["label"].as_str().unwrap_or("")
    )
    .unwrap();
    if !config.is_null() {
        writeln!(
            md,
            "- Pipeline `{}`, engine `{}` ({} @ {}), cleanup model {} @ {}, prompt {}",
            config["pipeline"].as_str().unwrap_or(""),
            config["engine"].as_str().unwrap_or(""),
            env["engine_repo"].as_str().unwrap_or(""),
            env["engine_revision"].as_str().unwrap_or("?"),
            env["cleanup_repo"].as_str().unwrap_or(""),
            env["cleanup_revision"].as_str().unwrap_or("?"),
            env["cleanup_prompt"].as_str().unwrap_or("")
        )
        .unwrap();
        writeln!(md, "- Coverage: {} utterances (limit {}, seed {}; id prefixes {}), {} of {} planned pairs{}", config["n_utterances"],
            config["limit"], config["seed"], config["id_prefix_counts"], metrics["n_pairs"], metrics["planned_pairs"],
            if metrics["complete"] == true { "" } else { " — PARTIAL" }).unwrap();
        let pinned = config["lists_sha256"] == super::PINNED_LISTS_SHA256;
        writeln!(
            md,
            "- Upstream revision `{}`; lists sha256 {}. OLIV commit `{}`{}; {} / macOS {}",
            &config["upstream_revision"].as_str().unwrap_or("")[..7],
            if pinned {
                "verified"
            } else {
                "NOT the pinned upstream file"
            },
            env["git_commit"]
                .as_str()
                .map_or("?", |c| &c[..c.len().min(7)]),
            if env["git_dirty"] == true {
                " (uncommitted changes)"
            } else {
                ""
            },
            env["chip"].as_str().unwrap_or("?"),
            env["macos"].as_str().unwrap_or("?")
        )
        .unwrap();
    }
    writeln!(
        md,
        "- Pair set sha256 `{}`\n",
        &metrics["pairs_sha256"].as_str().unwrap_or("")[..12]
    )
    .unwrap();
    writeln!(md, "All rates are percentages. CER/B-CER/U-CER/recall/listed/fires follow the upstream scorer exactly; WER and latency are OLIV additions.\n").unwrap();
    writeln!(md, "| condition | n | CER | CER 95% CI | B-CER | U-CER | WER | recall | listed (of recalled) | listed-form acc | fire | median s | p95 s |").unwrap();
    writeln!(md, "|---|---|---|---|---|---|---|---|---|---|---|---|---|").unwrap();
    let conds = metrics["conditions"].as_object().unwrap();
    for (c, m) in conds {
        let ci = &m["ci95"]["cer"];
        writeln!(
            md,
            "| {c} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |",
            m["n_utts"],
            pct(&m["cer"]),
            if ci.is_array() {
                format!("{}–{}", pct(&ci[0]), pct(&ci[1]))
            } else {
                "—".into()
            },
            pct(&m["b_cer"]),
            pct(&m["u_cer"]),
            pct(&m["wer"]),
            pct(&m["entity_recall"]),
            pct(&m["script_compliance"]),
            pct(&m["listed_form_accuracy"]),
            pct3(&m["distractor_fire_rate"]),
            secs(&m["latency_s"]["end_to_end"]["median"]),
            secs(&m["latency_s"]["end_to_end"]["p95"])
        )
        .unwrap();
    }
    let d = &metrics["deltas"];
    writeln!(md, "\nContext deltas (percentage points): recall bias@0−none {}, bias@50−none {}; CER bias@50−none {}, dis@50−none {} (over-biasing damage).\n",
        pct(&d["recall_bias0_minus_none"]), pct(&d["recall_bias50_minus_none"]), pct(&d["cer_bias50_minus_none"]), pct(&d["cer_dis50_minus_none"])).unwrap();
    if conds.values().any(|m| m.get("asr_stage").is_some()) {
        writeln!(
            md,
            "## Stage attribution (ASR transcript vs final output)\n"
        )
        .unwrap();
        writeln!(md, "| condition | ASR CER | final CER | ASR recall | final recall | ASR listed | final listed | ASR fire | final fire | entities kept/gained/lost/missed | listed gained/lost | fires added/removed | utts better/worse |").unwrap();
        writeln!(md, "|---|---|---|---|---|---|---|---|---|---|---|---|---|").unwrap();
        for (c, m) in conds {
            let a = &m["asr_stage"];
            let at = &m["cleanup_attribution"];
            let g = &at["gold_entities"];
            writeln!(md, "| {c} | {} | {} | {} | {} | {} | {} | {} | {} | {}/{}/{}/{} | {}/{} | {}/{} | {}/{} |", pct(&a["cer"]), pct(&m["cer"]),
                pct(&a["entity_recall"]), pct(&m["entity_recall"]), pct(&a["script_compliance"]), pct(&m["script_compliance"]),
                pct3(&a["distractor_fire_rate"]), pct3(&m["distractor_fire_rate"]), g["kept"], g["gained"], g["lost"], g["missed"],
                at["listed_form_gained"], at["listed_form_lost"], at["fires_introduced"], at["fires_removed"],
                at["utterances_cer_better"], at["utterances_cer_worse"]).unwrap();
        }
        writeln!(md, "\n## Pipeline activity and latency\n").unwrap();
        writeln!(md, "| condition | LLM ran | vocab fired (rows/total) | guardrail flags | errors | STT median/p95 s | cleanup median/p95 s | LLM median s |").unwrap();
        writeln!(md, "|---|---|---|---|---|---|---|---|").unwrap();
        for (c, m) in conds {
            let p = &m["pipeline"];
            let l = &m["latency_s"];
            let flags: Vec<String> = p["guardrail_flags"]
                .as_object()
                .map(|o| o.iter().map(|(k, v)| format!("{k} {v}")).collect())
                .unwrap_or_default();
            writeln!(
                md,
                "| {c} | {} | {}/{} | {} | {} | {}/{} | {}/{} | {} |",
                p["llm_ran"],
                p["vocab_fired_rows"],
                p["vocab_fired_total"],
                flags.join(", "),
                p["errors"],
                secs(&l["stt"]["median"]),
                secs(&l["stt"]["p95"]),
                secs(&l["cleanup"]["median"]),
                secs(&l["cleanup"]["p95"]),
                secs(&l["llm_when_run"]["median"])
            )
            .unwrap();
        }
    }
    writeln!(
        md,
        "\n## By id prefix (a = GigaSpeech2 real, b = TTS, c = Shunya real)\n"
    )
    .unwrap();
    writeln!(
        md,
        "| condition | prefix | n | CER | B-CER | recall | listed |"
    )
    .unwrap();
    writeln!(md, "|---|---|---|---|---|---|---|").unwrap();
    for (c, m) in conds {
        for (p, s) in m["by_id_prefix"].as_object().unwrap() {
            writeln!(
                md,
                "| {c} | {p} | {} | {} | {} | {} | {} |",
                s["n"],
                pct(&s["cer"]),
                pct(&s["b_cer"]),
                pct(&s["entity_recall"]),
                pct(&s["script_compliance"])
            )
            .unwrap();
        }
    }
    md
}

/// Paired utterance bootstrap of (candidate − baseline) for one statistic.
fn paired_ci(pairs: &[(&Value, &Value)], stat: impl Fn(&[&Value]) -> Option<f64>) -> Value {
    let mut rng = PyRandom::new(2026);
    let mut vals = Vec::new();
    for _ in 0..1000 {
        let idx: Vec<usize> = (0..pairs.len())
            .map(|_| rng.randrange(pairs.len()))
            .collect();
        let a: Vec<&Value> = idx.iter().map(|i| pairs[*i].0).collect();
        let b: Vec<&Value> = idx.iter().map(|i| pairs[*i].1).collect();
        if let (Some(x), Some(y)) = (stat(&b), stat(&a)) {
            vals.push(x - y);
        }
    }
    vals.sort_by(f64::total_cmp);
    if vals.is_empty() {
        return Value::Null;
    }
    let n = vals.len() as f64;
    json!([vals[(0.025 * n) as usize], vals[(0.975 * n) as usize]])
}

/// Ratio of summed per-pair counts: `key` is `[numerator, denominator]`, or a
/// scalar denominator `den` paired with `key[0]`.
fn sum_ratio(rows: &[&Value], key: &str, den: Option<&str>) -> Option<f64> {
    let (n, d) = rows.iter().fold((0u64, 0u64), |a, r| {
        let d = match den {
            Some(k) => r[k].as_u64().unwrap_or(0),
            None => r[key][1].as_u64().unwrap_or(0),
        };
        (a.0 + r[key][0].as_u64().unwrap_or(0), a.1 + d)
    });
    (d > 0).then(|| n as f64 / d as f64)
}

/// `K/N`: keep utterances whose sha256(seed:id) falls in shard K of N.
pub fn parse_shard(text: &str) -> Result<(u64, u64)> {
    let (k, n) = text.split_once('/').ok_or("Shard must look like 1/2")?;
    let (k, n): (u64, u64) = (k.parse()?, n.parse()?);
    if n == 0 || k >= n {
        return Err("Shard K/N needs 0 <= K < N".into());
    }
    Ok((k, n))
}
pub fn in_shard(id: &str, seed: &str, (k, n): (u64, u64)) -> bool {
    let h = sha256_hex(format!("{seed}:{id}").as_bytes());
    u64::from_str_radix(&h[..15], 16).unwrap() % n == k
}

const COMPARED: [(&str, &str, Option<&str>); 8] = [
    ("CER", "overall", None),
    ("WER", "words", None),
    ("B-CER", "biased", None),
    ("U-CER", "unbiased", None),
    ("Entity recall", "gold", None),
    (
        "Listed-form compliance (of recalled)",
        "listed",
        Some("expected"),
    ),
    ("Listed-form accuracy (of listed gold)", "listed", None),
    ("Distractor fire rate", "fired", None),
];

pub fn compare(
    baseline: &Path,
    candidate: &Path,
    out: &Path,
    shard: Option<(u64, u64)>,
    seed: &str,
) -> Result<()> {
    let load = |dir: &Path| -> Result<(Value, Vec<Value>)> {
        let rows = read_jsonl(&dir.join("scores.jsonl"))?
            .into_iter()
            .filter(|r| shard.is_none_or(|s| in_shard(r["utt_id"].as_str().unwrap_or(""), seed, s)))
            .collect();
        Ok((
            serde_json::from_slice(&std::fs::read(dir.join("metrics.json"))?)?,
            rows,
        ))
    };
    let (bm, bs) = load(baseline)?;
    let (cm, cs) = load(candidate)?;
    let key = |r: &Value| {
        (
            r["utt_id"].as_str().unwrap_or("").to_owned(),
            r["condition"].as_str().unwrap_or("").to_owned(),
        )
    };
    let cand: BTreeMap<_, &Value> = cs.iter().map(|r| (key(r), r)).collect();
    let base_keys: BTreeSet<_> = bs.iter().map(key).collect();
    if bs.is_empty() || base_keys.len() != bs.len() || base_keys != cand.keys().cloned().collect() {
        return Err(
            "Runs cover different (utterance, condition) pairs; compare identical samples only"
                .into(),
        );
    }
    let scope = shard.map_or("all pairs".into(), |(k, n)| {
        format!("shard {k}/{n} (seed {seed})")
    });
    let mut md = format!(
        "# ContextASR comparison\n\nBaseline: **{}**  \nCandidate: **{}**  \nIdentical pair set, {scope}: {} pairs. Deltas are candidate − baseline in percentage points (latency in seconds); 95% CIs are paired utterance bootstraps (1,000 draws, seed 2026).\n",
        bm["label"].as_str().unwrap_or(""),
        cm["label"].as_str().unwrap_or(""),
        bs.len()
    );
    let conditions: BTreeSet<&str> = bs.iter().filter_map(|r| r["condition"].as_str()).collect();
    let mut summary = serde_json::Map::new();
    for c in conditions {
        let pairs: Vec<(&Value, &Value)> = bs
            .iter()
            .filter(|r| r["condition"] == c)
            .map(|r| (r, cand[&key(r)]))
            .collect();
        writeln!(md, "\n## {c} (n = {})\n\n| metric | baseline | candidate | delta | delta 95% CI |\n|---|---|---|---|---|", pairs.len()).unwrap();
        let (b_rows, c_rows): (Vec<&Value>, Vec<&Value>) = pairs.iter().copied().unzip();
        let mut cond = serde_json::Map::new();
        for (name, k, den) in COMPARED {
            let (b, c2) = (sum_ratio(&b_rows, k, den), sum_ratio(&c_rows, k, den));
            if b.is_none() && c2.is_none() {
                continue;
            }
            let ci = paired_ci(&pairs, |rows| sum_ratio(rows, k, den));
            let delta = b.zip(c2).map(|(b, c2)| c2 - b);
            let places = if k == "fired" { 3 } else { 2 };
            let fmt_ci = |ci: &Value| match (ci[0].as_f64(), ci[1].as_f64()) {
                (Some(lo), Some(hi)) => {
                    format!("{:+.places$} … {:+.places$}", 100.0 * lo, 100.0 * hi)
                }
                _ => String::new(),
            };
            let rate = |v: Option<f64>| {
                if k == "fired" {
                    pct3(&json!(v))
                } else {
                    pct(&json!(v))
                }
            };
            writeln!(
                md,
                "| {name} | {} | {} | {} | {} |",
                rate(b),
                rate(c2),
                delta.map_or("—".into(), |d| format!("{:+.places$}", 100.0 * d)),
                fmt_ci(&ci)
            )
            .unwrap();
            if k == "fired" {
                let count = |rows: &[&Value]| -> (u64, usize) {
                    let n = rows
                        .iter()
                        .map(|r| r["fired"][0].as_u64().unwrap_or(0))
                        .sum();
                    (
                        n,
                        rows.iter()
                            .filter(|r| r["fired"][0].as_u64().unwrap_or(0) > 0)
                            .count(),
                    )
                };
                let (bn, cn) = (count(&b_rows), count(&c_rows));
                writeln!(
                    md,
                    "| Distractor fires (count / utterances) | {} / {} | {} / {} | {:+} | |",
                    bn.0,
                    bn.1,
                    cn.0,
                    cn.1,
                    cn.0 as i64 - bn.0 as i64
                )
                .unwrap();
                cond.insert("fires".into(), json!({"baseline": bn.0, "candidate": cn.0}));
            }
            cond.insert(
                name.into(),
                json!({"baseline": b, "candidate": c2, "delta": delta, "ci95": ci}),
            );
        }
        let latency = |rows: &[&Value]| {
            let mut v: Vec<f64> = rows.iter().filter_map(|r| r["t_e2e"].as_f64()).collect();
            v.sort_by(f64::total_cmp);
            (percentile(&v, 0.5), percentile(&v, 0.95))
        };
        let (bl, cl) = (latency(&b_rows), latency(&c_rows));
        for (name, b, c2) in [
            ("Median latency (s)", bl.0, cl.0),
            ("P95 latency (s)", bl.1, cl.1),
        ] {
            if let (Some(b), Some(c2)) = (b, c2) {
                writeln!(md, "| {name} | {b:.3} | {c2:.3} | {:+.3} | |", c2 - b).unwrap();
                cond.insert(
                    name.into(),
                    json!({"baseline": b, "candidate": c2, "delta": c2 - b}),
                );
            }
        }
        let llm = |rows: &[&Value]| rows.iter().filter(|r| r["llm_ran"] == true).count();
        if b_rows.iter().any(|r| r.get("llm_ran").is_some()) {
            let (b, c2) = (llm(&b_rows), llm(&c_rows));
            writeln!(
                md,
                "| LLM ran (pairs) | {b} | {c2} | {:+} | |",
                c2 as i64 - b as i64
            )
            .unwrap();
            cond.insert("llm_ran".into(), json!({"baseline": b, "candidate": c2}));
        }
        summary.insert(c.into(), Value::Object(cond));
    }
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(out, md)?;
    std::fs::write(
        out.with_extension("json"),
        serde_json::to_vec_pretty(&json!({"baseline": bm["label"], "candidate": cm["label"],
        "scope": scope, "n_pairs": bs.len(), "conditions": summary}))?,
    )?;
    println!("Wrote {}", out.display());
    Ok(())
}
