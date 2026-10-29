//! The `oliv-api` HTTP surface (see `docs/PUBLIC-API.md`):
//! public `GET /health`, scoped `GET /v1/status`, `POST /v1/dictate`,
//! `POST /v1/clean`, and the personal dictionary `GET/POST /v1/dictionary`
//! (see `docs/DICTIONARY.md`). Cleanup runs one at a time (Gemma runs
//! `-np 1`); `/health` and dictionary sync never wait behind it.

use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{Map, Value, json};

use crate::admission::{Admission, MAX_ADMITTED, Permit, Rejected};
use crate::auth::{Auth, AuthError};
use crate::dictate::{AsrProfile, Options, Outcome, clean_text};
use crate::dictionary_store::{DictionaryStore, parse_ops};
use crate::llm::{Llm, Prompt};
use crate::pyu::is_blank;
use crate::stage_gate::StageGate;
use crate::stt::{SEED_PROMPT, Stt, initial_prompt, transcribe_maybe_redecode};

/// 2 minutes of 16 kHz mono 16-bit WAV is ~3.8 MB, ~5.1 MB as base64.
pub const MAX_BODY: usize = 8 * 1024 * 1024;
/// 1000 dictionary operations with long Thai fields fit well inside this.
pub const MAX_DICTIONARY_BODY: usize = 512 * 1024;
pub const QUEUE_TIMEOUT: Duration = Duration::from_secs(20);

pub struct App {
    pub auth: Auth,
    pub admission: Arc<Admission>,
    pub prompt: Prompt,
    /// The STT model behind `stt`, unless a request says otherwise.
    pub asr_profile: AsrProfile,
    /// Reported only by the authenticated `/v1/status` route.
    pub llm_timeout_s: u64,
    pub stt: Box<dyn Stt + Send + Sync>,
    pub llm: Box<dyn Llm + Send + Sync>,
    /// Personal dictionaries per profile (applied to dictate/clean).
    pub dictionaries: DictionaryStore,
    pub asr_gate: StageGate,
    /// Serializes cleanup only; ASR releases its permit before entering this stage.
    pub busy: Mutex<()>,
}

/// An HTTP reply: status and JSON body.
pub type Reply = (u16, Value);

pub(crate) fn error(status: u16, msg: &str) -> Reply {
    let code = match status {
        400 => "invalid_request",
        401 => "unauthorized",
        403 => "forbidden",
        404 => "not_found",
        405 => "method_not_allowed",
        408 => "upload_timeout",
        413 => "payload_too_large",
        415 => "unsupported_media_type",
        429 => "rate_limited",
        502 => "inference_failed",
        503 => "unavailable",
        504 => "processing_timeout",
        _ => "internal_error",
    };
    (status, json!({"ok": false, "error": msg, "code": code}))
}

/// The routes behind authentication.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Route {
    Dictate,
    Clean,
    Status,
    Dictionary,
}

impl Route {
    pub(crate) fn of(path: &str) -> Option<Route> {
        match path {
            "/v1/dictate" => Some(Route::Dictate),
            "/v1/clean" => Some(Route::Clean),
            "/v1/status" => Some(Route::Status),
            "/v1/dictionary" => Some(Route::Dictionary),
            _ => None,
        }
    }

    /// The key scope required. A key that may dictate may manage the
    /// dictionary its dictation uses.
    fn scope(self) -> &'static str {
        match self {
            Route::Dictate | Route::Dictionary => "dictate",
            Route::Clean => "clean",
            Route::Status => "status",
        }
    }

    fn allows(self, method: &str) -> bool {
        match self {
            Route::Status => method == "GET",
            Route::Dictionary => matches!(method, "GET" | "POST"),
            Route::Dictate | Route::Clean => method == "POST",
        }
    }

    /// Largest accepted body; `GET` takes none.
    pub(crate) fn max_body(self, method: &str) -> usize {
        match (self, method) {
            (_, "GET") => 0,
            (Route::Dictionary, _) => MAX_DICTIONARY_BODY,
            _ => MAX_BODY,
        }
    }

    /// Dictionary sync is a cheap local read/write: it neither takes an
    /// inference slot nor counts against the key's request quota.
    fn admitted(self) -> bool {
        self != Route::Dictionary
    }
}

