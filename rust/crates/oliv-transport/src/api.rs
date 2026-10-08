//! Talking to oliv-api `POST /v1/dictate` (see "สัญญา HTTP" in `docs/PLAN.md`),
//! and what to do with its reply.

use std::time::{Duration, SystemTime};

use base64::Engine;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::config::Config;

pub const USER_AGENT: &str = concat!("oliv-macos/", env!("CARGO_PKG_VERSION"));

/// The fields of a dictate reply the client uses.
#[derive(Clone, Debug, Default, Deserialize, serde::Serialize, PartialEq)]
#[serde(default)]
pub struct Reply {
    pub ok: bool,
    pub raw: String,
    #[serde(rename = "final")]
    pub final_text: String,
    pub no_speech: bool,
    pub stt_redecoded: bool,
    pub t_stt: f64,
    pub t_cleanup: f64,
    pub llm_ran: bool,
    pub gate_reason: String,
    pub guardrail_flag: String,
    pub cleanup_error: Option<String>,
    pub error: Option<String>,
    pub fillers_removed: usize,
    pub replacements_fired: usize,
    pub thai_format_fired: usize,
}

/// The request body. `prompt` is left out so the server's default applies.
pub fn body(cfg: &Config, wav: &[u8]) -> Value {
    let replacements: Map<String, Value> = cfg
        .replacements
        .iter()
        .map(|(k, v)| (k.clone(), Value::String(v.clone())))
        .collect();
    json!({
        "wav_b64": base64::engine::general_purpose::STANDARD.encode(wav),
        "cleanup": cfg.cleanup,
        "remove_fillers": cfg.remove_fillers,
        "thai_format": cfg.thai_format,
        "vocabulary": cfg.vocabulary,
        "replacements": replacements,
    })
}

