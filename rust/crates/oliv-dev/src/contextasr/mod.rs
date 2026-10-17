//! Thai ContextASR Bench (wayu-ai/thai-contextasr-bench, CC-BY-NC-4.0 data) run
//! through the shipped sidecar. The dataset stays outside the checkout; outputs
//! quote its transcripts and are written only to the requested local directory.
mod mt;
mod report;
pub mod score;

use crate::Result;
use crate::worker::Worker;
use base64::Engine;
use clap::{Args, Subcommand};
use score::{BiasList, Utterance};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// sha256 of `data/bias_lists.jsonl.gz` at upstream revision 84e3099 (its LFS oid).
pub const PINNED_LISTS_SHA256: &str =
    "dad80ee6a82f32f97ffea3e230192fcda26baa61e22b4dd1e218be71a09edd42";
pub const UPSTREAM_REVISION: &str = "84e309935208cca72ce4a19b073dc450515febad";
pub const STANDARD_CONDITIONS: &str = "none,bias@0,bias@50,dis@50";
const CACHE_VERSION: &str = "oliv-contextasr-stt-v1";

#[derive(Subcommand)]
pub enum Task {
    /// Decode benchmark pairs through the production sidecar, then score them.
    Run(RunArgs),
    /// Score a run directory, or any upstream-format hyps.jsonl, natively.
    Score(ScoreArgs),
    /// Compare two scored runs over identical (utterance, condition) pairs.
    Compare(CompareArgs),
}

#[derive(Args)]
pub struct RunArgs {
    /// Dataset root (utterances, lists, audio). Default: $OLIV_CONTEXTASR_DIR or
    /// ~/.cache/oliv-bench/thai-contextasr-bench.
    #[arg(long)]
    pub data_dir: Option<PathBuf>,
    /// Comma-separated upstream conditions.
    #[arg(long, default_value = STANDARD_CONDITIONS)]
    pub conditions: String,
    /// asr = pure STT; vocab = cleanup without the LLM (dictionary + vocabulary);
    /// full = cleanup with the LLM; app = full plus the app's default filler
    /// removal and Thai formatting.
    #[arg(long, default_value = "full")]
    pub pipeline: String,
    #[arg(long, default_value = "typhoon-turbo-mlx")]
    pub engine: String,
    #[arg(long, default_value = "build/native-runtime")]
    pub runtime_dir: PathBuf,
    /// Deterministic subset size in utterances (0 = all 2,062).
    #[arg(long, default_value_t = 0)]
    pub limit: usize,
    /// Seed of the hash order that picks `--limit` utterances.
    #[arg(long, default_value = "2026")]
    pub seed: String,
    /// Reusable STT transcripts; prompted engines include vocabulary in the key.
    #[arg(long, default_value = "benchmark/eval_results/contextasr/stt_cache")]
    pub cache_dir: PathBuf,
    #[arg(long)]
    pub no_cache: bool,
    #[arg(long, default_value = "")]
    pub label: String,
    /// Run directory; an interrupted run with the same configuration resumes.
    #[arg(long)]
    pub out: PathBuf,
    /// Accept bias lists that differ from the pinned upstream file (fixtures only).
    #[arg(long)]
    pub allow_unpinned: bool,
}

#[derive(Args)]
pub struct ScoreArgs {
    #[arg(long)]
    pub data_dir: Option<PathBuf>,
    /// Run directory written by `run` (rescored in place).
    #[arg(long, conflicts_with = "hyps")]
    pub run: Option<PathBuf>,
    /// Upstream-format hyps.jsonl, e.g. a published baseline.
    #[arg(long, requires = "out")]
    pub hyps: Option<PathBuf>,
    /// Output directory for `--hyps`.
    #[arg(long)]
    pub out: Option<PathBuf>,
    #[arg(long)]
    pub allow_unpinned: bool,
}