/// A request that passed the header checks. Holds its admission slot (if the
/// route takes one) until dropped.
pub(crate) struct Admitted {
    pub(crate) route: Route,
    pub(crate) key_id: String,
    _permit: Option<Permit>,
}

fn reply_body(
    raw: &str,
    redecoded: bool,
    out: &Outcome,
    t_stt: f64,
    t_cleanup: f64,
    dictionary_revision: Option<i64>,
) -> Reply {
    // Even worst-case JSON escaping stays below the desktop client's 1 MiB
    // response ceiling. User replacements can expand a small input substantially.
    if raw.len().saturating_add(out.final_text.len()) > 128 * 1024 {
        return error(
            502,
            "processed text exceeds response size limit; reduce replacements",
        );
    }
    (
        200,
        json!({
            "ok": true,
            "raw": raw,
            "stt_redecoded": redecoded,
            "final": out.final_text,
            "t_stt": t_stt,
            "t_cleanup": t_cleanup,
            "llm_ran": out.llm_ran,
            "gate_reason": out.gate_reason,
            "guardrail_flag": out.guardrail_flag,
            "dict_hits": out.dict_hits,
            "cleanup_error": out.cleanup_error.as_ref().map(|_| "cleanup unavailable; deterministic result returned"),
            "fillers_removed": out.fillers_removed,
            "replacements_fired": out.replacements_fired,
            "thai_format_fired": out.thai_format_fired,
            "vocab_fired": out.vocab_fired,
            "no_speech": out.no_speech,
            "dictionary_revision": dictionary_revision,
        }),
    )
}

impl App {
    /// Header-only checks, including admission. Must run before reading a body.
    pub(crate) fn preflight(
        &self,
        method: &str,
        path: &str,
        auth: Option<&str>,
    ) -> Result<Admitted, Reply> {
        self.preflight_observed(method, path, auth, &mut None, &mut false)
    }

    pub(crate) fn preflight_observed(
        &self,
        method: &str,
        path: &str,
        auth: Option<&str>,
        key_id: &mut Option<String>,
        charged: &mut bool,
    ) -> Result<Admitted, Reply> {
        let route = Route::of(path).ok_or_else(|| error(404, "not found"))?;
        if !route.allows(method) {
            return Err(error(405, "method not allowed"));
        }
        let user = self
            .auth
            .authenticate_observed(auth, route.scope(), key_id)
            .map_err(|e| match e {
                AuthError::Unauthorized => error(401, "invalid, expired or revoked API key"),
                AuthError::Forbidden => error(403, "API key does not allow this operation"),
                AuthError::Unavailable => error(503, "authentication store unavailable"),
            })?;
        *key_id = Some(user.id.clone());
        if !route.admitted() {
            return Ok(Admitted {
                route,
                key_id: user.id,
                _permit: None,
            });
        }
        let (result, counted) = self.admission.reserve_observed(&user);
        *charged = counted;
        let permit = result.map_err(|e| match e {
            Rejected::Rate => error(429, "API key request quota exceeded"),
            Rejected::Active => error(429, "this API key already has a request in progress"),
            Rejected::Full => error(503, "server is busy; retry later"),
        })?;
        Ok(Admitted {
            route,
            key_id: user.id,
            _permit: Some(permit),
        })
    }

