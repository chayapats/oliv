//! LLM failure handling: the transcript is never lost, and a slow llama-server is
//! cut off by the timeout. Uses only loopback listeners, never the network.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::{Duration, Instant};

use oliv_pipeline::dictate::{Options, clean_text};
use oliv_pipeline::llm::{HttpLlm, Llm, LlmError, Prompt, Request};
use oliv_pipeline::pipeline::LLM_ERROR_FLAG;

struct Failing;

impl Llm for Failing {
    fn generate(&self, _: &Request) -> Result<String, LlmError> {
        Err(LlmError("llm: timeout".into()))
    }
}

/// dict-hit text, so the gate runs the LLM
const TEXT: &str = "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา";

#[test]
fn llm_error_keeps_deterministic_text() {
    let out = clean_text(TEXT, &Options::default(), &Failing);
    assert_eq!(out.final_text, "restart server แล้วเช็คล็อกใน Grafana");
    assert_eq!(out.cleanup_error.as_deref(), Some("llm: timeout"));
    assert_eq!(out.guardrail_flag, LLM_ERROR_FLAG);
    assert!(out.llm_ran);
    assert_eq!(out.dict_hits, 3);
    assert!(!out.no_speech);
}

/// Serve one canned HTTP response on a loopback port after `delay`.
fn serve_once(body: &'static str, delay: Duration) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        let (mut sock, _) = listener.accept().unwrap();
        let mut buf = [0u8; 65536];
        let _ = sock.read(&mut buf);
        std::thread::sleep(delay);
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let _ = sock.write_all(resp.as_bytes());
    });
    format!("http://{addr}")
}

#[test]
fn http_llm_reads_content() {
    let url = serve_once(
        r#"{"choices":[{"message":{"content":"restart server"}}]}"#,
        Duration::ZERO,
    );
    let llm = HttpLlm::new(&url, Duration::from_secs(5));
    let req = Request {
        prompt: Prompt::V2,
        text: TEXT,
        hints: &[],
    };
    assert_eq!(llm.generate(&req).unwrap(), "restart server");
}

#[test]
fn http_llm_times_out() {
    let url = serve_once(r#"{"choices":[]}"#, Duration::from_secs(3));
    let llm = HttpLlm::new(&url, Duration::from_millis(300));
    let req = Request {
        prompt: Prompt::V2,
        text: TEXT,
        hints: &[],
    };
    let t0 = Instant::now();
    assert!(llm.generate(&req).is_err());
    assert!(
        t0.elapsed() < Duration::from_secs(2),
        "took {:?}",
        t0.elapsed()
    );
}