#[derive(Args)]
pub struct CompareArgs {
    #[arg(long)]
    pub baseline: PathBuf,
    #[arg(long)]
    pub candidate: PathBuf,
    /// Markdown output; JSON is written next to it.
    #[arg(long)]
    pub out: PathBuf,
    /// Restrict to utterance shard K/N (e.g. a held-out half, 1/2).
    #[arg(long)]
    pub shard: Option<String>,
    #[arg(long, default_value = "2026")]
    pub seed: String,
}

pub fn main(task: Task) -> Result<()> {
    match task {
        Task::Run(args) => run(args),
        Task::Score(args) => {
            let data = Dataset::load(&data_dir(args.data_dir)?, !args.allow_unpinned)?;
            match (args.run, args.hyps) {
                (Some(dir), _) => report::score_run(&data, &dir),
                (None, Some(hyps)) => report::score_hyps(&data, &hyps, &args.out.unwrap()),
                _ => Err("Pass --run DIR or --hyps FILE --out DIR".into()),
            }
        }
        Task::Compare(args) => {
            let shard = args.shard.as_deref().map(report::parse_shard).transpose()?;
            report::compare(
                &args.baseline,
                &args.candidate,
                &args.out,
                shard,
                &args.seed,
            )
        }
    }
}

fn data_dir(arg: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(dir) = arg.or_else(|| std::env::var_os("OLIV_CONTEXTASR_DIR").map(PathBuf::from)) {
        return Ok(dir);
    }
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(Path::new(&home).join(".cache/oliv-bench/thai-contextasr-bench"))
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes)
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn file_sha256(path: &Path) -> Result<String> {
    Ok(sha256_hex(&std::fs::read(path)?))
}

pub struct Dataset {
    pub root: PathBuf,
    pub utterances: Vec<Utterance>,
    pub index: HashMap<String, usize>,
    pub lists: HashMap<(String, String), BiasList>,
    pub lists_sha256: String,
    pub utterances_sha256: String,
}
impl Dataset {
    pub fn load(root: &Path, require_pin: bool) -> Result<Self> {
        let ann_path = root.join("data/utterances.jsonl");
        let lists_path = root.join("data/bias_lists.jsonl.gz");
        if !ann_path.is_file() || !lists_path.is_file() {
            return Err(format!(
                "Thai ContextASR Bench not found under {}; see benchmark/contextasr.md",
                root.display()
            )
            .into());
        }
        let lists_sha256 = file_sha256(&lists_path)?;
        if require_pin && lists_sha256 != PINNED_LISTS_SHA256 {
            return Err("bias_lists.jsonl.gz does not match the pinned upstream sha256".into());
        }
        let ann = std::fs::read(&ann_path)?;
        let utterances_sha256 = sha256_hex(&ann);
        let mut utterances = Vec::new();
        let mut index = HashMap::new();
        for line in std::str::from_utf8(&ann)?
            .lines()
            .filter(|l| !l.trim().is_empty())
        {
            let u = Utterance::from_json(&serde_json::from_str(line)?)?;
            if index.insert(u.id.clone(), utterances.len()).is_some() {
                return Err(format!("Duplicate utterance {}", u.id).into());
            }
            utterances.push(u);
        }
        let mut text = String::new();
        std::io::Read::read_to_string(
            &mut flate2::read::GzDecoder::new(std::fs::File::open(&lists_path)?),
            &mut text,
        )?;
        let mut lists = HashMap::new();
        for line in text.lines().filter(|l| !l.trim().is_empty()) {
            let v: Value = serde_json::from_str(line)?;
            let key = (
                v["utt_id"]
                    .as_str()
                    .ok_or("list missing utt_id")?
                    .to_owned(),
                v["condition"]
                    .as_str()
                    .ok_or("list missing condition")?
                    .to_owned(),
            );
            let entries = v["entries"]
                .as_array()
                .ok_or("list missing entries")?
                .iter()
                .map(|e| e.as_str().map(str::to_owned).ok_or("non-string list entry"))
                .collect::<std::result::Result<_, _>>()?;
            let gold_listed = v["gold_listed"]
                .as_object()
                .map(|m| {
                    m.iter()
                        .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                        .collect()
                })
                .unwrap_or_default();
            lists.insert(
                key,
                BiasList {
                    entries,
                    gold_listed,
                },
            );
        }
        Ok(Self {
            root: root.into(),
            utterances,
            index,
            lists,
            lists_sha256,
            utterances_sha256,
        })
    }

