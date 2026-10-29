//! Real backend HTTP adapters against disposable loopback servers only.
use oliv_pipeline::llm::{HttpLlm, Llm, Prompt, Request};
use oliv_pipeline::stt::{HttpStt, Stt};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(2);
const AUDIO: &[u8] = b"synthetic-audio-no-microphone";

struct Seen {
    first_line: String,
    headers: String,
    body: Vec<u8>,
}

struct Mock {
    url: String,
    request: JoinHandle<Seen>,
}

impl Mock {
    fn reply(status: u16, body: Value, extra_header: &str, chunked: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let body = serde_json::to_vec(&body).unwrap();
        let framing = if chunked {
            "Transfer-Encoding: chunked\r\n".to_string()
        } else {
            format!("Content-Length: {}\r\n", body.len())
        };
        let headers = format!(
            "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nConnection: close\r\n{framing}{extra_header}\r\n"
        );
        let request = thread::spawn(move || {
            let deadline = Instant::now() + TIMEOUT;
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(e)
                        if e.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(e) => panic!("mock did not receive a request: {e}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream.set_read_timeout(Some(TIMEOUT)).unwrap();
            stream.set_write_timeout(Some(TIMEOUT)).unwrap();
            let seen = read_request(&mut stream);
            // Oversized responses may be refused as soon as their headers are
            // received. A reset while sending the rejected body is expected.
            if stream.write_all(headers.as_bytes()).is_ok() {
                if chunked {
                    for part in body.chunks(4096) {
                        if write!(stream, "{:x}\r\n", part.len()).is_err()
                            || stream.write_all(part).is_err()
                            || stream.write_all(b"\r\n").is_err()
                        {
                            return seen;
                        }
                    }
                    let _ = stream.write_all(b"0\r\n\r\n");
                } else {
                    let _ = stream.write_all(&body);
                }
            }
            seen
        });
        Self { url, request }
    }

    fn seen(self) -> Seen {
        self.request.join().unwrap()
    }
}

fn read_request(stream: &mut TcpStream) -> Seen {
    let mut reader = BufReader::new(stream);
    let mut first_line = String::new();
    reader.read_line(&mut first_line).unwrap();
    let mut headers = String::new();
    let mut length = 0;
    let mut chunked = false;
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0);
        if line == "\r\n" {
            break;
        }
        let lower = line.to_ascii_lowercase();
        if let Some(value) = lower.strip_prefix("content-length:") {
            length = value.trim().parse::<usize>().unwrap();
        }
        chunked |= lower == "transfer-encoding: chunked\r\n";
        headers.push_str(&lower);
        assert!(headers.len() <= 16 * 1024);
    }
    let mut body = Vec::new();
    if chunked {
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let length = usize::from_str_radix(line.trim(), 16).unwrap();
            assert!(body.len() + length <= 64 * 1024);
            let start = body.len();
            body.resize(start + length, 0);
            reader.read_exact(&mut body[start..]).unwrap();
            let mut crlf = [0; 2];
            reader.read_exact(&mut crlf).unwrap();
            assert_eq!(&crlf, b"\r\n");
            if length == 0 {
                break;
            }
        }
    } else {
        assert!(length <= 64 * 1024);
        body.resize(length, 0);
        reader.read_exact(&mut body).unwrap();
    }
    Seen {
        first_line,
        headers,
        body,
    }
}

fn llm_body(content: &str) -> Value {
    json!({"choices": [{"message": {"content": content}}]})
}

fn generate(base: &str) -> Result<String, oliv_pipeline::llm::LlmError> {
    HttpLlm::new(base, TIMEOUT).generate(&Request {
        prompt: Prompt::V2,
        text: "synthetic input",
        hints: &[],
    })
}

fn transcribe(base: &str) -> Result<oliv_pipeline::stt::Transcript, String> {
    HttpStt::new(base, TIMEOUT).transcribe(AUDIO, Some("test prompt"), Some("en"))
}

#[test]
fn normal_backend_responses_preserve_requests_and_outputs() {
    let stt = Mock::reply(
        200,
        json!({"ok": true, "text": "ทดสอบ hello", "avg_logprob": -0.2}),
        "",
        false,
    );
    let text = transcribe(&stt.url).unwrap();
    assert_eq!(text.text, "ทดสอบ hello");
    assert_eq!(text.avg_logprob, Some(-0.2));
    let seen = stt.seen();
    assert_eq!(seen.first_line, "POST /transcribe HTTP/1.1\r\n");
    assert_eq!(seen.body, AUDIO);
    assert!(seen.headers.contains("content-type: audio/wav\r\n"));
    assert!(seen.headers.contains("x-language: en\r\n"));
    assert!(seen.headers.contains("x-initial-prompt: test%20prompt\r\n"));

    let llm = Mock::reply(200, llm_body("ผลลัพธ์ synthetic"), "", true);
    assert_eq!(generate(&llm.url).unwrap(), "ผลลัพธ์ synthetic");
    let seen = llm.seen();
    assert_eq!(seen.first_line, "POST /v1/chat/completions HTTP/1.1\r\n");
    let body: Value = serde_json::from_slice(&seen.body).unwrap();
    assert_eq!(body["max_tokens"], 200);
    assert!(
        body["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains("synthetic input")
    );
}

#[test]
fn redirects_never_forward_audio_or_prompt_and_are_not_successes() {
    let target = TcpListener::bind("127.0.0.1:0").unwrap();
    target.set_nonblocking(true).unwrap();
    let location = format!(
        "Location: http://{}/must-not-receive-data\r\n",
        target.local_addr().unwrap()
    );
    for status in [307, 308] {
        let stt = Mock::reply(
            status,
            json!({"ok": true, "text": "redirect body"}),
            &location,
            false,
        );
        let result = transcribe(&stt.url);
        let seen = stt.seen();
        assert_eq!(seen.body, AUDIO);
        assert!(
            matches!(target.accept(), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock),
            "audio reached redirect target"
        );
        assert!(
            result.is_err(),
            "STT accepted a redirect response as success"
        );

        let llm = Mock::reply(status, llm_body("redirect body"), &location, false);
        let result = generate(&llm.url);
        llm.seen();
        assert!(
            matches!(target.accept(), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock),
            "prompt reached redirect target"
        );
        assert!(
            result.is_err(),
            "LLM accepted a redirect response as success"
        );
    }
}

#[test]
fn response_byte_limit_applies_to_declared_and_chunked_json() {
    for chunked in [false, true] {
        let stt = Mock::reply(
            200,
            json!({"ok": true, "text": "short", "padding": "x".repeat(256 * 1024)}),
            "",
            chunked,
        );
        assert!(transcribe(&stt.url).is_err());
        stt.seen();
        let mut body = llm_body("short");
        body["padding"] = "x".repeat(256 * 1024).into();
        let llm = Mock::reply(200, body, "", chunked);
        assert!(generate(&llm.url).is_err());
        llm.seen();
    }
}

#[test]
fn content_limit_is_16_kib_of_utf8_bytes() {
    for (text, accepted) in [
        ("x".repeat(16 * 1024), true),
        ("x".repeat(16 * 1024 + 1), false),
        ("ก".repeat(6000), false),
    ] {
        let stt = Mock::reply(200, json!({"ok": true, "text": text}), "", false);
        assert_eq!(transcribe(&stt.url).is_ok(), accepted);
        stt.seen();
        let llm = Mock::reply(200, llm_body(&text), "", false);
        assert_eq!(generate(&llm.url).is_ok(), accepted);
        llm.seen();
    }
}
