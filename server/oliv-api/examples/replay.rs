//! Eval harness: replay STT text through the `/v1/clean` path without HTTP or auth.
//!   cargo run --release --example replay -- --prompt v5 --gemma http://127.0.0.1:18081 \
//!       [--prompts-dir DIR] [--options JSON] < in.jsonl > out.jsonl
//! Each input line needs `id` and `raw`; `vocab` (list) is sent as the vocabulary.
//! `--options` adds request-body fields (e.g. `{"asr_profile":"qwen3asr"}`) to every clip.
//! Output lines are the input plus the Outcome fields, `t_cleanup`, `prompt` and
//! `asr_profile`.
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use oliv_pipeline::dictate::{AsrProfile, Options, clean_text};
use oliv_pipeline::llm::{HttpLlm, Prompt, set_prompts_dir};
use serde_json::{Map, Value};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let arg = |k: &str| {
        args.iter()
            .position(|a| a == k)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    if let Some(d) = arg("--prompts-dir") {
        set_prompts_dir(PathBuf::from(d));
    }
    let prompt: Prompt = arg("--prompt")
        .unwrap_or_else(|| "v5".into())
        .parse()
        .expect("prompt");
    let gemma = arg("--gemma").unwrap_or_else(|| "http://127.0.0.1:18081".into());
    let extra: Map<String, Value> = arg("--options")
        .map(|s| serde_json::from_str(&s).expect("--options must be a JSON object"))
        .unwrap_or_default();
    let llm = HttpLlm::new(&gemma, Duration::from_secs(5));
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    for line in std::io::stdin().lock().lines() {
        let line = line.expect("stdin");
        if line.trim().is_empty() {
            continue;
        }
        let mut rec: Map<String, Value> = serde_json::from_str(&line).expect("jsonl");
        let mut body = extra.clone();
        body.insert(
            "vocabulary".into(),
            rec.get("vocab").cloned().unwrap_or(Value::Null),
        );
        let opts = Options::from_json(&body, prompt, AsrProfile::Turbo).expect("options");
        let raw = rec
            .get("raw")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let t0 = Instant::now();
        let o = clean_text(&raw, &opts, &llm);
        let t = t0.elapsed().as_secs_f64();
        if let Value::Object(m) = serde_json::to_value(&o).unwrap() {
            rec.extend(m);
        }
        rec.insert("t_cleanup".into(), t.into());
        rec.insert("prompt".into(), prompt.name().into());
        rec.insert("asr_profile".into(), opts.asr_profile.name().into());
        writeln!(out, "{}", Value::Object(rec)).unwrap();
        out.flush().unwrap();
    }
}
