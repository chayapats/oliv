//! Model-free native fixtures for Swift's production IPC and HTTP/TLS tests.
use base64::Engine;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::Arc;
use std::time::Duration;

fn emit(value: Value) -> io::Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &value)?;
    out.write_all(b"\n")?;
    out.flush()
}
fn sidecar() -> io::Result<()> {
    for line in io::stdin().lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(req) = serde_json::from_str::<Value>(&line) else {
            emit(json!({"id":null,"ok":false,"error":"bad json"}))?;
            continue;
        };
        let id = &req["id"];
        let reply = match req["cmd"].as_str().unwrap_or("") {
            "shutdown" => break,
            "ping" => json!({"id":id,"ok":true,"pid":std::process::id()}),
            "warm" => {
                if req["background_cleanup"] == true {
                    json!({"id":id,"ok":true,"engine":req["engine"],"t_stt_load":2.0,"t_cleanup_load":0.0,"cleanup_warming":true})
                } else {
                    let (stt, llm) = if req.get("background_cleanup").is_some() {
                        (-1.0, -1.0)
                    } else {
                        (0.5, 0.25)
                    };
                    json!({"id":id,"ok":true,"engine":req["engine"],"t_stt_load":stt,"t_cleanup_load":llm})
                }
            }
            "dictate" => {
                let rf = if req["remove_fillers"] == true { 7 } else { 0 };
                let tf = if req["thai_format"] == true { 5 } else { 0 };
                let repl = req["replacements"].as_object().map_or(0, |o| o.len());
                let fmt = req["vocabulary"].as_array().map_or(0, |a| a.len()) * 10
                    + usize::from(req["format_commands"] == true);
                json!({"id":id,"ok":true,"engine":req["engine"],"raw":"hello world","final":"Hello world.",
                    "t_stt":0.012,"t_cleanup":0.003,"llm_ran":true,"gate_reason":"dict-hit","guardrail_flag":"ok",
                    "cleanup_error":null,"fillers_removed":rf,"replacements_fired":repl,"format_commands_fired":fmt,"thai_format_fired":tf})
            }
            "hang" => {
                std::thread::sleep(Duration::from_secs(30));
                continue;
            }
            "garbage" => {
                println!("this is not json at all");
                io::stdout().flush()?;
                continue;
            }
            "noise" => {
                emit(json!({"id":999999,"ok":true,"stray":true}))?;
                println!("garbage stray line");
                json!({"id":id,"ok":true,"matched":true})
            }
            "sttfail" => json!({"id":id,"ok":false,"error":"STT backend exploded"}),
            "prog" => {
                for pct in [10, 90] {
                    emit(json!({"id":id,"event":"progress","repo":"r","pct":pct}))?;
                }
                json!({"id":id,"ok":true,"done":true})
            }
            _ => json!({"id":id,"ok":false,"error":"unknown cmd"}),
        };
        emit(reply)?;
    }
    Ok(())
}

