mod inference;
use base64::Engine;
use inference::Inference;
use oliv_pipeline::{
    audio, commands,
    dictate::Options,
    hallucination,
    llm::{Llm, LlmError, Prompt, Request},
    local,
    stt::{Stt, Transcript},
    transform,
};
use serde_json::{Value, json};
use std::cell::Cell;
use std::io::{self, BufRead, Read, Write};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

const MAX_REQUEST: u64 = 56 * 1024 * 1024;
const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

fn emit(value: &Value) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

fn pcm(request: &Value, limit: usize) -> Result<Option<Vec<f32>>, String> {
    if let Some(encoded) = request.get("pcm_b64") {
        let encoded = encoded.as_str().ok_or("invalidAudio")?;
        if encoded.len() > (limit * 4).div_ceil(3) * 4 {
            return Err("audioTooLong".into());
        }
        let bytes = B64.decode(encoded).map_err(|_| "invalidAudio")?;
        if bytes.len() % 4 != 0 {
            return Err("invalidAudio".into());
        }
        let samples: Vec<f32> = bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| f32::from_le_bytes(*b))
            .collect();
        if samples.len() > limit {
            return Err("audioTooLong".into());
        }
        return Ok(Some(samples));
    }
    if request["wav_path"].is_string() {
        return Ok(None);
    }
    Err("invalidAudio".into())
}

struct ModelLlm<'a> {
    inference: &'a Inference,
    id: &'a Value,
    seconds: Cell<f64>,
}
impl Llm for ModelLlm<'_> {
    fn generate(&self, req: &Request) -> Result<String, LlmError> {
        let start = Instant::now();
        let reply = self.inference.request(
            json!({"cmd":"generate","content":req.content()}),
            Duration::from_secs(20),
            self.id,
        );
        self.seconds
            .set(self.seconds.get() + start.elapsed().as_secs_f64());
        reply
            .map_err(LlmError)?
            .get("generation")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| LlmError("Invalid generation reply".into()))
    }
}
impl transform::Generate for ModelLlm<'_> {
    fn generate(&self, content: &str, max_tokens: u32) -> Result<transform::Generation, LlmError> {
        let start = Instant::now();
        let reply = self.inference.request(
            json!({"cmd":"generate","content":content,"max_tokens":max_tokens}),
            TRANSFORM_TIMEOUT,
            self.id,
        );
        self.seconds
            .set(self.seconds.get() + start.elapsed().as_secs_f64());
        transform_generation(&reply.map_err(LlmError)?)
    }
}
/// The native runtime's `generate` reply. Only `stop_reason: "stop"` (the
/// model ended its answer) is a finished answer: `"length"` hit `max_tokens`,
/// and a missing or other reason can't vouch for the end either.
fn transform_generation(reply: &Value) -> Result<transform::Generation, LlmError> {
    let text = reply
        .get("generation")
        .and_then(Value::as_str)
        .ok_or_else(|| LlmError("Invalid generation reply".into()))?;
    Ok(transform::Generation {
        text: text.to_string(),
        finished: reply["stop_reason"] == "stop",
    })
}
/// A transform may generate up to `transform::MAX_GENERATION_TOKENS`, and the
/// first one may also load the cleanup model (not pre-warmed with the OLIV
/// API engine).
const TRANSFORM_TIMEOUT: Duration = Duration::from_secs(120);

/// Evaluation only: `OLIV_TRANSFORM_PROMPT_DIR/<mode>.txt` replaces the
/// shipped prompt, so `oliv-dev voice-edit` can compare prompts unbuilt.
fn transform_template(mode: transform::Mode) -> Option<String> {
    let dir = std::env::var_os("OLIV_TRANSFORM_PROMPT_DIR")?;
    let name = match mode {
        transform::Mode::Command => "command.txt",
        transform::Mode::Translate => "translate.txt",
    };
    let text = std::fs::read_to_string(std::path::Path::new(&dir).join(name)).ok()?;
    Some(text.trim_end_matches('\n').to_string())
}

