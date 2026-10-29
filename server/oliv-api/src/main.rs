//! `oliv-api`: the OLIV dictation/cleanup API server.
//!
//! Usage: `oliv-api [--root DIR]` (default: the parent of the binary's `bin/`).
//! Reads config + hashed per-device keys; started by the existing start.sh api.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use oliv_pipeline::admission::Admission;
use oliv_pipeline::api::{App, bind, serve_with_audit};
use oliv_pipeline::auth::Auth;
use oliv_pipeline::config;
use oliv_pipeline::dictate::AsrProfile;
use oliv_pipeline::dictionary_store::DictionaryStore;
use oliv_pipeline::llm::{HttpLlm, Llm, Prompt};
use oliv_pipeline::pipeline::clean_ex;
use oliv_pipeline::stage_gate::StageGate;
use oliv_pipeline::stt::HttpStt;

/// Oliv's `_PRIME_TEXT`: a dict-hit sentence, so the prime exercises the LLM path.
const PRIME_TEXT: &str = "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา";
const STT_TIMEOUT: Duration = Duration::from_secs(30);
/// Gemma's first request after boot takes about a minute.
const PRIME_TIMEOUT: Duration = Duration::from_secs(180);

fn root() -> Result<PathBuf, String> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [flag, dir] if flag == "--root" => Ok(PathBuf::from(dir)),
        [] => {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            exe.parent()
                .and_then(|bin| bin.parent())
                .map(PathBuf::from)
                .ok_or_else(|| "cannot find the root next to the binary".into())
        }
        _ => Err("usage: oliv-api [--root DIR]".into()),
    }
}

/// Warm Gemma once under the same inference lock. Public requests receive a
/// bounded busy response during cold start instead of competing for the GPU.
fn prime(gemma_url: String, prompt: Prompt, profile: AsrProfile, app: Arc<App>) {
    std::thread::spawn(move || {
        let llm = HttpLlm::new(&gemma_url, PRIME_TIMEOUT);
        let t0 = Instant::now();
        while !llm.healthy() {
            if t0.elapsed() > Duration::from_secs(600) {
                eprintln!("prime: gemma never became healthy, skipped");
                return;
            }
            std::thread::sleep(Duration::from_secs(2));
        }
        let Ok(_prime_guard) = app.busy.try_lock() else {
            return;
        };
        let t0 = Instant::now();
        let r = clean_ex(
            PRIME_TEXT,
            &[],
            &Default::default(),
            prompt,
            profile,
            None,
            &llm,
        );
        eprintln!(
            "prime: {:.1}s cleanup_failed={}",
            t0.elapsed().as_secs_f64(),
            r.llm_error.is_some()
        );
    });
}

fn run() -> Result<(), String> {
    let root = root()?;
    oliv_pipeline::llm::set_prompts_dir(root.join("prompts"));
    let cfg = config::load(&root.join("config.toml"))?;
    let auth = match cfg.auth_mode {
        config::AuthMode::Keys => Auth::key_file(root.join("api-keys.json"))?,
        config::AuthMode::Legacy => Auth::legacy(config::load_token(&root.join("api.token"))?),
    };
    // Build the word tables before the first request, not during it.
    let _ = oliv_pipeline::tokenize::word_tokenize("พร้อม", true);
    let app = Arc::new(App {
        auth,
        admission: Arc::new(Admission::default()),
        prompt: cfg.prompt,
        asr_profile: cfg.asr_profile,
        llm_timeout_s: cfg.llm_timeout.as_secs(),
        stt: Box::new(HttpStt::new(&cfg.whisper_url, STT_TIMEOUT)),
        llm: Box::new(HttpLlm::new(&cfg.gemma_url, cfg.llm_timeout)),
        dictionaries: DictionaryStore::open(&root)
            .map_err(|e| format!("dictionary store unavailable: {e}"))?,
        busy: Mutex::new(()),
        asr_gate: StageGate::new(cfg.asr_concurrency),
    });
    let server = bind(&cfg.listen)?;
    prime(
        cfg.gemma_url.clone(),
        cfg.prompt,
        cfg.asr_profile,
        Arc::clone(&app),
    );
    let audit = Arc::new(
        oliv_pipeline::audit::Audit::open(&root).map_err(|_| "usage audit store unavailable")?,
    );
    serve_with_audit(app, server, audit);
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("oliv-api: {e}");
        std::process::exit(1);
    }
}