    pub fn utterance(&self, id: &str) -> Option<&Utterance> {
        self.index.get(id).map(|i| &self.utterances[*i])
    }

    pub fn list(&self, id: &str, condition: &str) -> Option<&BiasList> {
        self.lists.get(&(id.to_owned(), condition.to_owned()))
    }

    /// Deterministic subset: the first `limit` utterances in sha256(seed:id)
    /// order, returned in file order. `limit` 0 selects everything.
    pub fn select(&self, limit: usize, seed: &str) -> Vec<&Utterance> {
        if limit == 0 || limit >= self.utterances.len() {
            return self.utterances.iter().collect();
        }
        let mut order: Vec<(String, usize)> = self
            .utterances
            .iter()
            .enumerate()
            .map(|(i, u)| (sha256_hex(format!("{seed}:{}", u.id).as_bytes()), i))
            .collect();
        order.sort();
        let mut chosen: Vec<usize> = order[..limit].iter().map(|(_, i)| *i).collect();
        chosen.sort_unstable();
        chosen.into_iter().map(|i| &self.utterances[i]).collect()
    }

    /// (utterance, condition) pairs; `none` always exists, other conditions only
    /// where upstream ships a frozen list (bias@0 has none for entity-free rows).
    pub fn pairs<'a>(
        &'a self,
        selected: &[&'a Utterance],
        conditions: &[String],
    ) -> Vec<(&'a Utterance, String)> {
        let mut pairs = Vec::new();
        for u in selected {
            for c in conditions {
                if c == "none" || self.list(&u.id, c).is_some() {
                    pairs.push((*u, c.clone()));
                }
            }
        }
        pairs
    }
}

pub fn parse_conditions(text: &str) -> Result<Vec<String>> {
    let conditions: Vec<String> = text
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    let known = |c: &str| {
        c == "none"
            || c.strip_prefix("bias@")
                .is_some_and(|n| ["0", "10", "50", "100", "250", "500"].contains(&n))
            || c.strip_prefix("dis@")
                .is_some_and(|n| ["50", "500"].contains(&n))
            || c == "flip@50"
    };
    if conditions.is_empty() || conditions.iter().any(|c| !known(c)) {
        return Err(format!("Unknown condition list {text:?}").into());
    }
    if conditions.iter().collect::<HashSet<_>>().len() != conditions.len() {
        return Err("Duplicate condition".into());
    }
    Ok(conditions)
}

/// Sidecar request fields for one pipeline configuration.
pub fn pipeline_fields(pipeline: &str) -> Result<Value> {
    Ok(match pipeline {
        "asr" => json!({"cleanup": false}),
        "vocab" => json!({"cleanup": true, "cleanup_llm": false}),
        "full" => json!({"cleanup": true}),
        "app" => json!({"cleanup": true, "remove_fillers": true, "thai_format": true}),
        _ => return Err(format!("Unknown pipeline {pipeline:?} (asr, vocab, full, app)").into()),
    })
}

fn pcm(path: &Path) -> Result<Vec<u8>> {
    let output = std::process::Command::new("ffmpeg")
        .args(["-v", "error", "-nostdin", "-i"])
        .arg(path)
        .args(["-ar", "16000", "-ac", "1", "-f", "f32le", "-t", "601", "-"])
        .output()?;
    if !output.status.success() || output.stdout.is_empty() {
        return Err(format!("ffmpeg could not convert {}", path.display()).into());
    }
    Ok(output.stdout)
}