/// `{"cmd":"transform","mode","instruction","text"}`: Command mode or
/// translation on the cleanup model. Always ok:true when the request is well
/// formed; `applied:false` keeps the caller's text.
fn transform_reply(request: &Value, model: &dyn transform::Generate) -> Result<Value, String> {
    let start = Instant::now();
    let mode: transform::Mode = request["mode"]
        .as_str()
        .ok_or("invalidMode")?
        .parse()
        .map_err(|_| "invalidMode")?;
    let template = transform_template(mode);
    let req = transform::Request {
        mode,
        instruction: request["instruction"].as_str().unwrap_or(""),
        text: request["text"].as_str().ok_or("invalidText")?,
        template: template.as_deref(),
    };
    let out = transform::transform(&req, model);
    let mut reply = serde_json::to_value(&out).map_err(|_| "invalidReply")?;
    if request["include_raw"] != true {
        reply.as_object_mut().map(|o| o.remove("raw"));
    }
    reply["ok"] = json!(true);
    reply["t_total"] = json!(start.elapsed().as_secs_f64());
    Ok(reply)
}

struct ModelStt<'a> {
    inference: &'a Inference,
    request: &'a Value,
    engine: &'a str,
}
impl Stt for ModelStt<'_> {
    fn transcribe(
        &self,
        _wav: &[u8],
        initial_prompt: Option<&str>,
        language: Option<&str>,
    ) -> Result<Transcript, String> {
        if self.engine == "groq-large-v3" {
            let samples =
                pcm(self.request, audio::MAX_SAMPLES)?.ok_or("Groq requires captured PCM audio")?;
            return Ok(Transcript {
                text: oliv_transport::groq::transcribe(&samples, language, initial_prompt)?,
                avg_logprob: None,
            });
        }
        let mut body = json!({"cmd":"stt","engine":self.engine,"initial_prompt":initial_prompt,"language":language});
        for field in ["pcm_b64", "wav_path"] {
            if let Some(value) = self.request.get(field) {
                body[field] = value.clone();
            }
        }
        let reply = self
            .inference
            .request(body, Duration::from_secs(30), &self.request["id"])?;
        Ok(Transcript {
            text: reply["text"]
                .as_str()
                .ok_or("Invalid transcription reply")?
                .to_string(),
            avg_logprob: reply["avg_logprob"].as_f64().filter(|n| n.is_finite()),
        })
    }
}
/// Evaluation-only `cleanup_llm: false`: behaves as an unavailable cleanup model,
/// so the reply is the deterministic dictionary + vocabulary result.
struct DisabledLlm;
impl Llm for DisabledLlm {
    fn generate(&self, _request: &Request) -> Result<String, LlmError> {
        Err(LlmError("Cleanup model disabled by request".into()))
    }
}
struct FixedLlm<'a>(&'a Value);
impl Llm for FixedLlm<'_> {
    fn generate(&self, request: &Request) -> Result<String, LlmError> {
        if self.0["llm_error"] == true {
            return Err(LlmError("Synthetic inference failure".into()));
        }
        Ok(self.0["generation"]
            .as_str()
            .unwrap_or(request.text)
            .to_string())
    }
}