    fn inference_lock(&self) -> Result<MutexGuard<'_, ()>, Reply> {
        let start = Instant::now();
        loop {
            match self.busy.try_lock() {
                Ok(g) => return Ok(g),
                Err(TryLockError::Poisoned(_)) => {
                    return Err(error(503, "inference worker unavailable"));
                }
                Err(TryLockError::WouldBlock) => {}
            }
            if start.elapsed() >= QUEUE_TIMEOUT {
                return Err(error(503, "inference queue wait exceeded"));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Route one request. `auth` is the `Authorization` header, if any.
    pub fn handle(&self, method: &str, path: &str, auth: Option<&str>, body: &[u8]) -> Reply {
        if path.contains('?') {
            return error(400, "query parameters are not supported");
        }
        match (method, path) {
            ("GET", "/health") => return (200, json!({"ok": true})),
            (_, "/health") => return error(405, "method not allowed"),
            _ => {}
        }
        let admitted = match self.preflight(method, path, auth) {
            Ok(a) => a,
            Err(reply) => return reply,
        };
        self.handle_admitted(method, body, admitted)
    }

    pub(crate) fn handle_admitted(&self, method: &str, body: &[u8], admitted: Admitted) -> Reply {
        if body.len() > admitted.route.max_body(method) {
            return error(413, "body too large");
        }
        match admitted.route {
            Route::Status => return self.health(),
            Route::Dictionary => return self.dictionary(method, body, &admitted.key_id),
            Route::Dictate | Route::Clean => {}
        }
        if body.is_empty() {
            return error(400, "body must be a JSON object");
        }
        let req: Map<String, Value> = match serde_json::from_slice(body) {
            Ok(Value::Object(m)) => m,
            _ => return error(400, "body must be a JSON object"),
        };
        if let Err(msg) = validate_options(&req) {
            return error(400, msg);
        }
        let mut opts = match Options::from_json(&req, self.prompt, self.asr_profile) {
            Ok(o) => o,
            Err(_) => return error(400, "invalid request options"),
        };
        // Personalization must never cost the user their dictation: if the
        // store is unavailable, transcribe without it (revision = null).
        let revision = match self.dictionaries.compiled(&admitted.key_id) {
            Ok((dictionary, revision)) => {
                opts.dictionary = dictionary;
                Some(revision)
            }
            Err(e) => {
                eprintln!("dictionary store unavailable, continuing without: {e}");
                None
            }
        };
        if admitted.route == Route::Clean {
            let Some(text) = req.get("text").and_then(Value::as_str) else {
                return error(400, "text must be a string");
            };
            if text.len() > 8192 {
                return error(400, "text must be at most 8192 UTF-8 bytes");
            }
            let _busy = match self.inference_lock() {
                Ok(g) => g,
                Err(r) => return r,
            };
            let t0 = Instant::now();
            let out = clean_text(text, &opts, self.llm.as_ref());
            return reply_body(text, false, &out, 0.0, t0.elapsed().as_secs_f64(), revision);
        }
        let wav = match req.get("wav_b64").and_then(Value::as_str) {
            Some(b) => match base64::engine::general_purpose::STANDARD.decode(b) {
                Ok(w) if !w.is_empty() => w,
                _ => return error(400, "wav_b64 must be non-empty base64"),
            },
            None => return error(400, "wav_b64 must be a string"),
        };
        if let Err(msg) = crate::audio::validate(&wav) {
            return error(400, msg);
        }
        self.dictate(&wav, &opts, revision)
    }

    /// `GET` returns the caller's dictionary; `POST {"ops": [...]}` applies
    /// changes and returns it (plus any operations it could not apply).
    fn dictionary(&self, method: &str, body: &[u8], key_id: &str) -> Reply {
        let result = if method == "GET" {
            self.dictionaries.snapshot(key_id).map(|s| (s, Vec::new()))
        } else {
            let ops = match serde_json::from_slice(body) {
                Ok(Value::Object(m)) => match parse_ops(&m) {
                    Ok(ops) => ops,
                    Err(msg) => return error(400, &msg),
                },
                _ => return error(400, "body must be a JSON object"),
            };
            self.dictionaries.apply(key_id, &ops)
        };
        match result {
            Ok((snapshot, rejected)) => (
                200,
                json!({
                    "ok": true,
                    "revision": snapshot.revision,
                    "max_entries": crate::dictionary_store::MAX_ENTRIES,
                    "entries": snapshot.entries,
                    "rejected": rejected,
                }),
            ),
            Err(e) => {
                eprintln!("dictionary store error: {e}");
                error(503, "dictionary store unavailable")
            }
        }
    }

    fn dictate(&self, wav: &[u8], opts: &Options, dictionary_revision: Option<i64>) -> Reply {
        let asr_permit = match self.asr_gate.acquire(QUEUE_TIMEOUT) {
            Ok(permit) => permit,
            Err(message) => return error(503, message),
        };
        let t0 = Instant::now();
        let decoded = match opts.asr_profile {
            AsrProfile::Turbo | AsrProfile::TyphoonCtx => {
                let prompt = SEED_PROMPT
                    .then(|| initial_prompt(&opts.effective_vocabulary()))
                    .flatten();
                transcribe_maybe_redecode(self.stt.as_ref(), wav, prompt.as_deref())
            }
            // One auto decode with the vocabulary as context. Forced Thai and the
            // forced-English re-decode were measurably worse on the eval.
            AsrProfile::Qwen3Asr => {
                let prompt = initial_prompt(&opts.effective_vocabulary());
                self.stt
                    .transcribe(wav, prompt.as_deref(), None)
                    .map(|t| (t.text, false))
            }
        };
        let (raw, redecoded) = match decoded {
            Ok(r) => r,
            // The client keeps the WAV for a manual `oliv retry`.
            Err(_) => return error(502, "speech recognition failed; retry later"),
        };
        let t_stt = t0.elapsed().as_secs_f64();
        drop(asr_permit);
        let _cleanup = match self.inference_lock() {
            Ok(permit) => permit,
            Err(reply) => return reply,
        };
        let t0 = Instant::now();
        // Whisper's VAD can leave nothing at all; that is no speech too.
        let out = if is_blank(&raw) {
            Outcome {
                no_speech: true,
                gate_reason: "no_speech".into(),
                ..Default::default()
            }
        } else {
            clean_text(&raw, opts, self.llm.as_ref())
        };
        reply_body(
            &raw,
            redecoded,
            &out,
            t_stt,
            t0.elapsed().as_secs_f64(),
            dictionary_revision,
        )
    }

    fn health(&self) -> Reply {
        (
            200,
            json!({
                "ok": true,
                "whisper": self.stt.healthy(),
                "gemma": self.llm.healthy(),
                "version": env!("CARGO_PKG_VERSION"),
                "prompt": self.prompt.name(),
                "asr_profile": self.asr_profile.name(),
                "llm_timeout": self.llm_timeout_s,
                "asr_concurrency": self.asr_gate.capacity(),
                "max_admitted_requests": MAX_ADMITTED,
                "queue_timeout_s": QUEUE_TIMEOUT.as_secs(),
                "max_requests_per_key": 1,
            }),
        )
    }
}

// Transport is separate from the unchanged text pipeline.
pub use crate::transport::{bind, serve, serve_with_audit};

fn validate_options(req: &Map<String, Value>) -> Result<(), &'static str> {
    if let Some(Value::Array(words)) = req.get("vocabulary")
        && (words.len() > 128
            || words
                .iter()
                .any(|v| v.as_str().is_some_and(|s| s.len() > 256)))
    {
        return Err("vocabulary allows at most 128 entries of 256 UTF-8 bytes");
    }
    if let Some(Value::Object(items)) = req.get("replacements")
        && (items.len() > 128
            || items.iter().any(|(k, v)| {
                k.is_empty() || k.len() > 256 || v.as_str().is_some_and(|s| s.len() > 256)
            }))
    {
        return Err(
            "replacements allows at most 128 nonempty keys and values up to 256 UTF-8 bytes",
        );
    }
    Ok(())
}