fn command_line(program: &str, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new(program)
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// HF snapshot revision of a model in the app cache, when present.
fn model_revision(repo: &str) -> Option<String> {
    let hf_home = std::env::var_os("HF_HOME").map(PathBuf::from).or_else(|| {
        std::env::var_os("HOME")
            .map(|h| Path::new(&h).join("Library/Application Support/OLIV/models"))
    })?;
    let dir = hf_home
        .join("hub")
        .join(format!("models--{}", repo.replace('/', "--")));
    std::fs::read_to_string(dir.join("refs/main"))
        .ok()
        .map(|s| s.trim().to_owned())
}

pub fn engine_repo(engine: &str) -> &str {
    match engine {
        "typhoon-turbo-mlx" => "chayapats/typhoon-whisper-turbo-mlx",
        "pathumma-mlx" => "kinoppy555/Pathumma-whisper-th-large-v3-mlx",
        "mlx-large-v3" => "mlx-community/whisper-large-v3-mlx",
        other => other,
    }
}
pub const CLEANUP_REPO: &str = "mlx-community/gemma-4-e2b-it-4bit";

fn environment(args: &RunArgs) -> Result<Value> {
    let sidecar = args.runtime_dir.join("oliv-sidecar");
    let inference = args.runtime_dir.join("oliv-inference");
    let commit = command_line("git", &["rev-parse", "HEAD"]);
    let dirty = command_line("git", &["status", "--porcelain", "--untracked-files=no"])
        .map(|s| !s.is_empty());
    Ok(json!({
        "git_commit": commit, "git_dirty": dirty,
        "sidecar_sha256": file_sha256(&sidecar)?, "inference_sha256": file_sha256(&inference)?,
        "engine_repo": engine_repo(&args.engine), "engine_revision": model_revision(engine_repo(&args.engine)),
        "cleanup_repo": CLEANUP_REPO, "cleanup_revision": model_revision(CLEANUP_REPO),
        "cleanup_prompt": std::env::var("OLIV_CLEANUP_PROMPT").unwrap_or_else(|_| "v2".into()),
        "macos": command_line("sw_vers", &["-productVersion"]),
        "chip": command_line("sysctl", &["-n", "machdep.cpu.brand_string"]),
        "started_unix": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs(),
    }))
}

struct SttCache {
    path: PathBuf,
    entries: HashMap<String, Value>,
}
impl SttCache {
    fn open(dir: &Path, engine: &str) -> Result<Self> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join(format!("{engine}.jsonl"));
        let mut entries = HashMap::new();
        if path.is_file() {
            for line in std::fs::read_to_string(&path)?
                .lines()
                .filter(|l| !l.is_empty())
            {
                // A torn final line from an interrupted run is ignored.
                if let Ok(v) = serde_json::from_str::<Value>(line)
                    && let Some(key) = v["key"].as_str()
                {
                    entries.insert(key.to_owned(), v);
                }
            }
        }
        Ok(Self { path, entries })
    }
    fn insert(&mut self, key: String, value: Value) -> Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        let mut row = value.clone();
        row["key"] = key.clone().into();
        writeln!(file, "{}", serde_json::to_string(&row)?)?;
        self.entries.insert(key, value);
        Ok(())
    }
}

struct Runtime {
    worker: Worker,
    warm: Value,
}
fn start_runtime(args: &RunArgs, uses_llm: bool) -> Result<Runtime> {
    let mut worker = Worker::new(&args.runtime_dir, "oliv-sidecar", &[])?;
    let warm = worker.request(
        json!({"cmd":"warm","engine":args.engine,"cleanup":uses_llm}),
        Duration::from_secs(300),
    )?;
    Ok(Runtime { worker, warm })
}

fn append(file: &mut std::fs::File, value: &Value) -> Result<()> {
    writeln!(file, "{}", serde_json::to_string(value)?)?;
    Ok(file.flush()?)
}

pub fn read_jsonl(path: &Path) -> Result<Vec<Value>> {
    if !path.is_file() {
        return Ok(Vec::new());
    }
    std::fs::read_to_string(path)?
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| Ok(serde_json::from_str(l)?))
        .collect()
}

