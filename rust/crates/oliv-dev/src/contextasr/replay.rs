//! In-process replay for `run --stt-replay … --llm-cache FILE`: the sidecar's
//! `dictate` text path (silence gate, request options, `local::clean`) over
//! replayed transcripts, with cleanup-model replies cached by prompt. Gemma
//! decodes greedily, so one prompt has one reply; conditions that leave the
//! text unchanged reuse it instead of holding the shared GPU again. A reply
//! is reused only for the same model revision and inference helper (both are
//! in the key). The cache quotes transcripts: keep it under the ignored
//! `benchmark/eval_results/`.
use crate::Result;
use crate::worker::Worker;
use oliv_pipeline::{
    audio,
    dictate::Options,
    llm::{Llm, LlmError, Prompt, Request},
    local,
};
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// What produces a cleanup reply: the model snapshot the helper loads and
/// the helper binary (generation settings live in it). Part of every cache
/// key, so a reply from another model or helper is never reused.
#[derive(Clone, Debug, PartialEq)]
pub struct LlmIdentity {
    pub model_repo: String,
    /// The snapshot revision (`refs/main`); None when it can't be found, and
    /// then the cache is not used at all.
    pub model_revision: Option<String>,
    pub helper_sha256: String,
}
impl LlmIdentity {
    const KEY_VERSION: &str = "oliv-contextasr-llm-v2";
    fn key(&self, content: &str) -> Option<String> {
        let revision = self.model_revision.as_ref()?;
        let fields = json!([
            Self::KEY_VERSION,
            self.model_repo,
            revision,
            self.helper_sha256,
            content
        ]);
        Some(super::sha256_hex(fields.to_string().as_bytes()))
    }
}

/// Cleanup-model replies by sha256 of (model, helper, prompt), appended as JSONL.
pub struct LlmCache {
    path: PathBuf,
    entries: HashMap<String, String>,
}
impl LlmCache {
    pub fn open(path: &Path) -> Result<Self> {
        let mut entries = HashMap::new();
        for row in super::read_jsonl(path)? {
            if let (Some(k), Some(g)) = (row["key"].as_str(), row["generation"].as_str()) {
                entries.insert(k.to_owned(), g.to_owned());
            }
        }
        Ok(Self {
            path: path.into(),
            entries,
        })
    }
    fn insert(&mut self, key: String, generation: &str) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        writeln!(file, "{}", json!({"key": key, "generation": generation}))?;
        self.entries.insert(key, generation.to_owned());
        Ok(())
    }
}

/// The cleanup model behind the cache; the helper starts on the first miss.
pub struct CachedLlm {
    runtime_dir: PathBuf,
    identity: LlmIdentity,
    worker: RefCell<Option<Worker>>,
    cache: RefCell<LlmCache>,
    pub hits: Cell<usize>,
    pub misses: Cell<usize>,
    seconds: Cell<f64>,
}
impl CachedLlm {
    pub fn new(runtime_dir: &Path, cache: LlmCache, identity: LlmIdentity) -> Self {
        Self {
            runtime_dir: runtime_dir.into(),
            identity,
            worker: RefCell::new(None),
            cache: RefCell::new(cache),
            hits: Cell::new(0),
            misses: Cell::new(0),
            seconds: Cell::new(0.0),
        }
    }
}
impl Llm for CachedLlm {
    fn generate(&self, req: &Request) -> std::result::Result<String, LlmError> {
        let content = req.content();
        let key = self.identity.key(&content).ok_or_else(|| {
            LlmError(format!(
                "Unknown {} revision: cached cleanup replies can't be tied to a model",
                self.identity.model_repo
            ))
        })?;
        if let Some(g) = self.cache.borrow().entries.get(&key) {
            self.hits.set(self.hits.get() + 1);
            return Ok(g.clone());
        }
        self.misses.set(self.misses.get() + 1);
        let start = Instant::now();
        let mut worker = self.worker.borrow_mut();
        if worker.is_none() {
            *worker = Some(
                Worker::new(&self.runtime_dir, "oliv-inference", &[])
                    .map_err(|e| LlmError(e.to_string()))?,
            );
        }
        // As the sidecar's ModelLlm: one request, 20 s.
        let reply = worker
            .as_mut()
            .unwrap()
            .request(
                json!({"cmd":"generate","content":content}),
                Duration::from_secs(20),
            )
            .map_err(|e| {
                *worker = None;
                LlmError(e)
            })?;
        self.seconds
            .set(self.seconds.get() + start.elapsed().as_secs_f64());
        let generation = reply["generation"]
            .as_str()
            .ok_or_else(|| LlmError("Invalid generation reply".into()))?
            .to_owned();
        self.cache
            .borrow_mut()
            .insert(key, &generation)
            .map_err(|e| LlmError(e.to_string()))?;
        Ok(generation)
    }
}

