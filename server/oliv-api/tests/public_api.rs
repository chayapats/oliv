//! Real loopback HTTP with temporary keys and synthetic audio; never production.
use std::fs;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use oliv_pipeline::admission::Admission;
use oliv_pipeline::api::{App, MAX_BODY, bind, serve_with_audit};
use oliv_pipeline::auth::{Auth, CreateKey, create_key, initialize_key_store, revoke_key};
use oliv_pipeline::llm::{Llm, LlmError, Prompt, Request};
use oliv_pipeline::stt::{Stt, Transcript};
use serde_json::json;

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let mut id = [0; 8];
        getrandom::getrandom(&mut id).unwrap();
        let path = std::env::temp_dir().join(format!(
            "oliv-http-{}-{:x}",
            std::process::id(),
            u64::from_le_bytes(id)
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
struct FakeLlm;
impl Llm for FakeLlm {
    fn generate(&self, _: &Request) -> Result<String, LlmError> {
        panic!("cleanup disabled in synthetic tests")
    }
}
struct FakeStt {
    calls: Arc<AtomicUsize>,
    pause: Arc<(Mutex<bool>, Condvar)>,
}
impl Stt for FakeStt {
    fn transcribe(&self, _: &[u8], _: Option<&str>, _: Option<&str>) -> Result<Transcript, String> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let (lock, cv) = &*self.pause;
        let _ = cv
            .wait_timeout_while(lock.lock().unwrap(), Duration::from_secs(45), |p| *p)
            .unwrap();
        Ok(Transcript {
            text: "สวัสดีครับ".into(),
            avg_logprob: Some(-0.1),
        })
    }
}
struct Harness {
    dir: Temp,
    addr: String,
    calls: Arc<AtomicUsize>,
    pause: Arc<(Mutex<bool>, Condvar)>,
}
impl Harness {
    fn new() -> Self {
        Self::with_capacity(1)
    }
    fn with_capacity(capacity: usize) -> Self {
        let dir = Temp::new();
        initialize_key_store(&dir.0).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let pause = Arc::new((Mutex::new(false), Condvar::new()));
        let app = Arc::new(App {
            auth: Auth::key_file(dir.0.join("api-keys.json")).unwrap(),
            admission: Arc::new(Admission::default()),
            prompt: Prompt::V5,
            asr_profile: oliv_pipeline::dictate::AsrProfile::Turbo,
            llm_timeout_s: 5,
            stt: Box::new(FakeStt {
                calls: Arc::clone(&calls),
                pause: Arc::clone(&pause),
            }),
            llm: Box::new(FakeLlm),
            busy: Mutex::new(()),
            dictionaries: oliv_pipeline::dictionary_store::DictionaryStore::in_memory(),
            asr_gate: oliv_pipeline::stage_gate::StageGate::new(capacity),
        });
        let listener = bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let audit = Arc::new(oliv_pipeline::audit::Audit::open(&dir.0).unwrap());
        std::thread::spawn(move || serve_with_audit(app, listener, audit));
        Self {
            dir,
            addr,
            calls,
            pause,
        }
    }
    fn key(&self, name: &str, scopes: &[&str], rpm: u32, day: u32) -> (String, String) {
        let file = self.dir.0.join(format!("{name}.key"));
        let info = create_key(
            &self.dir.0,
            CreateKey {
                name: name.into(),
                scopes: scopes.iter().map(|s| s.to_string()).collect(),
                requests_per_minute: rpm,
                daily_requests: day,
                ..Default::default()
            },
            &file,
        )
        .unwrap();
        (info.id, fs::read_to_string(file).unwrap().trim().into())
    }
    fn post(&self, key: &str, path: &str, body: &str) -> String {
        post(&self.addr, key, path, body)
    }
}
impl Drop for Harness {
    fn drop(&mut self) {
        *self.pause.0.lock().unwrap() = false;
        self.pause.1.notify_all();
    }
}

fn socket(addr: &str) -> TcpStream {
    let s = TcpStream::connect(addr).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    s.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
    s
}
fn read(s: &mut TcpStream) -> String {
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    out
}
fn raw(addr: &str, request: &str) -> String {
    let mut s = socket(addr);
    s.write_all(request.as_bytes()).unwrap();
    read(&mut s)
}
fn post(addr: &str, key: &str, path: &str, body: &str) -> String {
    raw(
        addr,
        &format!(
            "POST {path} HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        ),
    )
}
fn begin_post(addr: &str, key: &str, body: &str) -> TcpStream {
    let mut s = socket(addr);
    write!(
        s,
        "POST /v1/dictate HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .unwrap();
    s
}
fn admitted_upload(addr: &str, key: &str, len: usize) -> TcpStream {
    assert!(len > 0, "100-continue requires a nonempty request body");
    let mut s = socket(addr);
    s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    write!(
        s,
        "POST /v1/dictate HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: {len}\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n"
    )
    .unwrap();
    // Hyper sends 100 only when dispatch starts polling the request body, AFTER
    // authentication and admission. This acknowledges the intended request's
    // permit without introducing a competing request for the same key.
    let start = Instant::now();
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        assert!(header.len() < 1024 && start.elapsed() < Duration::from_secs(3));
        let mut byte = [0];
        s.read_exact(&mut byte).expect("100-continue header");
        header.push(byte[0]);
    }
    assert_eq!(status(std::str::from_utf8(&header).unwrap()), 100);
    s.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    s
}

fn begin_chunked(addr: &str, key: &str) -> TcpStream {
    let mut s = socket(addr);
    write!(
        s,
        "POST /v1/dictate HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    )
    .unwrap();
    s
}
fn chunk(s: &mut TcpStream, bytes: &[u8]) {
    write!(s, "{:x}\r\n", bytes.len()).unwrap();
    s.write_all(bytes).unwrap();
    s.write_all(b"\r\n").unwrap();
}
fn wait_for_model(h: &Harness) {
    let start = Instant::now();
    while h.calls.load(Ordering::SeqCst) == 0 {
        assert!(
            start.elapsed() < Duration::from_secs(3),
            "model never started"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn wait_for_release(h: &Harness, key: &str) {
    // Only use after the original request is KNOWN to have been admitted and
    // disconnected. No intended request may be competing for admission here.
    // Bound attempts below the key's quota: polling can otherwise create 429s.
    for attempt in 0..30 {
        let got = status(&h.post(key, "/v1/dictate", "{}"));
        if got == 400 {
            return;
        }
        assert_eq!(got, 429, "unexpected status while waiting for release");
        assert!(
            attempt < 29,
            "disconnected request did not release its permit"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}
fn status(r: &str) -> u16 {
    r.split_whitespace().nth(1).unwrap().parse().unwrap()
}
fn audio_wav() -> Vec<u8> {
    let mut w = b"RIFF".to_vec();
    w.extend_from_slice(&38u32.to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    for n in [1u16, 1] {
        w.extend_from_slice(&n.to_le_bytes());
    }
    for n in [16000u32, 32000] {
        w.extend_from_slice(&n.to_le_bytes());
    }
    for n in [2u16, 16] {
        w.extend_from_slice(&n.to_le_bytes());
    }
    w.extend_from_slice(b"data");
    w.extend_from_slice(&2u32.to_le_bytes());
    w.extend_from_slice(&0i16.to_le_bytes());
    w
}
fn wav_body(wav: &[u8]) -> String {
    json!({"wav_b64":base64::engine::general_purpose::STANDARD.encode(wav),"cleanup":false})
        .to_string()
}
fn audio_body() -> String {
    wav_body(&audio_wav())
}

#[test]
fn chunked_uploads_accept_exact_limit_and_reject_the_next_byte() {
    let h = Harness::new();
    let (_, key) = h.key("chunks", &["dictate"], 100, 500);
    let body = audio_body();
    let mut s = begin_chunked(&h.addr, &key);
    // Split JSON tokens across chunks: HTTP framing must not leak into JSON.
    for bytes in body.as_bytes().chunks(7) {
        chunk(&mut s, bytes);
    }
    chunk(&mut s, &vec![b' '; MAX_BODY - body.len()]);
    s.write_all(b"0\r\n\r\n").unwrap();
    assert_eq!(status(&read(&mut s)), 200);
    assert_eq!(h.calls.load(Ordering::SeqCst), 1);

    let mut s = begin_chunked(&h.addr, &key);
    chunk(&mut s, &vec![b' '; MAX_BODY]);
    // Send only one byte past the accepted boundary, then stop writing. The
    // server may close without draining the chunked request's final delimiter.
    s.write_all(b"1\r\nx\r\n0\r\n\r\n").unwrap();
    let mut reply = String::new();
    let result = s.read_to_string(&mut reply);
    if let Err(e) = result {
        assert_eq!(e.kind(), std::io::ErrorKind::ConnectionReset);
    }
    assert_eq!(status(&reply), 413, "must receive a real HTTP 413 response");
    assert_eq!(h.calls.load(Ordering::SeqCst), 1);
    assert_eq!(status(&h.post(&key, "/v1/dictate", &body)), 200);
}

#[test]
fn malformed_and_truncated_chunked_uploads_release_admission() {
    let h = Harness::new();
    let (_, key) = h.key("chunks", &["dictate"], 100, 500);
    for bytes in [b"not-hex\r\n".as_slice(), b"10\r\n{"] {
        let mut s = begin_chunked(&h.addr, &key);
        s.write_all(bytes).unwrap();
        s.shutdown(Shutdown::Write).unwrap();
        assert_eq!(status(&read(&mut s)), 400);
        // A terminal reply is emitted after dispatch has dropped its permit.
        assert_eq!(status(&h.post(&key, "/v1/dictate", "{}")), 400);
    }
    assert_eq!(h.calls.load(Ordering::SeqCst), 0);
    assert_eq!(status(&h.post(&key, "/v1/dictate", &audio_body())), 200);
}

#[test]
fn disconnected_inference_keeps_its_key_and_global_slot_until_completion() {
    let h = Harness::new();
    *h.pause.0.lock().unwrap() = true;
    let keys: Vec<_> = (0..oliv_pipeline::admission::MAX_ADMITTED + 1)
        .map(|i| h.key(&format!("disconnect{i}"), &["dictate"], 100, 500).1)
        .collect();
    let s = begin_post(&h.addr, &keys[0], &audio_body());
    wait_for_model(&h);
    s.shutdown(Shutdown::Both).unwrap();
    drop(s);
    assert_eq!(status(&h.post(&keys[0], "/v1/dictate", "{}")), 429);

    let mut uploads = Vec::new();
    for key in &keys[1..oliv_pipeline::admission::MAX_ADMITTED] {
        uploads.push(admitted_upload(&h.addr, key, 2));
    }
    let reply = h.post(
        &keys[oliv_pipeline::admission::MAX_ADMITTED],
        "/v1/dictate",
        &audio_body(),
    );
    assert_eq!(status(&reply), 503);
    assert!(reply.contains("server is busy; retry later"));
    assert_eq!(h.calls.load(Ordering::SeqCst), 1);
    for mut upload in uploads {
        upload.write_all(b"{}").unwrap();
        assert_eq!(status(&read(&mut upload)), 400);
    }
    *h.pause.0.lock().unwrap() = false;
    h.pause.1.notify_all();
    wait_for_release(&h, &keys[0]);
    assert_eq!(status(&h.post(&keys[0], "/v1/dictate", &audio_body())), 200);
    assert_eq!(h.calls.load(Ordering::SeqCst), 2);
}

#[test]
fn queue_wait_deadline_releases_waiter_without_starting_another_model() {
    let h = Harness::new();
    *h.pause.0.lock().unwrap() = true;
    let (_, active) = h.key("active", &["dictate"], 100, 500);
    let (_, waiting) = h.key("waiting", &["dictate"], 100, 500);
    let mut s = begin_post(&h.addr, &active, &audio_body());
    wait_for_model(&h);
    let start = Instant::now();
    let reply = h.post(&waiting, "/v1/dictate", &audio_body());
    assert_eq!(status(&reply), 503);
    assert!(reply.contains("inference queue wait exceeded"));
    assert!((Duration::from_secs(19)..Duration::from_secs(23)).contains(&start.elapsed()));
    assert_eq!(h.calls.load(Ordering::SeqCst), 1);
    // Invalid JSON options can reach validation immediately once the timed-out
    // waiter's permit is dropped, even while the first model remains paused.
    assert_eq!(status(&h.post(&waiting, "/v1/dictate", "{}")), 400);
    *h.pause.0.lock().unwrap() = false;
    h.pause.1.notify_all();
    assert_eq!(status(&read(&mut s)), 200);
    assert_eq!(status(&h.post(&waiting, "/v1/dictate", &audio_body())), 200);
    assert_eq!(h.calls.load(Ordering::SeqCst), 2);
}

#[test]
fn malformed_wav_metadata_is_rejected_before_model_decode() {
    let h = Harness::new();
    let (_, key) = h.key("metadata", &["dictate"], 100, 500);
    for (tag, payload, declared) in [
        (b"LIST", b"".as_slice(), 0u32),
        (b"LIST", b"INF\0".as_slice(), 3), // list type shorter than four bytes
        (b"LIST", b"wavl".as_slice(), 4u32),
        (b"LIST", b"INFO".as_slice(), 12),
        (b"JUNK", b"a".as_slice(), 1), // odd chunk with missing padding
    ] {
        let mut wav = audio_wav();
        wav.extend_from_slice(tag);
        wav.extend_from_slice(&declared.to_le_bytes());
        wav.extend_from_slice(payload);
        let riff_len = (wav.len() - 8) as u32;
        wav[4..8].copy_from_slice(&riff_len.to_le_bytes());
        assert_eq!(status(&h.post(&key, "/v1/dictate", &wav_body(&wav))), 400);
    }
    assert_eq!(h.calls.load(Ordering::SeqCst), 0);
    assert_eq!(status(&h.post(&key, "/v1/dictate", &audio_body())), 200);
}

#[test]
fn auth_precedes_body_and_bad_credentials_never_reach_models() {
    let h = Harness::new();
    let t = Instant::now();
    let r = raw(
        &h.addr,
        "POST /v1/dictate HTTP/1.1\r\nHost: x\r\nContent-Length: 9000000\r\n\r\n",
    );
    assert_eq!(status(&r), 401);
    assert!(t.elapsed() < Duration::from_secs(2));
    let (_, key) = h.key("a", &["dictate"], 100, 500);
    let r = raw(
        &h.addr,
        &format!(
            "POST /v1/dictate HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {key}\r\nAuthorization: Bearer {key}\r\nContent-Length: 9000000\r\n\r\n"
        ),
    );
    assert_eq!(status(&r), 401);
    assert_eq!(
        status(&h.post("not-a-key", "/v1/dictate", &audio_body())),
        401
    );
    assert_eq!(h.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn forwarded_protocol_rejections_precede_body_quota_and_models() {
    let h = Harness::new();
    let (_, key) = h.key("protocol", &["dictate"], 1, 1);
    for headers in [
        b"X-Forwarded-Proto: http\r\n".as_slice(),
        b"X-Forwarded-Proto: HTTPS\r\n",
        b"X-Forwarded-Proto: https,http\r\n",
        b"X-Forwarded-Proto: \r\n",
        b"X-Forwarded-Proto: https\r\nX-Forwarded-Proto: https\r\n",
        b"X-Forwarded-Proto: \xff\r\n",
    ] {
        let mut socket = socket(&h.addr);
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        write!(
            socket,
            "POST /v1/dictate HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n"
        )
        .unwrap();
        socket.write_all(headers).unwrap();
        socket.write_all(b"\r\n").unwrap(); // No body: rejection must not await upload.
        let reply = read(&mut socket);
        assert_eq!(status(&reply), 403);
        assert!(reply.contains("HTTPS is required"));
        assert_eq!(h.calls.load(Ordering::SeqCst), 0);
    }
    let body = audio_body();
    let reply = raw(
        &h.addr,
        &format!(
            "POST /v1/dictate HTTP/1.1\r\nHost: test\r\nX-Forwarded-Proto: https\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        ),
    );
    // Exactly one daily/minute request is available: none of the rejects spent it.
    assert_eq!(status(&reply), 200);
    assert_eq!(h.calls.load(Ordering::SeqCst), 1);
    assert_eq!(status(&h.post(&key, "/v1/dictate", &body)), 429);
}

#[test]
fn forwarded_protocol_never_grants_auth_and_missing_header_allows_private_health() {
    let h = Harness::new();
    let reply = raw(
        &h.addr,
        "GET /health HTTP/1.1\r\nHost: test\r\nX-Forwarded-Proto: http\r\n\r\n",
    );
    assert_eq!(status(&reply), 403);
    for header in ["", "X-Forwarded-Proto: https\r\n"] {
        let reply = raw(
            &h.addr,
            &format!("GET /health HTTP/1.1\r\nHost: test\r\n{header}\r\n"),
        );
        assert_eq!(status(&reply), 200);
        assert!(reply.ends_with(r#"{"ok":true}"#));
    }
    for (proto, expected) in [("http", 403), ("https", 401)] {
        let reply = raw(
            &h.addr,
            &format!(
                "POST /v1/dictate HTTP/1.1\r\nHost: test\r\nX-Forwarded-Proto: {proto}\r\nContent-Length: 100\r\n\r\n"
            ),
        );
        assert_eq!(status(&reply), expected);
    }
    assert_eq!(h.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn scopes_revocation_and_corrupt_store_apply_without_restart() {
    let h = Harness::new();
    let (id, key) = h.key("a", &["dictate"], 100, 500);
    let r = h.post(&key, "/v1/dictate", &audio_body());
    assert_eq!(status(&r), 200);
    assert!(r.to_ascii_lowercase().contains("cache-control: no-store"));
    assert_eq!(status(&h.post(&key, "/v1/clean", r#"{"text":"x"}"#)), 403);
    revoke_key(&h.dir.0, &id).unwrap();
    assert_eq!(status(&h.post(&key, "/v1/dictate", &audio_body())), 401);
    fs::write(h.dir.0.join("api-keys.json"), b"broken").unwrap();
    assert_eq!(status(&h.post(&key, "/v1/dictate", &audio_body())), 503);
    assert_eq!(h.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn per_key_daily_limit_and_minimal_health() {
    let h = Harness::new();
    let (_, key) = h.key("a", &["dictate"], 100, 1);
    assert_eq!(status(&h.post(&key, "/v1/dictate", &audio_body())), 200);
    let r = h.post(&key, "/v1/dictate", &audio_body());
    assert_eq!(status(&r), 429);
    assert!(r.to_ascii_lowercase().contains("retry-after:"));
    let r = raw(&h.addr, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!(status(&r), 200);
    assert!(r.ends_with(r#"{"ok":true}"#));
    assert_eq!(h.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn body_size_encoding_audio_and_text_limits() {
    let h = Harness::new();
    let (_, key) = h.key("a", &["dictate", "clean"], 100, 500);
    let r = raw(
        &h.addr,
        &format!(
            "POST /v1/dictate HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            MAX_BODY + 1
        ),
    );
    assert_eq!(status(&r), 413);
    assert_eq!(
        status(&h.post(&key, "/v1/dictate", r#"{"wav_b64":"UklGRi1mYWtlLXdhdg=="}"#)),
        400
    );
    assert_eq!(
        status(&h.post(
            &key,
            "/v1/clean",
            &json!({"text":"x".repeat(8193)}).to_string()
        )),
        400
    );
    assert_eq!(status(&h.post(&key, "/v1/dictate?token=secret", "{}")), 400);
    let r = raw(
        &h.addr,
        &format!(
            "POST /v1/dictate HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n"
        ),
    );
    assert_eq!(status(&r), 415);
    assert_eq!(h.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn stalled_headers_are_closed_and_other_connections_stay_healthy() {
    let h = Harness::new();
    let mut s = socket(&h.addr);
    s.write_all(b"GET /health HTTP/1.1\r\nHost:").unwrap();
    let r = raw(&h.addr, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!(status(&r), 200);
    let t = Instant::now();
    let mut out = Vec::new();
    let _ = s.read_to_end(&mut out);
    assert!(t.elapsed() < Duration::from_secs(8));
}

#[test]
fn authenticated_stalled_upload_times_out_and_releases_its_slot() {
    let h = Harness::new();
    let (_, key) = h.key("a", &["dictate"], 100, 500);
    let t = Instant::now();
    let r = raw(
        &h.addr,
        &format!(
            "POST /v1/dictate HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{{"
        ),
    );
    assert_eq!(status(&r), 408);
    assert!(t.elapsed() < Duration::from_secs(18));
    assert_eq!(status(&h.post(&key, "/v1/dictate", &audio_body())), 200);
}

#[test]
fn one_job_per_key_and_bounded_global_queue() {
    let h = Harness::new();
    *h.pause.0.lock().unwrap() = true;
    let keys: Vec<_> = (0..oliv_pipeline::admission::MAX_ADMITTED + 1)
        .map(|i| h.key(&format!("k{i}"), &["dictate"], 100, 500).1)
        .collect();
    let body = audio_body();
    let mut a = begin_post(&h.addr, &keys[0], &body);
    wait_for_model(&h);
    assert_eq!(status(&h.post(&keys[0], "/v1/dictate", "{}")), 429);
    // Keep both later jobs in the upload stage until their admission has been
    // acknowledged. No polling request may steal either intended job's key.
    let uploads: Vec<_> = keys[1..oliv_pipeline::admission::MAX_ADMITTED]
        .iter()
        .map(|key| admitted_upload(&h.addr, key, body.len()))
        .collect();
    for key in &keys[1..oliv_pipeline::admission::MAX_ADMITTED] {
        assert_eq!(status(&h.post(key, "/v1/dictate", "{}")), 429);
    }
    let start = Instant::now();
    let reply = h.post(
        &keys[oliv_pipeline::admission::MAX_ADMITTED],
        "/v1/dictate",
        &body,
    );
    assert_eq!(status(&reply), 503);
    assert!(reply.contains("server is busy; retry later"));
    assert!(start.elapsed() < Duration::from_secs(3));
    assert_eq!(h.calls.load(Ordering::SeqCst), 1);
    *h.pause.0.lock().unwrap() = false;
    h.pause.1.notify_all();
    assert_eq!(status(&read(&mut a)), 200);
    // Completion of the first job is explicit. Deliver subsequent bodies one
    // at a time so scheduler delays cannot turn this admission test into the
    // independent inference-queue-timeout test above.
    for mut upload in uploads {
        upload.write_all(body.as_bytes()).unwrap();
        assert_eq!(status(&read(&mut upload)), 200);
    }
    assert_eq!(
        h.calls.load(Ordering::SeqCst),
        oliv_pipeline::admission::MAX_ADMITTED
    );
}

#[test]
fn replacement_expansion_does_not_exceed_client_response_budget() {
    let h = Harness::new();
    let (_, key) = h.key("expansion", &["clean"], 100, 500);
    let body = json!({
        "text": format!("q{}", "a".repeat(8191)),
        "cleanup": false, "remove_fillers": false, "thai_format": false,
        "replacements": {"a": "b".repeat(256)}
    })
    .to_string();
    let reply = h.post(&key, "/v1/clean", &body);
    assert_eq!(status(&reply), 502);
    assert!(reply.len() < 1024);
    assert!(reply.contains("response size limit"));
    assert_eq!(h.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn audit_attributes_only_verified_keys_and_records_quota_rejections() {
    let h = Harness::new();
    let (id, token) = h.key("limited", &["clean"], 2, 2);
    assert!(
        h.post(
            &token,
            "/v1/clean",
            r#"{"text":"synthetic secret transcript","cleanup":false}"#
        )
        .starts_with("HTTP/1.1 200")
    );
    assert!(
        h.post(&token, "/v1/clean", "not-json")
            .starts_with("HTTP/1.1 400")
    );
    assert!(
        h.post(&token, "/v1/clean", "{}")
            .starts_with("HTTP/1.1 429")
    );
    assert!(
        h.post(&token, "/v1/dictate", "{}")
            .starts_with("HTTP/1.1 403")
    );
    let fake = format!("oliv_{id}_{}", "0".repeat(64));
    assert!(h.post(&fake, "/v1/clean", "{}").starts_with("HTTP/1.1 401"));
    assert!(raw(&h.addr, "GET /health HTTP/1.1\r\nHost: test\r\n\r\n").starts_with("HTTP/1.1 200"));
    let db = rusqlite::Connection::open(h.dir.0.join("usage/requests.sqlite3")).unwrap();
    let rows: Vec<(Option<String>, i64, bool)> = db
        .prepare("SELECT key_id,status,quota_charged FROM requests ORDER BY id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(
        rows,
        vec![
            (Some(id.clone()), 200, true),
            (Some(id.clone()), 400, true),
            (Some(id.clone()), 429, false),
            (Some(id), 403, false),
            (None, 401, false)
        ]
    );
    let bytes = fs::read(h.dir.0.join("usage/requests.sqlite3-wal")).unwrap();
    assert!(!bytes.windows(9).any(|b| b == b"synthetic"));
    assert!(!bytes.windows(token.len()).any(|b| b == token.as_bytes()));
}

#[test]
fn two_asr_jobs_overlap_while_clean_does_not_wait_for_asr() {
    let h = Harness::with_capacity(2);
    *h.pause.0.lock().unwrap() = true;
    let keys: Vec<_> = (0..4)
        .map(|id| {
            h.key(&format!("parallel-{id}"), &["dictate", "clean"], 100, 500)
                .1
        })
        .collect();
    let body = audio_body();
    let mut first = begin_post(&h.addr, &keys[0], &body);
    let mut second = begin_post(&h.addr, &keys[1], &body);
    let deadline = Instant::now() + Duration::from_secs(3);
    while h.calls.load(Ordering::SeqCst) != 2 {
        assert!(Instant::now() < deadline, "second ASR never started");
        std::thread::sleep(Duration::from_millis(5));
    }
    let mut third = begin_post(&h.addr, &keys[2], &body);
    let start = Instant::now();
    let reply = h.post(
        &keys[3],
        "/v1/clean",
        r#"{"text":"สวัสดีครับ","cleanup":false}"#,
    );
    assert_eq!(status(&reply), 200);
    assert!(start.elapsed() < Duration::from_secs(2));
    assert_eq!(
        h.calls.load(Ordering::SeqCst),
        2,
        "third job exceeded ASR capacity"
    );
    *h.pause.0.lock().unwrap() = false;
    h.pause.1.notify_all();
    for stream in [&mut first, &mut second, &mut third] {
        assert_eq!(status(&read(stream)), 200);
    }
    assert_eq!(h.calls.load(Ordering::SeqCst), 3);
}