fn local_options(request: &Value) -> Result<Options, String> {
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
fn api_failure(error: oliv_transport::api::Failure) -> Value {
    json!({"ok":false,"code":error.code,"status":error.status,
        "retry_after":error.retry_after.map(|d|d.as_secs_f64())})
}
fn handle(request: &Value, inference: &Inference) -> Result<Value, String> {
    let command = request["cmd"].as_str().ok_or("invalidCommand")?;
    let id = &request["id"];
    if let Some(seconds) = request.get("cleanup_idle_seconds") {
        let seconds = seconds
            .as_u64()
            .filter(|s| matches!(s, 0 | 30))
            .ok_or("invalidMemoryPolicy")?;
        inference.set_cleanup_idle_seconds(seconds);
    }
    let engine = request["engine"].as_str().unwrap_or("typhoon-turbo-mlx");
    let llm = ModelLlm {
        inference,
        id,
        seconds: Cell::new(0.0),
    };
    match command {
        "ping" => Ok(json!({"ok":true,"pid":std::process::id(),"runtime":"rust-core"})),
        "api_health" | "api_dictate" | "api_dictionary" => {
            let config = oliv_transport::config::Config::from_request(request)?;
            if command == "api_health" {
                return Ok(match oliv_transport::api::health(&config) {
                    Ok(()) => json!({"ok":true}),
                    Err(e) => api_failure(e),
                });
            }
            if command == "api_dictionary" {
                // `ops` present: POST changes; absent: GET the snapshot.
                let ops = request.get("ops").filter(|o| !o.is_null());
                return Ok(match oliv_transport::api::dictionary(&config, ops) {
                    Ok(mut snapshot) => {
                        snapshot["ok"] = json!(true);
                        snapshot
                    }
                    Err(e) => api_failure(e),
                });
            }
            let samples = pcm(request, 1_920_000)?.ok_or("invalidAudio")?;
            let wav = oliv_transport::wav::encode_float(&samples).map_err(str::to_string)?;
            Ok(match oliv_transport::api::dictate(&config, &wav) {
                Ok(reply) => serde_json::to_value(reply).map_err(|_| "invalidReply")?,
                Err(e) => api_failure(e),
            })
        }
        "memory_policy" => {
            if request.get("cleanup_idle_seconds").is_none() {
                return Err("invalidMemoryPolicy".into());
            }
            inference.apply_cleanup_policy(id)?;
            Ok(json!({"ok":true}))
        }
        "warm" => {
            let start = Instant::now();
            if engine != "groq-large-v3" {
                inference.request(
                    json!({"cmd":"stt_load","engine":engine}),
                    Duration::from_secs(120),
                    id,
                )?;
            }
            let stt = start.elapsed().as_secs_f64();
            let mut cleanup = 0.0;
            let mut warming = false;
            if request["cleanup"].as_bool().unwrap_or(true) {
                let start = Instant::now();
                let prompt = local_options(request)?.prompt;
                let prime = Request {
                    prompt,
                    text: "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา",
                    hints: &[],
                };
                let reply = inference.request(
                    json!({"cmd":"llm_warm","content":prime.content(),
                    "background":request["background_cleanup"]==true}),
                    Duration::from_secs(120),
                    id,
                )?;
                warming = reply["cleanup_warming"] == true;
                if !warming {
                    cleanup = start.elapsed().as_secs_f64();
                }
            }
            Ok(
                json!({"ok":true,"engine":engine,"t_stt_load":stt,"t_cleanup_load":cleanup,"cleanup_warming":warming}),
            )
        }
        "cleanup_warm" => inference.request(
            json!({"cmd":"llm_warm","background":true,"load_only":true,
                "recording_token":request["recording_token"]}),
            Duration::from_secs(120),
            id,
        ),
        "cleanup_release" => inference.request(
            json!({"cmd":"llm_release_warm","recording_token":request["recording_token"]}),
            Duration::from_secs(120),
            id,
        ),
        "download" => inference.request(
            json!({"cmd":"download","repos":request["repos"]}),
            Duration::from_secs(1800),
            id,
        ),
        "clean" => {
            let start = Instant::now();
            let opts = local_options(request)?;
            let r = oliv_pipeline::pipeline::clean_ex(
                request["text"].as_str().unwrap_or(""),
                &opts.effective_vocabulary(),
                &opts.dictionary,
                opts.prompt,
                &llm,
            );
            let mut value = serde_json::to_value(&r).map_err(|_| "invalidReply")?;
            value["ok"] = json!(true);
            value["t_total"] = json!(start.elapsed().as_secs_f64());
            value["t_llm"] = json!(llm.seconds.get());
            value["cleanup_error"] = json!(r.llm_error);
            Ok(value)
        }
        "transform" => {
            let mut reply = transform_reply(request, &llm)?;
            reply["t_llm"] = json!(llm.seconds.get());
            Ok(reply)
        }
        "text" => {
            let opts = local_options(request)?;
            let out = local::clean(
                request["text"].as_str().unwrap_or(""),
                request["duration"].as_f64(),
                &opts,
                request["format_commands"] == true,
                &FixedLlm(request),
            );
            let mut result = serde_json::to_value(out).map_err(|_| "invalidReply")?;
            result["ok"] = json!(true);
            Ok(result)
        }
        "preview" => preview(request, engine, inference),
        "dictate" => {
            let samples = pcm(request, audio::MAX_SAMPLES)?;
            if samples
                .as_ref()
                .is_some_and(|s| s.iter().any(|f| !f.is_finite()))
            {
                return Err("invalidAudio".into());
            }
            let no_speech = |reason: &str, t_stt: f64| {
                json!({"ok":true,"engine":engine,"raw":"","final":"",
                "no_speech":true,"t_stt":t_stt,"t_cleanup":0,"gate_reason":reason})
            };
            if samples.as_ref().is_some_and(|s| audio::is_silent(s)) {
                return Ok(no_speech("silent", 0.0));
            }
            let duration = samples.as_ref().map(|s| s.len() as f64 / 16000.0);
            let opts = local_options(request)?;
            let initial_prompt = stt_initial_prompt(request, engine, &opts.effective_vocabulary());
            let stt = ModelStt {
                inference,
                request,
                engine,
            };
            let start = Instant::now();
            // Evaluation replay of an earlier decode of this same audio. The app
            // never sends it; silence and duration gates still use the PCM.
            let replay = request.get("stt_text").and_then(Value::as_str);
            let (raw, redecoded) = if let Some(text) = replay {
                (text.to_string(), false)
            } else if let Some(language) = request["language"].as_str().filter(|s| !s.is_empty()) {
                (
                    stt.transcribe(&[], initial_prompt.as_deref(), Some(language))?
                        .text,
                    false,
                )
            } else {
                oliv_pipeline::stt::transcribe_maybe_redecode(&stt, &[], initial_prompt.as_deref())?
            };
            let t_stt = start.elapsed().as_secs_f64();
            let start = Instant::now();
            let cleanup_llm: &dyn Llm = if request["cleanup_llm"] == false {
                &DisabledLlm
            } else {
                &llm
            };
            let out = local::clean(
                &raw,
                duration,
                &opts,
                request["format_commands"] == true,
                cleanup_llm,
            );
            if out.outcome.no_speech {
                return Ok(no_speech(&out.outcome.gate_reason, t_stt));
            }
            let mut reply = serde_json::to_value(out).map_err(|_| "invalidReply")?;
            reply["ok"] = json!(true);
            reply["raw"] = json!(raw);
            reply["engine"] = json!(engine);
            reply["stt_redecoded"] = json!(redecoded);
            reply["stt_replayed"] = json!(replay.is_some());
            reply["t_stt"] = json!(t_stt);
            reply["t_cleanup"] = json!(start.elapsed().as_secs_f64());
            reply["t_llm"] = json!(llm.seconds.get());
            Ok(reply)
        }
        _ => Err("invalidCommand".into()),
    }
}

/// On-device engines that may preview while the key is held. Groq and the OLIV
/// API never do: a preview must not upload audio.
const PREVIEW_ENGINES: [&str; 3] = ["typhoon-turbo-mlx", "pathumma-mlx", "mlx-large-v3"];
/// One Whisper window: a preview transcribes only the newest audio.
const PREVIEW_MAX_SAMPLES: usize = audio::RATE * 30;

/// A preview's light cleanup: the dictate pipeline's deterministic steps
/// (built-in dictionary, the user's Dictionary and words, numbers, ๆ, fillers)
/// with the cleanup model left out, so it takes milliseconds and never touches
/// the GPU. `None` when the text is no speech (a hallucination or too long for
/// the audio). Options are the dictate request's own (`cleanup`,
/// `dictionary`, `vocabulary`, ...), so a verbatim app stays verbatim.
fn light_clean(
    request: &Value,
    text: &str,
    duration: Option<f64>,
) -> Result<Option<String>, String> {
    let opts = local_options(request)?;
    let out = local::clean(
        text,
        duration,
        &opts,
        request["format_commands"] == true,
        &DisabledLlm,
    );
    Ok((!out.outcome.no_speech).then(|| out.outcome.final_text.trim().to_string()))
}

/// Live preview while the key is held: speech-to-text on the newest audio,
/// greedy, with the engine that is already loaded (no cleanup model, no
/// English re-decode). `light_cleanup: true` adds the deterministic cleanup
/// (see `light_clean`). The app shows it and never pastes it; the final
/// `dictate` after release is unchanged. `preview_seq` lets the app cancel it
/// out of band (`cancel_preview`), even mid-decode. `include_raw: true` also
/// returns the text before cleanup (evaluation).
fn preview(request: &Value, engine: &str, inference: &Inference) -> Result<Value, String> {
    let handled = Instant::now();
    if !PREVIEW_ENGINES.contains(&engine) {
        return Err("previewUnavailable".into());
    }
    let seq = request["preview_seq"]
        .as_u64()
        .filter(|seq| *seq > 0)
        .ok_or("invalidPreview")?;
    let samples = pcm(request, PREVIEW_MAX_SAMPLES)?.ok_or("invalidAudio")?;
    if samples.iter().any(|f| !f.is_finite()) {
        return Err("invalidAudio".into());
    }
    let skipped = |reason: &str, t_stt: f64| json!({"ok":true,"engine":engine,"text":"","skipped":reason,"t_stt":t_stt});
    if inference.preview_cancelled(seq) {
        return Ok(skipped("cancelled", 0.0));
    }
    if audio::is_silent(&samples) {
        return Ok(skipped("silent", 0.0));
    }
    let mut stt =
        json!({"cmd":"stt","engine":engine,"pcm_b64":request["pcm_b64"],"preview_seq":seq});
    for field in ["preview_floor", "preview_tail"] {
        if let Some(value) = request.get(field).filter(|v| v.is_number()) {
            stt[field] = value.clone();
        }
    }
    let start = Instant::now();
    let reply = inference.request(stt, Duration::from_secs(30), &request["id"])?;
    let t_stt = start.elapsed().as_secs_f64();
    // Timings only: how long each stage took, never any text.
    let finish = |mut value: Value| {
        value["timings"] = reply["timings"].clone();
        value["t_sidecar"] = json!(handled.elapsed().as_secs_f64());
        value
    };
    if let Some(reason) = reply["skipped"].as_str() {
        return Ok(finish(skipped(reason, t_stt)));
    }
    let raw = hallucination::strip_cjk(reply["text"].as_str().unwrap_or(""));
    if hallucination::text_hallucination(&raw) {
        return Ok(finish(skipped("noSpeech", t_stt)));
    }
    let start = Instant::now();
    let text = if request["light_cleanup"] == true {
        let duration = Some(samples.len() as f64 / audio::RATE as f64);
        match light_clean(request, &raw, duration)? {
            Some(text) => text,
            None => return Ok(finish(skipped("noSpeech", t_stt))),
        }
    } else {
        raw.trim().to_string()
    };
    let mut value = json!({"ok":true,"engine":engine,"text":text,"t_stt":t_stt,
        "t_clean":start.elapsed().as_secs_f64()});
    if request["include_raw"] == true {
        value["raw"] = json!(raw.trim());
    }
    Ok(finish(value))
}

/// Whisper initial prompt using the same engine policy as the app.
fn stt_initial_prompt(request: &Value, engine: &str, vocabulary: &[String]) -> Option<String> {
    if !oliv_pipeline::stt::uses_initial_prompt(engine) {
        return None;
    }
    commands::initial_prompt(
        request["initial_prompt"].as_str(),
        vocabulary,
        request["format_commands"] == true,
    )
}

enum Incoming {
    Request(Value),
    Invalid,
    TooLarge,
}

/// Read requests on their own thread, so a `cancel_preview` takes effect while
/// the request loop is still waiting on that preview. Every other line keeps
/// its order; the cancel itself gets no reply.
fn read_requests(mut reader: impl BufRead, cancel: impl Fn(u64), requests: mpsc::Sender<Incoming>) {
    loop {
        let mut line = Vec::new();
        let incoming = match (&mut reader)
            .take(MAX_REQUEST + 1)
            .read_until(b'\n', &mut line)
        {
            Ok(0) | Err(_) => return,
            Ok(_) if line.len() as u64 > MAX_REQUEST => Incoming::TooLarge,
            _ => match serde_json::from_slice(&line) {
                Ok(Value::Object(body)) if body.get("cmd") == Some(&json!("cancel_preview")) => {
                    if let Some(through) = body.get("through").and_then(Value::as_u64) {
                        cancel(through);
                    }
                    continue;
                }
                Ok(Value::Object(body)) => Incoming::Request(Value::Object(body)),
                _ => Incoming::Invalid,
            },
        };
        let last = match &incoming {
            Incoming::TooLarge => true,
            Incoming::Request(request) => request["cmd"] == "shutdown",
            Incoming::Invalid => false,
        };
        if requests.send(incoming).is_err() || last {
            return;
        }
    }
}

fn main() {
    // Panic details can include user inputs; stdout remains protocol-only.
    std::panic::set_hook(Box::new(|_| eprintln!("OLIV Rust worker failed")));
    let once = std::env::args().any(|a| a == "--once");
    let inference = Arc::new(Inference::default());
    let (sender, requests) = mpsc::channel();
    let cancels = Arc::clone(&inference);
    std::thread::spawn(move || {
        read_requests(
            io::stdin().lock(),
            |through| cancels.cancel_previews(through),
            sender,
        );
    });
    for incoming in requests {
        let request = match incoming {
            Incoming::TooLarge => {
                let _ = emit(&json!({"ok":false,"code":"requestTooLarge"}));
                break;
            }
            Incoming::Invalid => {
                if emit(&json!({"ok":false,"code":"invalidRequest"})).is_err() || once {
                    break;
                }
                continue;
            }
            Incoming::Request(request) => request,
        };
        if request["cmd"] == "shutdown" {
            break;
        }
        let mut reply = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            handle(&request, &inference)
        })) {
            Ok(Ok(value)) => value,
            Ok(Err(code)) => {
                json!({"ok":false,"code":code,"error":"The Rust worker could not finish this request"})
            }
            Err(_) => json!({"ok":false,"code":"internal","error":"Rust worker failed"}),
        };
        reply["id"] = request["id"].clone();
        if emit(&reply).is_err() || once {
            break;
        }
    }
    // The stdin reader still holds a reference: stop the model helper here.
    inference.shutdown();
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Answer(&'static str);
    impl transform::Generate for Answer {
        fn generate(&self, _: &str, _: u32) -> Result<transform::Generation, LlmError> {
            Ok(transform::Generation::finished(self.0))
        }
    }
    struct Down;
    impl transform::Generate for Down {
        fn generate(&self, _: &str, _: u32) -> Result<transform::Generation, LlmError> {
            Err(LlmError("Inference runtime not configured".into()))
        }
    }
    /// The runtime's reply for `max_tokens`, as `transform_generation` reads it.
    struct Runtime(Value);
    impl transform::Generate for Runtime {
        fn generate(&self, _: &str, _: u32) -> Result<transform::Generation, LlmError> {
            transform_generation(&self.0)
        }
    }

    #[test]
    fn an_answer_that_hit_the_token_limit_keeps_the_text() {
        let answer = "รบกวนส่งไฟล์ deck มาให้หน่อยนะครับ";
        let read = |reply: Value| transform_generation(&reply).unwrap().finished;
        assert!(read(json!({"generation": answer, "stop_reason": "stop"})));
        assert!(!read(
            json!({"generation": answer, "stop_reason": "length"})
        ));
        assert!(!read(
            json!({"generation": answer, "stop_reason": "cancelled"})
        ));
        assert!(
            !read(json!({"generation": answer})),
            "no reason, no vouching for the end"
        );
        assert!(transform_generation(&json!({"stop_reason": "stop"})).is_err());

        let text = "ส่งไฟล์ deck มาด่วนเลย";
        for (mode, instruction) in [("command", "ทำให้สุภาพขึ้น"), ("translate", "")]
        {
            let request =
                json!({"cmd":"transform","mode":mode,"instruction":instruction,"text":text});
            let reply = transform_reply(
                &request,
                &Runtime(json!({"generation": answer, "stop_reason": "length"})),
            )
            .unwrap();
            assert_eq!(
                (
                    reply["applied"].clone(),
                    reply["flag"].clone(),
                    reply["text"].clone()
                ),
                (json!(false), json!("unfinished"), json!(text)),
                "{mode}"
            );
        }
        let request =
            json!({"cmd":"transform","mode":"command","instruction":"ทำให้สุภาพขึ้น","text":text});
        let reply = transform_reply(
            &request,
            &Runtime(json!({"generation": answer, "stop_reason": "stop"})),
        )
        .unwrap();
        assert_eq!(
            (reply["applied"].clone(), reply["text"].clone()),
            (json!(true), json!(answer))
        );
    }

    #[test]
    fn transform_reply_applies_or_keeps_the_text() {
        let text = "ส่งไฟล์ deck มาด่วนเลย";
        let request =
            json!({"cmd":"transform","mode":"command","instruction":"ทำให้สุภาพขึ้น","text":text});
        let reply = transform_reply(&request, &Answer("รบกวนส่งไฟล์ deck มาให้หน่อยนะครับ")).unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["applied"], true);
        assert_eq!(reply["text"], "รบกวนส่งไฟล์ deck มาให้หน่อยนะครับ");
        assert!(reply.get("raw").is_none());
        // A model failure is not a protocol failure: the original comes back.
        let reply = transform_reply(&request, &Down).unwrap();
        assert_eq!(
            (reply["ok"].clone(), reply["applied"].clone()),
            (json!(true), json!(false))
        );
        assert_eq!(reply["text"], text);
        assert_eq!(reply["flag"], "llmError");
        // Evaluation asks for the raw generation.
        let mut eval = request.clone();
        eval["include_raw"] = json!(true);
        let reply = transform_reply(&eval, &Answer("As an AI I cannot")).unwrap();
        assert_eq!(reply["applied"], false);
        assert_eq!(reply["raw"], "As an AI I cannot");
        assert_eq!(reply["text"], text);
        for bad in [
            json!({"cmd":"transform","mode":"poem","text":"x"}),
            json!({"cmd":"transform","mode":"command"}),
        ] {
            assert!(transform_reply(&bad, &Down).is_err());
        }
    }

    fn incoming(input: &str) -> (Vec<Value>, Vec<u64>) {
        let (sender, receiver) = mpsc::channel();
        let cancels = std::cell::RefCell::new(Vec::new());
        read_requests(
            io::Cursor::new(input.as_bytes().to_vec()),
            |through| cancels.borrow_mut().push(through),
            sender,
        );
        let requests = receiver
            .try_iter()
            .map(|item| match item {
                Incoming::Request(request) => request,
                Incoming::Invalid => json!("invalid"),
                Incoming::TooLarge => json!("too large"),
            })
            .collect();
        (requests, cancels.into_inner())
    }

    #[test]
    fn cancel_preview_is_handled_out_of_band_and_never_queued() {
        let (requests, cancels) = incoming(concat!(
            "{\"id\":1,\"cmd\":\"preview\"}\n",
            "{\"cmd\":\"cancel_preview\",\"through\":1}\n",
            "not json\n",
            "{\"id\":2,\"cmd\":\"dictate\"}\n",
        ));
        assert_eq!(cancels, vec![1]);
        assert_eq!(
            requests,
            vec![
                json!({"id":1,"cmd":"preview"}),
                json!("invalid"),
                json!({"id":2,"cmd":"dictate"})
            ]
        );
    }

    #[test]
    fn reading_stops_after_shutdown() {
        let (requests, _) = incoming(concat!(
            "{\"id\":1,\"cmd\":\"shutdown\"}\n",
            "{\"id\":2,\"cmd\":\"ping\"}\n",
        ));
        assert_eq!(requests, vec![json!({"id":1,"cmd":"shutdown"})]);
    }

    fn pcm_b64(samples: &[f32]) -> String {
        B64.encode(
            samples
                .iter()
                .flat_map(|s| s.to_le_bytes())
                .collect::<Vec<_>>(),
        )
    }

    #[test]
    fn light_clean_runs_the_deterministic_steps_without_the_model() {
        // A built-in spelling (ดีพลอย → deploy) and the user's own entry; no
        // helper is configured, so the cleanup model can't have run.
        let request = json!({"dictionary":[{"word":"Grafana","correction":"กราฟาน่า"}]});
        let text = light_clean(&request, "ดีพลอย แล้วเช็ค กราฟาน่า", Some(3.0))
            .unwrap()
            .unwrap();
        assert!(text.contains("deploy"), "{text}");
        assert!(text.contains("Grafana"), "{text}");
        assert!(!text.contains("ดีพลอย"), "{text}");
        // A verbatim app (cleanup off) keeps the built-in spelling as heard.
        let verbatim = light_clean(&json!({"cleanup":false}), "ดีพลอย แล้วเช็ค", Some(3.0))
            .unwrap()
            .unwrap();
        assert!(verbatim.contains("ดีพลอย"), "{verbatim}");
        // Far too much text for the audio is no speech, as in dictate.
        let long = "ดีพลอย ".repeat(80);
        assert_eq!(light_clean(&json!({}), &long, Some(0.5)).unwrap(), None);
    }

    #[test]
    fn previews_never_reach_a_cloud_engine() {
        // No helper is configured: any attempt to transcribe would fail with a
        // different error than the policy refusal.
        let inference = Inference::default();
        for engine in ["groq-large-v3", "oliv-api", "oliv-trial", "unknown"] {
            let request = json!({"cmd":"preview","engine":engine,"preview_seq":1,
                "pcm_b64":pcm_b64(&[0.1; 16_000])});
            assert_eq!(
                handle(&request, &inference).unwrap_err(),
                "previewUnavailable",
                "{engine}"
            );
        }
    }

    #[test]
    fn preview_guards_run_before_the_model() {
        let inference = Inference::default();
        let speech: Vec<f32> = (0..32_000).map(|i| (i as f32 * 0.05).sin() * 0.2).collect();
        let request = |seq: Value, samples: &[f32]| {
            json!({"cmd":"preview","engine":"typhoon-turbo-mlx","preview_seq":seq,
                "pcm_b64":pcm_b64(samples)})
        };
        assert_eq!(
            handle(&request(json!(0), &speech), &inference).unwrap_err(),
            "invalidPreview"
        );
        let too_long = vec![0.1; PREVIEW_MAX_SAMPLES + 1];
        assert_eq!(
            handle(&request(json!(1), &too_long), &inference).unwrap_err(),
            "audioTooLong"
        );
        let silent = handle(&request(json!(1), &[0.0; 16_000]), &inference).unwrap();
        assert_eq!(silent["skipped"], "silent");
        inference.cancel_previews(3);
        let cancelled = handle(&request(json!(2), &speech), &inference).unwrap();
        assert_eq!(cancelled["skipped"], "cancelled");
        assert_eq!(cancelled["text"], "");
        // Not cancelled, so it reaches the (unconfigured) helper and fails.
        assert!(handle(&request(json!(4), &speech), &inference).is_err());
    }

    #[test]
    fn initial_prompt_follows_the_shipped_engine_policy() {
        let vocab = vec!["Kafka".to_string(), "คลองเตย".to_string()];
        let plain = json!({"cmd": "dictate"});
        assert_eq!(
            stt_initial_prompt(&plain, "typhoon-turbo-mlx", &vocab),
            None
        );
        assert_eq!(
            stt_initial_prompt(&plain, "pathumma-mlx", &vocab).as_deref(),
            Some("Kafka, คลองเตย")
        );
        assert_eq!(
            stt_initial_prompt(&plain, "mlx-large-v3", &vocab).as_deref(),
            Some("Kafka, คลองเตย")
        );
        assert_eq!(stt_initial_prompt(&plain, "pathumma-mlx", &[]), None);
    }
}
