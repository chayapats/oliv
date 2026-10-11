//! Native developer benchmarks. Private transcripts go only to explicit files.
mod metrics;
mod worker;
use base64::Engine;
use clap::{Parser, Subcommand};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use worker::Worker;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Parser)]
#[command(about = "OLIV native evaluation and reports (no interpreter)")]
struct Cli {
    #[command(subcommand)]
    command: Task,
}
#[derive(Subcommand)]
enum Task {
    /// Evaluate the production Rust + MLX pipeline over a local manifest.
    Eval(Eval),
    /// Recompute Thai WER/CER and keyword recall for existing per-clip JSON.
    Score {
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// LaBSE cosine scores using cached native MLX weights and Rust WordPiece.
    Semantic {
        #[arg(long, default_value = "benchmark/eval_results")]
        results: PathBuf,
        #[arg(long)]
        model_dir: PathBuf,
        #[arg(long, default_value = "build/native-tools")]
        tools_dir: PathBuf,
    },
    /// Write a private HTML report; never exports recordings or publishes pages.
    Report {
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
}
#[derive(clap::Args)]
struct Eval {
    #[arg(long, default_value = "data/manifest_all.jsonl")]
    manifest: PathBuf,
    #[arg(long, default_value = "data")]
    audio_root: PathBuf,
    #[arg(long, default_value = "build/native-runtime")]
    runtime_dir: PathBuf,
    #[arg(long, default_value = "typhoon-turbo-mlx")]
    engine: String,
    #[arg(long)]
    no_cleanup: bool,
    #[arg(long)]
    no_vocab: bool,
    #[arg(long, default_value = "")]
    buckets: String,
    #[arg(long, default_value_t = 0)]
    limit: usize,
    #[arg(long, default_value = "")]
    label: String,
    #[arg(long, default_value = "benchmark/eval_results/native.json")]
    out: PathBuf,
}
fn read_json(path: &Path) -> Result<Value> {
    Ok(serde_json::from_slice(&std::fs::read(path)?)?)
}
fn write_json(path: &Path, value: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, serde_json::to_vec_pretty(value)?)?;
    Ok(())
}
fn benchmark_path(path: &Path) -> PathBuf {
    if path.is_absolute() || path.starts_with("benchmark") {
        path.into()
    } else {
        Path::new("benchmark").join(path)
    }
}
fn keywords(row: &Value) -> Vec<String> {
    row["keywords"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}
fn fields(row: &Value) -> Result<(&str, &str)> {
    Ok((
        row["reference"].as_str().ok_or("Missing reference")?,
        row["final"].as_str().ok_or("Missing final")?,
    ))
}
fn summarize(rows: &[Value]) -> Value {
    if rows.is_empty() {
        return Value::Null;
    }
    let n = rows.len() as f64;
    json!({"n":rows.len(),"exact_pct":100.0*rows.iter().filter(|c|c["exact"]==true).count() as f64/n,
        "mean_wer":rows.iter().map(|c|c["wer"].as_f64().unwrap_or(0.0)).sum::<f64>()/n,
        "mean_cer":rows.iter().map(|c|c["cer"].as_f64().unwrap_or(0.0)).sum::<f64>()/n,
        "mean_latency_s":rows.iter().map(|c|c["latency_s"].as_f64().unwrap_or(0.0)).sum::<f64>()/n})
}
fn aggregate(rows: &[Value]) -> Value {
    let buckets: BTreeSet<_> = rows.iter().filter_map(|c| c["bucket"].as_str()).collect();
    let map: serde_json::Map<_, _> = buckets
        .into_iter()
        .map(|bucket| {
            let selected: Vec<_> = rows
                .iter()
                .filter(|c| c["bucket"] == bucket)
                .cloned()
                .collect();
            (bucket.to_owned(), summarize(&selected))
        })
        .collect();
    Value::Object(map)
}
fn captured_pcm(path: &Path) -> Result<Vec<u8>> {
    let output = std::process::Command::new("ffmpeg")
        .args(["-v", "error", "-nostdin", "-i"])
        .arg(path)
        .args(["-ar", "16000", "-ac", "1", "-f", "f32le", "-t", "601", "-"])
        .output()?;
    if !output.status.success() {
        return Err("ffmpeg failed to convert audio".into());
    }
    if output.stdout.is_empty() || output.stdout.len() > 600 * 16000 * 4 {
        return Err("Audio is empty or exceeds 10 minutes".into());
    }
    Ok(output.stdout)
}
fn evaluate(args: Eval) -> Result<()> {
    let manifest = benchmark_path(&args.manifest);
    let audio_root = benchmark_path(&args.audio_root);
    let mut rows = Vec::new();
    let mut seen = BTreeMap::new();
    let mut ids = BTreeSet::new();
    let wanted: BTreeSet<_> = args.buckets.split(',').filter(|s| !s.is_empty()).collect();
    for line in std::fs::read_to_string(&manifest)?
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
    {
        let mut row: Value = serde_json::from_str(line)?;
        let id = row["id"].as_str().ok_or("Manifest row has no id")?;
        if !ids.insert(id.to_owned()) {
            return Err("Duplicate manifest id".into());
        }
        let bucket = metrics::bucket(id);
        if !wanted.is_empty() && !wanted.contains(bucket.as_str()) {
            continue;
        }
        let count = seen.entry(bucket.clone()).or_insert(0usize);
        if args.limit > 0 && *count >= args.limit {
            continue;
        }
        *count += 1;
        row["reference"]
            .as_str()
            .ok_or("Manifest row has no reference")?;
        let path = audio_root.join(
            row["path"]
                .as_str()
                .ok_or("Manifest row has no audio path")?,
        );
        if !path.is_file() {
            return Err(format!("Missing selected audio file: {}", path.display()).into());
        }
        row["bucket"] = bucket.into();
        row["_audio"] = path.to_string_lossy().as_ref().into();
        rows.push(row);
    }
    if rows.is_empty() {
        return Err("No selected manifest rows; evaluation stopped".into());
    }
    let mut runtime = Worker::new(&args.runtime_dir, "oliv-sidecar", &[])?;
    runtime.request(
        json!({"cmd":"warm","engine":args.engine,"cleanup":!args.no_cleanup}),
        Duration::from_secs(120),
    )?;
    let mut clips = Vec::new();
    for row in &rows {
        let start = Instant::now();
        let pcm = captured_pcm(Path::new(row["_audio"].as_str().unwrap()))?;
        let mut request = json!({"cmd":"dictate","engine":args.engine,"cleanup":!args.no_cleanup,
            "pcm_b64":base64::engine::general_purpose::STANDARD.encode(&pcm)});
        if !args.no_cleanup {
            match row["bucket"].as_str().unwrap() {
                "fl" => request["remove_fillers"] = true.into(),
                "fm" => request["format_commands"] = true.into(),
                "vb" if !args.no_vocab => {
                    if let Some(vocab) = row.get("vocab") {
                        request["vocabulary"] = vocab.clone();
                    }
                }
                _ => {}
            }
        }
        let reply = runtime.request(request, Duration::from_secs(65))?;
        let final_text = reply["final"]
            .as_str()
            .ok_or("Native reply has no final text")?;
        let reference = row["reference"].as_str().unwrap();
        let mut clip = metrics::score(reference, final_text, &keywords(row));
        for key in ["id", "bucket", "difficulty", "reference", "keywords"] {
            clip[key] = row[key].clone();
        }
        for key in [
            "raw",
            "final",
            "llm_ran",
            "guardrail_flag",
            "gate_reason",
            "fillers_removed",
            "format_commands_fired",
            "replacements_fired",
            "thai_format_fired",
            "t_stt",
            "t_cleanup",
            "cleanup_error",
        ] {
            clip[key] = reply[key].clone();
        }
        clip["guardrail"] = reply["guardrail_flag"].clone();
        clip["exact"] = (metrics::exact(reference) == metrics::exact(final_text)).into();
        clip["latency_s"] = start.elapsed().as_secs_f64().into();
        clips.push(clip);
        println!("Evaluated {}/{} clips", clips.len(), rows.len());
    }
    let label = if args.label.is_empty() {
        args.engine.clone()
    } else {
        args.label
    };
    let report = json!({"label":label,"runtime":"native","engine":args.engine,"cleanup_model":if args.no_cleanup {Value::Null}else{json!("mlx-community/gemma-4-e2b-it-4bit")},
        "manifest":manifest,"no_vocab":args.no_vocab,"metric_version":"newmm_nfc_v1","overall":summarize(&clips),"aggregate":aggregate(&clips),"clips":clips,"missing":[]});
    write_json(&args.out, &report)?;
    println!(
        "{} clips; WER {:.4}, CER {:.4}; wrote {}",
        rows.len(),
        report["overall"]["mean_wer"].as_f64().unwrap(),
        report["overall"]["mean_cer"].as_f64().unwrap(),
        args.out.display()
    );
    Ok(())
}
fn rescore(input: &Path, out: &Path) -> Result<()> {
    let mut report = read_json(input)?;
    let rows = report["clips"].as_array_mut().ok_or("Input has no clips")?;
    if rows.is_empty() {
        return Err("Input has no scored clips".into());
    }
    for row in &mut *rows {
        let (reference, hypothesis) = fields(row)?;
        let values = metrics::score(reference, hypothesis, &keywords(row));
        let exact = metrics::exact(reference) == metrics::exact(hypothesis);
        for (k, v) in values.as_object().unwrap() {
            row[k] = v.clone();
        }
        row["exact"] = exact.into();
        if row["bucket"].as_str().is_none() {
            row["bucket"] = metrics::bucket(row["id"].as_str().ok_or("Clip has no id")?).into();
        }
    }
    let overall = summarize(rows);
    let per_bucket = aggregate(rows);
    report["overall"] = overall;
    report["aggregate"] = per_bucket;
    report["metric_version"] = "newmm_nfc_v1".into();
    write_json(out, &report)?;
    println!("Wrote {}", out.display());
    Ok(())
}
fn semantic(results: &Path, model_dir: &Path, tools_dir: &Path) -> Result<()> {
    let mut files: Vec<_> = std::fs::read_dir(results)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.extension().is_some_and(|e| e == "json")
                && !p.file_name().unwrap().to_string_lossy().starts_with('_')
        })
        .collect();
    files.sort();
    let mut runtime = Worker::new(
        tools_dir,
        "oliv-semantic",
        &[model_dir.to_string_lossy().into_owned()],
    )?;
    let mut configs = serde_json::Map::new();
    for file in files {
        let report = read_json(&file)?;
        let Some(rows) = report["clips"].as_array() else {
            continue;
        };
        if rows.is_empty() {
            continue;
        }
        let mut clips = Vec::new();
        let mut by_bucket: BTreeMap<String, Vec<f64>> = BTreeMap::new();
        for row in rows {
            let (reference, hypothesis) = fields(row)?;
            let sim = if reference.trim().is_empty() || hypothesis.trim().is_empty() {
                0.0
            } else {
                runtime.request(json!({"cmd":"similarity","texts":[metrics::segment(reference),metrics::segment(hypothesis)]}),Duration::from_secs(120))?["similarity"].as_f64().ok_or("Missing similarity")?.clamp(0.0,1.0)
            };
            let id = row["id"].as_str().ok_or("Clip has no id")?;
            let bucket = metrics::bucket(id);
            by_bucket.entry(bucket.clone()).or_default().push(sim);
            clips.push(json!({"id":id,"bucket":bucket,"sim":sim}));
        }
        let all: Vec<_> = by_bucket.values().flatten().copied().collect();
        let summarize = |sims: &[f64]| json!({"sim":sims.iter().sum::<f64>()/sims.len() as f64,"match":100.0*sims.iter().filter(|s|**s>=0.8).count() as f64/sims.len() as f64,"n":sims.len()});
        let agg: serde_json::Map<_, _> = by_bucket
            .iter()
            .map(|(b, s)| (b.clone(), summarize(s)))
            .collect();
        let summary = summarize(&all);
        let key = file.file_stem().unwrap().to_string_lossy().into_owned();
        println!(
            "Semantic: {} clips, similarity {:.4}",
            clips.len(),
            summary["sim"].as_f64().unwrap()
        );
        configs.insert(key,json!({"overall_sim":summary["sim"],"match_rate":summary["match"],"aggregate":agg,"clips":clips}));
    }
    if configs.is_empty() {
        return Err("No per-clip evaluation files".into());
    }
    write_json(
        &results.join("_semantic.json"),
        &json!({"model":"sentence-transformers/LaBSE","threshold":0.8,"metric_version":"v2_newmm_seg_native_mlx","configs":configs}),
    )
}
fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
fn html_report(input: &Path, out: &Path) -> Result<()> {
    let report = read_json(input)?;
    let rows = report["clips"].as_array().ok_or("Input has no clips")?;
    if rows.is_empty() {
        return Err("Input has no scored clips".into());
    }
    let mut html = String::from(
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>OLIV evaluation</title><style>body{max-width:1100px;margin:3rem auto;padding:0 1rem;font:16px system-ui;background:#fbf8ed;color:#33321f}table{border-collapse:collapse;width:100%}th,td{padding:.7rem;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}td{white-space:pre-wrap}code{font:inherit}details{margin:1rem 0}pre{overflow:auto}th{position:sticky;top:0;background:#fbf8ed}</style>",
    );
    html.push_str(&format!("<h1>{}</h1><p>Local evaluation. WER/CER measure text differences; these are not semantic accuracy.</p><details><summary>Aggregate metrics</summary><pre>{}</pre></details><table><thead><tr><th>Clip</th><th>Reference</th><th>Output</th><th>WER</th><th>CER</th></tr></thead><tbody>",escape(report["label"].as_str().unwrap_or("OLIV")),escape(&serde_json::to_string_pretty(&summarize(rows))?)));
    for row in rows {
        let (reference, hypothesis) = fields(row)?;
        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
            escape(row["id"].as_str().unwrap_or("")),
            escape(reference),
            escape(hypothesis),
            escape(&row["wer"].to_string()),
            escape(&row["cer"].to_string())
        ));
    }
    html.push_str("</tbody></table></html>");
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(out, html)?;
    println!("Wrote {}", out.display());
    Ok(())
}
fn main() -> Result<()> {
    match Cli::parse().command {
        Task::Eval(args) => evaluate(args),
        Task::Score { input, out } => rescore(&input, &out),
        Task::Semantic {
            results,
            model_dir,
            tools_dir,
        } => semantic(&results, &model_dir, &tools_dir),
        Task::Report { input, out } => html_report(&input, &out),
    }
}
