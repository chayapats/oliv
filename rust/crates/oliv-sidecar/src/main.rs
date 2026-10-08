mod inference;
use base64::Engine;
use inference::Inference;
use oliv_pipeline::{
    audio, commands,
    dictate::Options,
    llm::{Llm, LlmError, Prompt, Request},
    local,
    stt::{Stt, Transcript},
};
use serde_json::{Value, json};
use std::cell::Cell;
use std::io::{self, BufRead, Read, Write};
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
    let engine = request["engine"].as_str().unwrap_or("typhoon-turbo-mlx");
    let llm = ModelLlm {
        inference,
        id,
        seconds: Cell::new(0.0),
    };
    match command {
        "ping" => Ok(
            json!({"ok":true,"pid":std::process::id(),"runtime":"rust-core","upstream":"0000a4d"}),
        ),
        "api_health" | "api_dictate" => {
            let config = oliv_transport::config::Config::from_request(request)?;
            if command == "api_health" {
                return Ok(match oliv_transport::api::health(&config) {
                    Ok(()) => json!({"ok":true}),
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
                &opts.vocabulary,
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
            let initial_prompt = if engine == "typhoon-turbo-mlx" {
                None
            } else {
                commands::initial_prompt(
                    request["initial_prompt"].as_str(),
                    &opts.vocabulary,
                    request["format_commands"] == true,
                )
            };
            let stt = ModelStt {
                inference,
                request,
                engine,
            };
            let start = Instant::now();
            let (raw, redecoded) = if let Some(language) =
                request["language"].as_str().filter(|s| !s.is_empty())
            {
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
            let out = local::clean(
                &raw,
                duration,
                &opts,
                request["format_commands"] == true,
                &llm,
            );
            if out.outcome.no_speech {
                return Ok(no_speech(&out.outcome.gate_reason, t_stt));
            }
            let mut reply = serde_json::to_value(out).map_err(|_| "invalidReply")?;
            reply["ok"] = json!(true);
            reply["raw"] = json!(raw);
            reply["engine"] = json!(engine);
            reply["stt_redecoded"] = json!(redecoded);
            reply["t_stt"] = json!(t_stt);
            reply["t_cleanup"] = json!(start.elapsed().as_secs_f64());
            reply["t_llm"] = json!(llm.seconds.get());
            Ok(reply)
        }
        _ => Err("invalidCommand".into()),
    }
}

fn main() {
    // Panic details can include user inputs; stdout remains protocol-only.
    std::panic::set_hook(Box::new(|_| eprintln!("OLIV Rust worker failed")));
    let once = std::env::args().any(|a| a == "--once");
    let inference = Inference::default();
    let mut reader = io::stdin().lock();
    loop {
        let mut line = Vec::new();
        match (&mut reader)
            .take(MAX_REQUEST + 1)
            .read_until(b'\n', &mut line)
        {
            Ok(0) | Err(_) => break,
            Ok(_) if line.len() as u64 > MAX_REQUEST => {
                let _ = emit(&json!({"ok":false,"code":"requestTooLarge"}));
                break;
            }
            _ => (),
        }
        let request: Value = match serde_json::from_slice(&line) {
            Ok(Value::Object(body)) => Value::Object(body),
            _ => {
                if emit(&json!({"ok":false,"code":"invalidRequest"})).is_err() || once {
                    break;
                }
                continue;
            }
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
}