/// Safe, client-owned diagnostics: never echo response bodies or transport URLs.
#[derive(Debug)]
pub struct Failure {
    message: String,
    pub retry_after: Option<Duration>,
    pub code: &'static str,
    pub status: Option<u16>,
    pub notice: &'static str,
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::ops::Deref for Failure {
    type Target = str;
    fn deref(&self) -> &str {
        &self.message
    }
}

impl From<String> for Failure {
    fn from(message: String) -> Self {
        Self {
            message,
            retry_after: None,
            code: "invalidReply",
            status: None,
            notice: "Request failed — try again later",
        }
    }
}

fn failure(message: &str) -> Failure {
    message.to_string().into()
}

fn status_error(status: u16, text: &str) -> Failure {
    let json = serde_json::from_str::<Value>(text).ok();
    let detail = json.as_ref().and_then(|j| j["error"].as_str());
    let lower = text.to_ascii_lowercase();
    let why = match status {
        301..=399 => "redirect rejected; configure the final HTTPS API URL",
        400 => "invalid JSON/options/base64/WAV; use PCM16 mono 16000 Hz WAV",
        401 => {
            "API key invalid, expired or revoked; check/replace server.token with a new individual key"
        }
        403 if detail == Some("API key does not allow this operation") => {
            "API key lacks scope dictate; ask the administrator for a key with that scope"
        }
        403 if lower.contains("error code: 1010") => {
            "Cloudflare blocked this client (1010); contact the administrator and report the oliv-linux version"
        }
        403 if lower.contains("cloudflare") => {
            "Cloudflare denied the request; contact the administrator"
        }
        403 => "access denied; check key scope dictate or Cloudflare policy with the administrator",
        408 => "upload timed out; retry later",
        413 => "audio/request too large; record a shorter clip (maximum 120 seconds)",
        415 => "unsupported data format; the API requires uncompressed JSON with WAV base64",
        429 => "API key busy or quota exceeded; retry later",
        500..=599 => "server/pipeline unavailable; try again later",
        _ => "unexpected API response; check the API URL",
    };
    let mut error: Failure = format!("HTTP {status}: {why}").into();
    error.code = if (300..400).contains(&status) {
        "redirect"
    } else {
        "http"
    };
    error.status = Some(status);
    error.notice = match status {
        401 => "key ใช้ไม่ได้ กรุณาตรวจ/เปลี่ยน key ",
        403 if lower.contains("1010") || lower.contains("cloudflare") => "Cloudflare ปฏิเสธคำขอ ",
        403 => "สิทธิ์ไม่พอ ตรวจ scope dictate ",
        429 => "key ไม่ว่าง/เกินโควตา รอก่อน retry ",
        400 | 415 => "รูปแบบเสียงไม่ถูกต้อง ",
        413 => "เสียงใหญ่เกินไป ลองอัดสั้นลง ",
        _ => "Request failed — try again later",
    };
    error
}

/// Require a real dictation result: a liveness reply is not a transcript.
/// Optional pipeline metadata remains backward compatible.
pub fn parse_reply(status: u16, text: &str) -> Result<Reply, Failure> {
    if status != 200 {
        return Err(status_error(status, text));
    }
    let mut value: Value = serde_json::from_str(text)
        .map_err(|_| failure("HTTP 200: malformed JSON reply; request failed"))?;
    if value["ok"] != true {
        return Err(failure(
            "HTTP 200: dictation failed (ok is not true); request failed",
        ));
    }
    if !value["final"].is_string() && !(value.get("final").is_none() && value["no_speech"] == true)
    {
        return Err(failure(
            "HTTP 200: missing/invalid final text; request failed",
        ));
    }
    for field in ["t_stt", "t_cleanup"] {
        if let Some(value) = value.get(field)
            && !value.is_null()
            && !value.as_f64().is_some_and(|n| n.is_finite() && n >= 0.0)
        {
            return Err(failure("HTTP 200: invalid timing fields"));
        }
    }
    // Swift's optional metadata decoder accepts null as absent. Keep that contract.
    for field in [
        "raw",
        "no_speech",
        "stt_redecoded",
        "t_stt",
        "t_cleanup",
        "llm_ran",
        "gate_reason",
        "guardrail_flag",
        "fillers_removed",
        "replacements_fired",
        "thai_format_fired",
    ] {
        if value[field].is_null() {
            value.as_object_mut().unwrap().remove(field);
        }
    }
    serde_json::from_value(value)
        .map_err(|_| failure("HTTP 200: invalid dictation fields; request failed"))
}

pub(crate) fn platform_tls() -> ureq::tls::TlsConfig {
    // Match URLSession's macOS trust store, including user-managed CAs.
    ureq::tls::TlsConfig::builder()
        .root_certs(ureq::tls::RootCerts::PlatformVerifier)
        .build()
}

fn agent_config(cfg: &Config) -> ureq::config::ConfigBuilder<ureq::typestate::AgentScope> {
    ureq::Agent::config_builder()
        .tls_config(platform_tls())
        .timeout_global(Some(cfg.request_timeout))
        .user_agent(&cfg.user_agent)
        .max_redirects(0)
        .http_status_as_error(false)
}

fn transport_error(e: ureq::Error) -> Failure {
    // ureq diagnostics may contain untrusted URLs; expose only the category.
    let mut error = match e {
        ureq::Error::Timeout(_) => failure("request timed out; request failed"),
        _ => failure(
            "network/TLS error; check connectivity, certificate, hostname and system clock; request failed",
        ),
    };
    error.code = match e {
        ureq::Error::Timeout(_) => "timeout",
        ureq::Error::BodyExceedsLimit(_) => "responseTooLarge",
        _ => "network",
    };
    error
}

fn retry_after(header: Option<&str>, now: SystemTime) -> Duration {
    header
        .and_then(|h| {
            h.parse::<u64>().ok().map(Duration::from_secs).or_else(|| {
                httpdate::parse_http_date(h)
                    .ok()
                    .map(|date| date.duration_since(now).unwrap_or_default())
            })
        })
        .unwrap_or(Duration::from_secs(60))
        .max(Duration::from_secs(1))
}

pub fn dictate(cfg: &Config, wav: &[u8]) -> Result<Reply, Failure> {
    dictate_with_agent(cfg, wav, &agent_config(cfg).build().into())
}

fn dictate_with_agent(cfg: &Config, wav: &[u8], agent: &ureq::Agent) -> Result<Reply, Failure> {
    let encoded =
        serde_json::to_vec(&body(cfg, wav)).map_err(|_| failure("cannot encode request"))?;
    if encoded.len() > 8 * 1024 * 1024 {
        let mut error = failure("API request is too large");
        error.code = "requestTooLarge";
        return Err(error);
    }
    let mut resp = agent
        .post(&format!("{}/v1/dictate", cfg.url))
        .header("Authorization", &format!("Bearer {}", cfg.token))
        .header("Content-Type", "application/json")
        .send(&encoded)
        .map_err(transport_error)?;
    let status = resp.status().as_u16();
    let header = resp
        .headers()
        .get("Retry-After")
        .and_then(|h| h.to_str().ok());
    let delay = if status == 429 || (status >= 500 && header.is_some()) {
        Some(retry_after(header, SystemTime::now()))
    } else {
        None
    };
    if status != 200 {
        let mut error = status_error(status, "");
        error.retry_after = delay;
        return Err(error);
    }
    let text = resp
        .body_mut()
        .with_config()
        .limit(1024 * 1024)
        .read_to_string();
    let result = match text {
        Ok(text) => parse_reply(status, &text),
        Err(_) if status != 200 => Err(status_error(status, "")),
        Err(e) => Err(transport_error(e)),
    };
    result.map_err(|mut e| {
        e.retry_after = delay;
        if let Some(delay) = delay {
            e.message.push_str(&format!(
                "; wait at least {} seconds before trying again",
                delay.as_secs()
            ));
        }
        e
    })
}

/// An optional diagnostic, never a prerequisite for recording/inference.
/// No Authorization header and no backend readiness assumptions.
pub fn health(cfg: &Config) -> Result<(), Failure> {
    let agent: ureq::Agent = agent_config(cfg).build().into();
    let mut response = agent
        .get(&format!("{}/health", cfg.url))
        .call()
        .map_err(transport_error)?;
    let status = response.status().as_u16();
    if status != 200 {
        return Err(status_error(status, ""));
    }
    let value: Value = response
        .body_mut()
        .with_config()
        .limit(8192)
        .read_json()
        .map_err(|_| failure("invalid health response"))?;
    if value["ok"] != true {
        return Err(failure("API liveness check failed"));
    }
    Ok(())
}

#[cfg(test)]
#[path = "api/tls_tests.rs"]
mod tls_tests;

pub const NO_SPEECH: &str = "ไม่ได้ยินเสียงพูด";

#[derive(Debug, PartialEq)]
pub enum Action<'a> {
    Paste(&'a str),
    Notice(&'static str),
}

/// What to do with a successful reply: paste the text, or say nothing was heard
/// (also when cleanup left nothing, e.g. only fillers were spoken).
pub fn action(reply: &Reply) -> Action<'_> {
    if reply.no_speech || reply.final_text.trim().is_empty() {
        Action::Notice(NO_SPEECH)
    } else {
        Action::Paste(&reply.final_text)
    }
}

/// One history.jsonl line. `source` is `dictate` or `retry`; `t_total` is the
/// client-side round trip.
pub fn history_entry(
    ts: &str,
    source: &str,
    audio_s: f64,
    reply: &Reply,
    t_total: f64,
    pasted: bool,
) -> Value {
    let r3 = |x: f64| (x * 1000.0).round() / 1000.0;
    json!({
        "ts": ts,
        "source": source,
        "audio_s": r3(audio_s),
        "raw": reply.raw,
        "final": reply.final_text,
        "t_stt": r3(reply.t_stt),
        "t_cleanup": r3(reply.t_cleanup),
        "t_total": r3(t_total),
        "llm_ran": reply.llm_ran,
        "gate_reason": reply.gate_reason,
        "guardrail_flag": reply.guardrail_flag,
        "cleanup_error": reply.cleanup_error,
        "no_speech": reply.no_speech,
        "stt_redecoded": reply.stt_redecoded,
        "pasted": pasted,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        Config {
            url: "http://h:1".into(),
            user_agent: USER_AGENT.to_string(),
            token: "t".into(),
            request_timeout: crate::config::DEFAULT_TIMEOUT,
            cleanup: true,
            remove_fillers: false,
            thai_format: true,
            vocabulary: vec!["Grafana".into()],
            replacements: vec![("ซี".into(), "C".into()), ("เอ".into(), "A".into())],
        }
    }

    #[test]
    fn body_fields() {
        let b = body(&cfg(), &[1, 2, 3]);
        assert_eq!(b["wav_b64"], "AQID");
        assert_eq!(b["cleanup"], true);
        assert_eq!(b["remove_fillers"], false);
        assert_eq!(b["thai_format"], true);
        assert_eq!(b["vocabulary"], json!(["Grafana"]));
        assert!(b.get("prompt").is_none());
        // Order survives into the JSON text: the server applies them in order.
        let text = serde_json::to_string(&b["replacements"]).unwrap();
        assert_eq!(text, r#"{"ซี":"C","เอ":"A"}"#);
    }

    #[test]
    fn reply_ok_and_action() {
        let r = parse_reply(
            200,
            r#"{"ok":true,"raw":"r","final":"สวัสดี","no_speech":false,"t_stt":1.5,
                "cleanup_error":null,"dict_hits":2,"stt_redecoded":true}"#,
        )
        .unwrap();
        assert_eq!(r.final_text, "สวัสดี");
        assert!(r.stt_redecoded);
        assert_eq!(action(&r), Action::Paste("สวัสดี"));
    }

    #[test]
    fn no_speech_and_empty_final_are_notices() {
        let r = parse_reply(200, r#"{"ok":true,"raw":"x","final":"","no_speech":true}"#).unwrap();
        assert_eq!(action(&r), Action::Notice(NO_SPEECH));
        let r = parse_reply(
            200,
            r#"{"ok":true,"raw":"เอ่อ","final":" ","no_speech":false}"#,
        )
        .unwrap();
        assert_eq!(action(&r), Action::Notice(NO_SPEECH));
    }

    #[test]
    fn failures() {
        let e = parse_reply(502, r#"{"ok":false,"error":"whisper: timed out"}"#).unwrap_err();
        assert!(e.contains("502") && e.contains("server/pipeline"), "{e}");
        assert!(parse_reply(401, r#"{"ok":false,"error":"unauthorized"}"#).is_err());
        assert!(parse_reply(200, r#"{"ok":false}"#).is_err());
        assert!(parse_reply(200, "<html>").is_err());
        assert!(parse_reply(500, r#"{"ok":true,"final":"x"}"#).is_err());
    }

    #[test]
    fn nullable_metadata_preserves_swift_reply_contract() {
        let r = parse_reply(
            200,
            r#"{"ok":true,"final":"hello","raw":null,
            "no_speech":null,"t_stt":null,"t_cleanup":null,"stt_redecoded":null,
            "llm_ran":null,"cleanup_error":null}"#,
        )
        .unwrap();
        assert_eq!(r.final_text, "hello");
        assert_eq!(r.raw, "");
        assert!(!r.no_speech && !r.stt_redecoded);
        assert!(parse_reply(200, r#"{"ok":true,"final":null}"#).is_err());
        assert!(parse_reply(200, r#"{"ok":true,"final":"x","t_stt":-1}"#).is_err());
    }

    #[test]
    fn history_line() {
        let r = Reply {
            ok: true,
            raw: "r".into(),
            final_text: "f".into(),
            t_stt: 2.4004,
            ..Default::default()
        };
        let h = history_entry("ts", "dictate", 5.0, &r, 3.21159, true);
        assert_eq!(h["final"], "f");
        assert_eq!(h["t_stt"], 2.4);
        assert_eq!(h["t_total"], 3.212);
        assert_eq!(h["pasted"], true);
        assert_eq!(h["cleanup_error"], Value::Null);
    }

    /// A one-shot HTTP server that answers with `status`/`body` and hands back the request.
    fn serve_once(status: u16, body: &'static str) -> (String, std::thread::JoinHandle<String>) {
        use std::io::{BufRead, BufReader, Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", l.local_addr().unwrap());
        let h = std::thread::spawn(move || {
            let (s, _) = l.accept().unwrap();
            let mut r = BufReader::new(s);
            let mut head = String::new();
            let mut len = 0;
            loop {
                let mut line = String::new();
                r.read_line(&mut line).unwrap();
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap();
                }
                head.push_str(&line);
                if line == "\r\n" {
                    break;
                }
            }
            let mut b = vec![0; len];
            r.read_exact(&mut b).unwrap();
            let mut s = r.into_inner();
            write!(
                s,
                "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
            head + &String::from_utf8(b).unwrap()
        });
        (url, h)
    }

    #[test]
    fn dictate_over_http() {
        let (url, h) = serve_once(200, r#"{"ok":true,"raw":"a","final":"b"}"#);
        let c = Config { url, ..cfg() };
        let r = dictate(&c, &[9]).unwrap();
        assert_eq!(r.final_text, "b");
        let req = h.join().unwrap();
        assert!(req.starts_with("POST /v1/dictate "), "{req}");
        assert!(req.contains("authorization: Bearer t") || req.contains("Authorization: Bearer t"));
        assert!(req.contains(r#""wav_b64":"CQ==""#), "{req}");
    }

    #[test]
    fn dictate_server_error_and_down() {
        let (url, h) = serve_once(502, r#"{"ok":false,"error":"stt down"}"#);
        let c = Config { url, ..cfg() };
        assert!(dictate(&c, &[9]).unwrap_err().contains("server/pipeline"));
        h.join().unwrap();
        // Nothing listens on a port we just released.
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let c = Config {
            url: format!("http://127.0.0.1:{port}"),
            ..cfg()
        };
        assert!(dictate(&c, &[9]).is_err());
    }
}