fn run(args: RunArgs) -> Result<()> {
    let data = Dataset::load(&data_dir(args.data_dir.clone())?, !args.allow_unpinned)?;
    let conditions = parse_conditions(&args.conditions)?;
    let fields = pipeline_fields(&args.pipeline)?;
    let uses_llm = args.pipeline == "full" || args.pipeline == "app";
    let selected = data.select(args.limit, &args.seed);
    let pairs = data.pairs(&selected, &conditions);
    let mut split_counts: BTreeMap<&str, usize> = BTreeMap::new();
    for u in &selected {
        *split_counts
            .entry(u.id.split('-').next().unwrap_or(""))
            .or_default() += 1;
    }
    let config = json!({
        "benchmark": "wayu-ai/thai-contextasr-bench", "upstream_revision": UPSTREAM_REVISION,
        "lists_sha256": data.lists_sha256, "utterances_sha256": data.utterances_sha256,
        "pipeline": args.pipeline, "engine": args.engine, "conditions": conditions,
        "limit": args.limit, "seed": args.seed, "request_fields": fields,
        "n_utterances": selected.len(), "n_pairs": pairs.len(), "id_prefix_counts": split_counts,
    });
    std::fs::create_dir_all(&args.out)?;
    let run_path = args.out.join("run.json");
    let label = if args.label.is_empty() {
        format!("{} / {}", args.engine, args.pipeline)
    } else {
        args.label.clone()
    };
    if run_path.is_file() {
        let previous: Value = serde_json::from_slice(&std::fs::read(&run_path)?)?;
        if previous["config"] != config {
            return Err("Run directory holds a different configuration; choose a new --out".into());
        }
    }
    let details_path = args.out.join("details.jsonl");
    let done: HashSet<(String, String)> = read_jsonl(&details_path)?
        .iter()
        .filter_map(|r| {
            Some((
                r["utt_id"].as_str()?.to_owned(),
                r["condition"].as_str()?.to_owned(),
            ))
        })
        .collect();
    let todo: Vec<_> = pairs
        .iter()
        .filter(|(u, c)| !done.contains(&(u.id.clone(), c.clone())))
        .collect();
    println!(
        "{label}: {} utterances, {} pairs, {} already done",
        selected.len(),
        pairs.len(),
        pairs.len() - todo.len()
    );
    let mut env = environment(&args)?;
    let mut details = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&details_path)?;
    let mut hyps = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(args.out.join("hyps.jsonl"))?;
    if !todo.is_empty() {
        let inference_sha = env["inference_sha256"].as_str().unwrap().to_owned();
        let engine_rev = env["engine_revision"].clone();
        let prompt_dependent = oliv_pipeline::stt::uses_initial_prompt(&args.engine);
        let mut cache = if args.no_cache {
            None
        } else {
            Some(SttCache::open(&args.cache_dir, &args.engine)?)
        };
        let started = Instant::now();
        let mut runtime = start_runtime(&args, uses_llm)?;
        env["warm"] = runtime.warm.clone();
        std::fs::write(
            &run_path,
            serde_json::to_vec_pretty(&json!({"label":label,"config":config,"environment":env}))?,
        )?;
        let mut current: Option<(String, String, String)> = None; // (id, pcm_b64, audio sha)
        let mut failures = 0;
        for (n, (u, condition)) in todo.iter().enumerate() {
            if current.as_ref().is_none_or(|c| c.0 != u.id) {
                let path = data.root.join("audio").join(format!("{}.wav", u.id));
                let audio_sha = file_sha256(&path)?;
                let encoded = base64::engine::general_purpose::STANDARD.encode(pcm(&path)?);
                current = Some((u.id.clone(), encoded, audio_sha));
            }
            let (_, encoded, audio_sha) = current.as_ref().unwrap();
            let list = data.list(&u.id, condition);
            let vocabulary: Vec<&String> =
                list.map(|l| l.entries.iter().collect()).unwrap_or_default();
            let mut request = fields.clone();
            request["cmd"] = "dictate".into();
            request["engine"] = args.engine.clone().into();
            request["pcm_b64"] = encoded.clone().into();
            if !vocabulary.is_empty() {
                request["vocabulary"] = json!(vocabulary);
            }
            let prompt_input = if prompt_dependent {
                json!(vocabulary)
            } else {
                Value::Null
            };
            let key = sha256_hex(
                serde_json::to_string(&json!([
                    CACHE_VERSION,
                    args.engine,
                    engine_rev,
                    inference_sha,
                    audio_sha,
                    prompt_input
                ]))?
                .as_bytes(),
            );
            let cached = cache.as_ref().and_then(|c| c.entries.get(&key)).cloned();
            if let Some(hit) = &cached {
                request["stt_text"] = hit["raw"].clone();
            }
            let wall = Instant::now();
            let reply = match runtime
                .worker
                .request(request.clone(), Duration::from_secs(120))
            {
                Ok(r) => Ok(r),
                Err(_) => {
                    // The sidecar or model helper may have died: restart once, retry once.
                    runtime = start_runtime(&args, uses_llm)?;
                    runtime.worker.request(request, Duration::from_secs(120))
                }
            };
            let t_wall = wall.elapsed().as_secs_f64();
            let mut row = json!({"utt_id":u.id,"condition":condition,"split":u.split,"n_entries":vocabulary.len(),"t_wall":t_wall});
            match reply {
                Ok(reply) => {
                    for k in [
                        "raw",
                        "final",
                        "no_speech",
                        "stt_redecoded",
                        "stt_replayed",
                        "t_stt",
                        "t_cleanup",
                        "t_llm",
                        "llm_ran",
                        "gate_reason",
                        "guardrail_flag",
                        "dict_hits",
                        "vocab_fired",
                        "fillers_removed",
                        "thai_format_fired",
                        "cleanup_error",
                    ] {
                        row[k] = reply.get(k).cloned().unwrap_or(Value::Null);
                    }
                    row["text"] = reply["final"].as_str().unwrap_or("").into();
                    if let Some(hit) = &cached {
                        // Replayed decodes report the original STT cost.
                        row["t_stt"] = hit["t_stt"].clone();
                        row["stt_redecoded"] = hit["redecoded"].clone();
                        row["stt_cached"] = true.into();
                    } else {
                        row["stt_cached"] = false.into();
                        if let Some(c) = cache.as_mut()
                            && reply["no_speech"] != true
                        {
                            c.insert(key, json!({"utt_id":u.id,"raw":reply["raw"],"redecoded":reply["stt_redecoded"],"t_stt":reply["t_stt"]}))?;
                        }
                    }
                }
                Err(e) => {
                    row["text"] = "".into();
                    row["error"] = e.into();
                }
            }
            append(&mut details, &row)?;
            failures = if row.get("error").is_some() {
                failures + 1
            } else {
                0
            };
            if failures >= 10 {
                return Err(format!(
                    "10 consecutive requests failed (last: {}); fix the runtime and rerun into a fresh --out",
                    row["error"]
                )
                .into());
            }
            append(
                &mut hyps,
                &json!({"utt_id":u.id,"condition":condition,"text":row["text"]}),
            )?;
            if (n + 1) % 50 == 0 || n + 1 == todo.len() {
                let rate = started.elapsed().as_secs_f64() / (n + 1) as f64;
                println!(
                    "{}/{} pairs ({:.2}s/pair, ~{:.0} min left)",
                    n + 1,
                    todo.len(),
                    rate,
                    rate * (todo.len() - n - 1) as f64 / 60.0
                );
            }
        }
    } else if !run_path.is_file() {
        std::fs::write(
            &run_path,
            serde_json::to_vec_pretty(&json!({"label":label,"config":config,"environment":env}))?,
        )?;
    }
    report::score_run(&data, &args.out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn conditions_and_pipelines_are_validated() {
        assert_eq!(parse_conditions(STANDARD_CONDITIONS).unwrap().len(), 4);
        assert!(parse_conditions("bias@7").is_err());
        assert!(parse_conditions("none,none").is_err());
        assert!(parse_conditions("").is_err());
        assert_eq!(pipeline_fields("vocab").unwrap()["cleanup_llm"], false);
        assert!(pipeline_fields("asr").unwrap().get("cleanup_llm").is_none());
        assert_eq!(pipeline_fields("app").unwrap()["thai_format"], true);
        assert!(pipeline_fields("llm").is_err());
    }
    #[test]
    fn sha256_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