fn respond(stream: &mut impl Write, status: u16, body: &Value, extra: &str) -> io::Result<()> {
    let bytes = serde_json::to_vec(body)?;
    write!(
        stream,
        "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n",
        bytes.len()
    )?;
    stream.write_all(&bytes)?;
    stream.flush()
}
fn http(stream: impl Read + Write, counts: &mut BTreeMap<&str, usize>) -> io::Result<()> {
    let mut reader = BufReader::new(stream);
    let mut first = String::new();
    reader.read_line(&mut first)?;
    let words: Vec<_> = first.split_whitespace().collect();
    let path = words.get(1).copied().unwrap_or("");
    let mut headers = BTreeMap::new();
    let mut size = first.len();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        size += line.len();
        if size > 8192 {
            return Err(io::Error::other("oversized fixture headers"));
        }
        if line == "\r\n" || line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let length = headers
        .get("content-length")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);
    if length > 1024 * 1024 {
        return Err(io::Error::other("oversized fixture body"));
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes)?;
    let mut stream = reader.into_inner();
    match path {
        "/counts" => respond(&mut stream, 200, &json!(counts), ""),
        "/health" => {
            *counts.get_mut("health_keys").unwrap() +=
                usize::from(headers.contains_key("authorization"));
            respond(&mut stream, 200, &json!({"ok":true}), "")
        }
        "/stall/v1/dictate" => {
            std::thread::sleep(Duration::from_secs(20));
            Ok(())
        }
        "/target/v1/dictate" => {
            *counts.get_mut("targets").unwrap() += 1;
            respond(
                &mut stream,
                200,
                &json!({"ok":true,"final":"unexpected redirect"}),
                "",
            )
        }
        "/v1/dictate" => {
            let body: Value = serde_json::from_slice(&bytes)?;
            let wav = base64::engine::general_purpose::STANDARD
                .decode(body["wav_b64"].as_str().unwrap_or(""))
                .unwrap_or_default();
            let valid = headers
                .get("authorization")
                .is_some_and(|v| v == "Bearer dummy")
                && headers
                    .get("user-agent")
                    .is_some_and(|v| v.starts_with("oliv-macos/"))
                && headers
                    .get("content-type")
                    .is_some_and(|v| v == "application/json")
                && ["cleanup", "remove_fillers", "thai_format"]
                    .iter()
                    .all(|k| body[k] == false)
                && wav.len() >= 44
                && wav[..4] == *b"RIFF"
                && wav[20..24] == [1, 0, 1, 0]
                && wav[24..28] == 16000u32.to_le_bytes()
                && wav[34..36] == [16, 0];
            if valid {
                *counts.get_mut("valid_requests").unwrap() += 1;
            }
            respond(
                &mut stream,
                if valid { 200 } else { 400 },
                &json!({"ok":valid,"final":"ไทย English"}),
                "",
            )
        }
        _ if path.starts_with("/redirect/") => {
            *counts.get_mut("redirects").unwrap() += 1;
            let status = path
                .split('/')
                .nth(2)
                .and_then(|v| v.parse().ok())
                .unwrap_or(400);
            respond(
                &mut stream,
                status,
                &json!({}),
                "Location: /target/v1/dictate\r\n",
            )
        }
        _ => respond(&mut stream, 404, &json!({"ok":false}), ""),
    }
}
fn loopback(tls: bool) -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let config = if tls {
        let generated =
            rcgen::generate_simple_self_signed(vec!["localhost".into(), "127.0.0.1".into()])?;
        Some(Arc::new(
            rustls::ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(
                    vec![generated.cert.der().clone()],
                    rustls::pki_types::PrivatePkcs8KeyDer::from(
                        generated.signing_key.serialize_der(),
                    )
                    .into(),
                )?,
        ))
    } else {
        None
    };
    println!("{}", listener.local_addr()?.port());
    io::stdout().flush()?;
    let mut counts = BTreeMap::from([
        ("redirects", 0),
        ("targets", 0),
        ("valid_requests", 0),
        ("health_keys", 0),
    ]);
    for socket in listener.incoming() {
        let socket = socket?;
        socket.set_read_timeout(Some(Duration::from_secs(5)))?;
        socket.set_write_timeout(Some(Duration::from_secs(5)))?;
        if let Some(config) = &config {
            let connection = rustls::ServerConnection::new(config.clone())?;
            let _ = http(rustls::StreamOwned::new(connection, socket), &mut counts);
        } else {
            let _ = http(socket, &mut counts);
        }
    }
    Ok(())
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    match std::env::args().nth(1).as_deref() {
        Some("sidecar") => sidecar()?,
        Some("http") => loopback(false)?,
        Some("https") => loopback(true)?,
        _ => return Err("usage: oliv-test-worker sidecar|http|https".into()),
    }
    Ok(())
}