/// As the sidecar's `cleanup_llm: false`: the deterministic result.
struct DisabledLlm;
impl Llm for DisabledLlm {
    fn generate(&self, _: &Request) -> std::result::Result<String, LlmError> {
        Err(LlmError("Cleanup model disabled by request".into()))
    }
}

/// The sidecar's `local_options`: request fields over its defaults.
fn options(request: &Value) -> std::result::Result<Options, String> {
    let mut body = request.as_object().ok_or("invalidOptions")?.clone();
    for (key, default) in [
        ("cleanup", true),
        ("remove_fillers", false),
        ("thai_format", false),
    ] {
        body.entry(key).or_insert(json!(default));
    }
    let prompt = std::env::var("OLIV_CLEANUP_PROMPT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(Prompt::V2);
    Options::from_json(&body, prompt)
}

/// The sidecar's `dictate` reply for a replayed transcript (`stt_text`).
pub fn dictate(request: &Value, pcm: &[u8], llm: &CachedLlm) -> std::result::Result<Value, String> {
    let samples: Vec<f32> = pcm
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| f32::from_le_bytes(*b))
        .collect();
    let no_speech = |reason: &str| json!({"ok":true,"raw":"","final":"","no_speech":true,"t_stt":0,"t_cleanup":0,"gate_reason":reason});
    if audio::is_silent(&samples) {
        return Ok(no_speech("silent"));
    }
    let raw = request["stt_text"].as_str().unwrap_or("");
    let opts = options(request)?;
    let cleanup: &dyn Llm = if request["cleanup_llm"] == false {
        &DisabledLlm
    } else {
        llm
    };
    let before = llm.seconds.get();
    let start = Instant::now();
    let out = local::clean(
        raw,
        Some(samples.len() as f64 / 16000.0),
        &opts,
        request["format_commands"] == true,
        cleanup,
    );
    if out.outcome.no_speech {
        return Ok(no_speech(&out.outcome.gate_reason));
    }
    let mut reply = serde_json::to_value(out).map_err(|_| "invalidReply")?;
    reply["ok"] = json!(true);
    reply["raw"] = json!(raw);
    reply["stt_redecoded"] = json!(false);
    reply["stt_replayed"] = json!(true);
    reply["t_cleanup"] = json!(start.elapsed().as_secs_f64());
    reply["t_llm"] = json!(llm.seconds.get() - before);
    Ok(reply)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(revision: Option<&str>, helper: &str) -> LlmIdentity {
        LlmIdentity {
            model_repo: "mlx-community/gemma-4-e2b-it-4bit".into(),
            model_revision: revision.map(str::to_owned),
            helper_sha256: helper.into(),
        }
    }

    #[test]
    fn a_reply_cached_for_another_model_or_helper_is_not_reused() {
        let dir = std::env::temp_dir().join(format!("oliv-dev-llm-cache-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("llm.jsonl");
        let _ = std::fs::remove_file(&path);
        let request = Request {
            prompt: Prompt::V2,
            text: "เรียกแกร็บไปสยาม",
            hints: &[],
        };
        let cached = identity(Some("rev-a"), "helper-a");
        LlmCache::open(&path)
            .unwrap()
            .insert(cached.key(&request.content()).unwrap(), "cached reply")
            .unwrap();
        // `dir` holds no inference helper: a miss fails to start it.
        let llm = |identity| CachedLlm::new(&dir, LlmCache::open(&path).unwrap(), identity);

        let same = llm(cached.clone());
        assert_eq!(same.generate(&request).unwrap(), "cached reply");
        assert_eq!((same.hits.get(), same.misses.get()), (1, 0));

        for other in [
            identity(Some("rev-b"), "helper-a"),
            identity(Some("rev-a"), "helper-b"),
        ] {
            let changed = llm(other);
            assert!(changed.generate(&request).is_err(), "not the cached reply");
            assert_eq!((changed.hits.get(), changed.misses.get()), (0, 1));
        }

        let unknown = llm(identity(None, "helper-a"));
        assert!(unknown.generate(&request).is_err());
        assert_eq!((unknown.hits.get(), unknown.misses.get()), (0, 0));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
