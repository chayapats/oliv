//! Exercise the shipped CLI as child processes with isolated user data and a
//! loopback HTTP server. Audio is generated silence, never a user's recording.
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{Value, json};

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// The lower-cased `User-Agent` header the client must send on this OS.
fn user_agent() -> String {
    let os = if cfg!(windows) { "windows" } else { "linux" };
    format!("user-agent: oliv-{os}/{}", env!("CARGO_PKG_VERSION"))
}

struct Sandbox(PathBuf);

impl Sandbox {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "oliv CLI ไทย ' {}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        for dir in ["config/oliv", "state/oliv/pending", "run"] {
            fs::create_dir_all(path.join(dir)).unwrap();
        }
        // Stub desktop commands so automated tests cannot alter the real clipboard.
        #[cfg(unix)]
        Self::stub_desktop_commands(&path);
        Self(path)
    }

    #[cfg(unix)]
    fn stub_desktop_commands(path: &std::path::Path) {
        fs::create_dir_all(path.join("bin")).unwrap();
        use std::os::unix::fs::PermissionsExt;
        for (name, script) in [
            (
                "wl-copy",
                "#!/bin/sh\ncat > \"$OLIV_TEST_ROOT/clipboard\"\necho copy >> \"$OLIV_TEST_ROOT/calls\"\n",
            ),
            (
                "hyprctl",
                "#!/bin/sh\necho paste >> \"$OLIV_TEST_ROOT/calls\"\nexit 1\n",
            ),
        ] {
            let file = path.join("bin").join(name);
            fs::write(&file, script).unwrap();
            fs::set_permissions(file, fs::Permissions::from_mode(0o700)).unwrap();
        }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_oliv"));
        #[cfg(unix)]
        cmd.env("OLIV_TEST_ROOT", &self.0)
            .env(
                "PATH",
                format!("{}:/usr/bin:/bin", self.0.join("bin").display()),
            )
            .env_remove("WAYLAND_DISPLAY")
            .env_remove("DISPLAY");
        cmd.args(args)
            .env("APPDATA", self.0.join("config"))
            .env("LOCALAPPDATA", self.0.join("state"))
            .env("XDG_CONFIG_HOME", self.0.join("config"))
            .env("XDG_STATE_HOME", self.0.join("state"))
            .env("XDG_RUNTIME_DIR", self.0.join("run"))
            .env("NO_PROXY", "127.0.0.1,localhost")
            .env("no_proxy", "127.0.0.1,localhost")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        cmd
    }

    fn run(&self, args: &[&str]) -> Output {
        finish(self.command(args).spawn().unwrap())
    }

    fn configure(&self, url: &str) {
        self.configure_timeout(url, 120);
    }

    fn configure_timeout(&self, url: &str, seconds: u64) {
        let path = self.0.join("config/oliv/config.toml");
        fs::write(
            &path,
            format!(
                "[server]\nurl = \"{url}/\"\ntoken = \"ci-synthetic-token\"\ntimeout_seconds = {seconds}\n\
                 [dictate]\ncleanup = false\nremove_fillers = true\nthai_format = false\n\
                 vocabulary = [\"Grafana\", \"ทดสอบ\"]\n\
                 [replacements]\n\"ซี\" = \"C\"\n\"เอ\" = \"A\"\n"
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
    }

    fn pending(&self, name: &str) -> PathBuf {
        let path = self.0.join("state/oliv/pending").join(name);
        fs::write(&path, silence()).unwrap();
        path
    }

    fn history(&self) -> Vec<Value> {
        let out = self.run(&["history", "2000", "--json"]);
        assert_success(&out);
        String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn finish(mut child: Child) -> Output {
    // Drain both pipes while waiting: a long history must not fill stdout and
    // deadlock the child before its exit can be observed.
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let stdout = thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).unwrap();
        bytes
    });
    let stderr = thread::spawn(move || {
        let mut bytes = Vec::new();
        stderr.read_to_end(&mut bytes).unwrap();
        bytes
    });
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            timed_out = true;
            break child.wait().unwrap();
        }
        thread::sleep(Duration::from_millis(10));
    };
    let output = Output {
        status,
        stdout: stdout.join().unwrap(),
        stderr: stderr.join().unwrap(),
    };
    assert!(
        !timed_out,
        "CLI timed out: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn assert_success(out: &Output) {
    assert!(
        out.status.success(),
        "CLI failed: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

fn silence() -> Vec<u8> {
    let mut wav = b"RIFF".to_vec();
    wav.extend(32036u32.to_le_bytes());
    wav.extend(b"WAVEfmt ");
    wav.extend(16u32.to_le_bytes());
    wav.extend(1u16.to_le_bytes());
    wav.extend(1u16.to_le_bytes());
    wav.extend(16000u32.to_le_bytes());
    wav.extend(32000u32.to_le_bytes());
    wav.extend(2u16.to_le_bytes());
    wav.extend(16u16.to_le_bytes());
    wav.extend(b"data");
    wav.extend(32000u32.to_le_bytes());
    wav.resize(32044, 0);
    wav
}

struct Mock {
    url: String,
    requests: Arc<Mutex<Vec<(String, Value)>>>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl Mock {
    fn new(replies: Vec<(u16, String)>, delay: Duration) -> Self {
        Self::with_headers(replies, delay, "")
    }

    fn with_headers(replies: Vec<(u16, String)>, delay: Duration, headers: &str) -> Self {
        let extra_headers = headers.to_string();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&requests);
        let stop = Arc::new(AtomicBool::new(false));
        let done = Arc::clone(&stop);
        let worker = thread::spawn(move || {
            while !done.load(Ordering::Acquire) {
                let (stream, _) = match listener.accept() {
                    Ok(pair) => pair,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    Err(e) => panic!("mock accept: {e}"),
                };
                // Winsock inherits the non-blocking listener mode; Linux does
                // not. Read each accepted request with explicit blocking I/O
                // and deadlines on both platforms, including failure cases.
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                stream
                    .set_write_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut reader = BufReader::new(stream);
                let mut headers = String::new();
                let mut len = 0usize;
                loop {
                    let mut line = String::new();
                    assert_ne!(reader.read_line(&mut line).unwrap(), 0);
                    if line == "\r\n" {
                        break;
                    }
                    if let Some(value) = line.to_lowercase().strip_prefix("content-length:") {
                        len = value.trim().parse().unwrap();
                    }
                    headers.push_str(&line);
                    assert!(headers.len() < 8192);
                }
                assert!(len <= 1024 * 1024);
                let mut body = vec![0; len];
                reader.read_exact(&mut body).unwrap();
                let n = {
                    let mut requests = captured.lock().unwrap();
                    let n = requests.len();
                    requests.push((
                        headers,
                        if body.is_empty() {
                            Value::Null
                        } else {
                            serde_json::from_slice(&body).unwrap()
                        },
                    ));
                    n
                };
                thread::sleep(delay);
                let fallback = (
                    500,
                    "{\"ok\":false,\"error\":\"unexpected duplicate request\"}".into(),
                );
                let (status, body) = replies.get(n).unwrap_or(&fallback);
                // Oversized-body tests deliberately close the connection early.
                let _ = write!(
                    reader.into_inner(),
                    "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{extra_headers}\r\n{body}",
                    body.len()
                );
            }
        });
        Self {
            url,
            requests,
            stop,
            worker: Some(worker),
        }
    }

    fn success(replies: &[Value]) -> Self {
        Self::new(
            replies.iter().map(|r| (200, r.to_string())).collect(),
            Duration::ZERO,
        )
    }
}

impl Drop for Mock {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let result = worker.join();
            if !thread::panicking() {
                result.unwrap();
            }
        }
    }
}

#[test]
fn retry_preserves_http_contract_unicode_order_history_and_last() {
    let sandbox = Sandbox::new();
    let mock = Mock::success(&[
        json!({"ok":true,"raw":"ดิบ", "final":"สวัสดี OLIV 🫒\nบรรทัดสอง", "stt_redecoded":true, "cleanup_error":"synthetic fallback"}),
        json!({"ok":true,"raw":"raw", "final":"second result", "t_stt":0.25, "t_cleanup":0.1}),
    ]);
    sandbox.configure(&mock.url);
    let later = sandbox.pending("20261003-120001-000.wav");
    let earlier = sandbox.pending("20261003-120000-000.wav");
    let out = sandbox.run(&["retry"]);
    assert_success(&out);
    assert_eq!(
        String::from_utf8(out.stdout).unwrap().replace("\r\n", "\n"),
        "สวัสดี OLIV 🫒\nบรรทัดสอง\nsecond result\n"
    );
    assert!(!earlier.exists() && !later.exists());
    let history = sandbox.history();
    assert_eq!(history.len(), 2);
    assert_eq!(history[0]["recorded"], "20261003-120000-000");
    assert_eq!(history[0]["source"], "retry");
    assert_eq!(history[0]["audio_s"], 1.0);
    assert_eq!(history[0]["pasted"], false);
    assert_eq!(history[0]["stt_redecoded"], true);
    assert_eq!(history[0]["cleanup_error"], "synthetic fallback");
    assert_eq!(
        String::from_utf8(sandbox.run(&["last"]).stdout)
            .unwrap()
            .trim(),
        "second result"
    );
    assert_success(&sandbox.run(&["retry"]));
    let requests = mock.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    for (headers, body) in requests.iter() {
        assert!(headers.starts_with("POST /v1/dictate HTTP/1.1\r\n"));
        assert!(
            headers
                .to_lowercase()
                .contains("authorization: bearer ci-synthetic-token\r\n")
        );
        assert!(headers.to_ascii_lowercase().contains(&user_agent()));
        assert_eq!(body.as_object().unwrap().len(), 6);
        assert_eq!(body["cleanup"], false);
        assert_eq!(body["remove_fillers"], true);
        assert_eq!(body["thai_format"], false);
        assert_eq!(body["vocabulary"], json!(["Grafana", "ทดสอบ"]));
        assert_eq!(
            body["replacements"].to_string(),
            "{\"ซี\":\"C\",\"เอ\":\"A\"}"
        );
        assert_eq!(
            base64::engine::general_purpose::STANDARD
                .decode(body["wav_b64"].as_str().unwrap())
                .unwrap(),
            silence()
        );
    }
}

#[test]
fn failures_preserve_audio_then_recovery_consumes_it_once() {
    for (status, body) in [
        (400, "bad WAV".into()),
        (413, "<html>too big</html>".into()),
        (415, "unsupported".into()),
        (403, "error code: 1010".into()),
        (200, "{\"ok\":true}".into()),
        (200, "{\"ok\":true,\"final\":42}".into()),
        (401, "{\"ok\":false,\"error\":\"unauthorized\"}".into()),
        (403, "{\"ok\":false,\"error\":\"device revoked\"}".into()),
        (502, "{\"ok\":false,\"error\":\"stt unavailable\"}".into()),
        (
            503,
            "{\"ok\":false,\"error\":\"service unavailable\"}".into(),
        ),
        (200, "{\"ok\":false}".into()),
        (200, "<html>upstream error</html>".into()),
        (200, "x".repeat(1024 * 1024 + 1)),
    ] {
        let sandbox = Sandbox::new();
        let mock = Mock::new(vec![(status, body)], Duration::ZERO);
        sandbox.configure(&mock.url);
        let file = sandbox.pending("20261003-120000-000.wav");
        let out = sandbox.run(&["retry"]);
        assert!(!out.status.success());
        assert!(String::from_utf8_lossy(&out.stderr).contains("still pending"));
        assert_eq!(fs::read(&file).unwrap(), silence());
        assert!(sandbox.history().is_empty());
        assert_eq!(mock.requests.lock().unwrap().len(), 1);
        let recovered =
            Mock::success(&[json!({"ok":true,"raw":"silence","final":"","no_speech":true})]);
        sandbox.configure(&recovered.url);
        assert_success(&sandbox.run(&["retry"]));
        assert!(!file.exists());
        assert_eq!(sandbox.history().len(), 1);
        assert_success(&sandbox.run(&["retry"]));
        assert_eq!(recovered.requests.lock().unwrap().len(), 1);
    }
}

#[test]
fn retry_stops_at_first_failure_and_keeps_later_recordings() {
    let sandbox = Sandbox::new();
    let mock = Mock::new(
        vec![
            (
                200,
                json!({"ok":true,"final":"","no_speech":true}).to_string(),
            ),
            (503, json!({"ok":false,"error":"offline"}).to_string()),
        ],
        Duration::ZERO,
    );
    sandbox.configure(&mock.url);
    let first = sandbox.pending("1.wav");
    let second = sandbox.pending("2.wav");
    let third = sandbox.pending("3.wav");
    assert!(!sandbox.run(&["retry"]).status.success());
    assert!(!first.exists() && second.exists() && third.exists());
    assert_eq!(sandbox.history().len(), 1);
    assert_eq!(mock.requests.lock().unwrap().len(), 2);
}

#[test]
fn concurrent_retries_do_not_send_the_same_audio_twice() {
    let sandbox = Sandbox::new();
    let reply = json!({"ok":true,"final":"","no_speech":true}).to_string();
    let mock = Mock::new(
        vec![(200, reply.clone()), (200, reply)],
        Duration::from_millis(350),
    );
    sandbox.configure(&mock.url);
    sandbox.pending("1.wav");
    sandbox.pending("2.wav");
    let a = sandbox.command(&["retry"]).spawn().unwrap();
    // First retry must be inside its request while the other reads pending/.
    let deadline = Instant::now() + Duration::from_secs(5);
    while mock.requests.lock().unwrap().is_empty() {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    let b = sandbox.command(&["retry"]).spawn().unwrap();
    let a = finish(a);
    let b = finish(b);
    assert_success(&a);
    assert_success(&b);
    assert_eq!(mock.requests.lock().unwrap().len(), 2);
    assert_eq!(sandbox.history().len(), 2);
}

#[test]
fn offline_and_bad_configuration_leave_pending_untouched() {
    let sandbox = Sandbox::new();
    // Release a freshly allocated port to exercise connection refusal.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    sandbox.configure(&url);
    let file = sandbox.pending("1.wav");
    assert!(!sandbox.run(&["retry"]).status.success());
    assert_eq!(fs::read(&file).unwrap(), silence());
    fs::write(sandbox.0.join("config/oliv/config.toml"), "[broken").unwrap();
    assert!(!sandbox.run(&["retry"]).status.success());
    assert_eq!(fs::read(&file).unwrap(), silence());
    assert!(sandbox.history().is_empty());
}

#[test]
fn untrusted_https_certificate_keeps_pending_audio_without_sending_http() {
    let sandbox = Sandbox::new();
    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
    let tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![cert.der().clone()],
            rustls::pki_types::PrivatePkcs8KeyDer::from(signing_key.serialize_der()).into(),
        )
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    sandbox.configure_timeout(&format!("https://{}", listener.local_addr().unwrap()), 10);
    let peer = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        Instant::now() < deadline,
                        "CLI never attempted loopback TLS"
                    );
                    thread::sleep(Duration::from_millis(5));
                }
                Err(e) => panic!("TLS accept: {e}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let conn = rustls::ServerConnection::new(Arc::new(tls)).unwrap();
        let mut tls = rustls::StreamOwned::new(conn, stream);
        // A certificate failure must happen before any HTTP header/audio byte.
        !matches!(tls.read(&mut [0; 1]), Ok(1..))
    });
    let file = sandbox.pending("1.wav");
    let output = sandbox.run(&["retry"]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("still pending"));
    assert!(peer.join().unwrap(), "HTTP leaked through invalid TLS");
    assert_eq!(fs::read(file).unwrap(), silence());
    assert!(sandbox.history().is_empty());
}

#[test]
fn request_timeout_keeps_audio_and_returns_control() {
    let sandbox = Sandbox::new();
    let mock = Mock::new(
        vec![(200, json!({"ok":true,"no_speech":true}).to_string())],
        Duration::from_secs(11),
    );
    sandbox.configure_timeout(&mock.url, 10);
    let file = sandbox.pending("1.wav");
    let started = Instant::now();
    let output = sandbox.run(&["retry"]);
    assert!(!output.status.success());
    assert!(started.elapsed() >= Duration::from_secs(9));
    assert!(started.elapsed() < Duration::from_secs(17));
    assert_eq!(mock.requests.lock().unwrap().len(), 1);
    assert_eq!(fs::read(file).unwrap(), silence());
    assert!(sandbox.history().is_empty());
}

#[test]
fn history_trims_existing_file_and_skips_damaged_lines() {
    let sandbox = Sandbox::new();
    let mock = Mock::success(&[json!({"ok":true,"no_speech":true})]);
    sandbox.configure(&mock.url);
    let history = sandbox.0.join("state/oliv/history.jsonl");
    let original: String = (0..1200)
        .map(|n| format!("{}\n", json!({"final":format!("เดิม {n}")})))
        .collect();
    fs::write(&history, original).unwrap();
    sandbox.pending("1.wav");
    assert_success(&sandbox.run(&["retry"]));
    let entries = sandbox.history();
    assert_eq!(entries.len(), 1000);
    assert_eq!(entries[0]["final"], "เดิม 201");
    assert_eq!(entries[999]["no_speech"], true);
    let mut file = fs::OpenOptions::new().append(true).open(&history).unwrap();
    writeln!(file, "broken JSON\n{{\"final\":\"รอด 🫒\"}}").unwrap();
    drop(file);
    assert_eq!(sandbox.history().len(), 1001);
    let last = sandbox.run(&["last"]);
    assert_success(&last);
    assert_eq!(String::from_utf8(last.stdout).unwrap().trim(), "รอด 🫒");
}

#[test]
fn health_is_minimal_unauthenticated_and_not_a_dictation_preflight() {
    let sandbox = Sandbox::new();
    let mock = Mock::success(&[json!({"ok":true})]);
    sandbox.configure(&mock.url);
    assert_success(&sandbox.run(&["health"]));
    let requests = mock.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    let headers = requests[0].0.to_ascii_lowercase();
    assert!(headers.starts_with("get /health "));
    assert!(!headers.contains("authorization"));
    assert!(headers.contains(&user_agent()));
    assert!(requests[0].1.is_null());
}

#[test]
fn retry_after_survives_processes_and_blocks_the_whole_queue() {
    for header in ["Retry-After: 60\r\n", "Retry-After: invalid\r\n", ""] {
        let sandbox = Sandbox::new();
        let mock = Mock::with_headers(
            vec![(429, "<html>busy</html>".into())],
            Duration::ZERO,
            header,
        );
        sandbox.configure(&mock.url);
        let a = sandbox.pending("1.wav");
        let b = sandbox.pending("2.wav");
        let first = sandbox.run(&["retry"]);
        assert!(!first.status.success());
        assert!(String::from_utf8_lossy(&first.stderr).contains("wait at least 60 seconds"));
        let second = sandbox.run(&["retry"]);
        assert!(!second.status.success());
        assert!(String::from_utf8_lossy(&second.stderr).contains("cooldown"));
        assert_eq!(mock.requests.lock().unwrap().len(), 1);
        assert_eq!(fs::read(a).unwrap(), silence());
        assert_eq!(fs::read(b).unwrap(), silence());
        assert!(sandbox.history().is_empty());
        assert!(!sandbox.0.join("calls").exists());
        // Simulate time having passed without a minute-long test sleep.
        fs::write(sandbox.0.join("state/oliv/retry-after"), "0").unwrap();
        let recovered = Mock::success(&[
            json!({"ok":true,"no_speech":true}),
            json!({"ok":true,"no_speech":true}),
        ]);
        sandbox.configure(&recovered.url);
        assert_success(&sandbox.run(&["retry"]));
        assert_eq!(sandbox.history().len(), 2);
        assert_eq!(recovered.requests.lock().unwrap().len(), 2);
    }
}

#[test]
fn retry_after_http_date_and_503_also_defer_requests() {
    let sandbox = Sandbox::new();
    let date = httpdate::fmt_http_date(std::time::SystemTime::now() + Duration::from_secs(120));
    let mock = Mock::with_headers(
        vec![(503, "unavailable".into())],
        Duration::ZERO,
        &format!("Retry-After: {date}\r\n"),
    );
    sandbox.configure(&mock.url);
    sandbox.pending("1.wav");
    assert!(!sandbox.run(&["retry"]).status.success());
    assert!(!sandbox.run(&["retry"]).status.success());
    assert_eq!(mock.requests.lock().unwrap().len(), 1);
    assert!(sandbox.history().is_empty());
}

/// Linux-only: drives the `wl-copy`/`hyprctl` stubs. Windows copies through the
/// Win32 clipboard, which a CI test must not overwrite.
#[cfg(unix)]
#[test]
fn single_retry_copies_once_never_pastes_even_if_copy_failed() {
    for copy_fails in [false, true] {
        let sandbox = Sandbox::new();
        let mock = Mock::success(&[
            json!({"ok":true,"final":"ข้อความ fallback", "cleanup_error":"LLM unavailable"}),
        ]);
        sandbox.configure(&mock.url);
        sandbox.pending("1.wav");
        if copy_fails {
            fs::write(
                sandbox.0.join("bin/wl-copy"),
                "#!/bin/sh\necho copy >> \"$OLIV_TEST_ROOT/calls\"\nexit 1\n",
            )
            .unwrap();
        }
        let out = sandbox.run(&["retry"]);
        assert_eq!(out.status.success(), !copy_fails);
        assert_success(&sandbox.run(&["retry"]));
        assert_eq!(sandbox.history().len(), 1);
        assert_eq!(sandbox.history()[0]["pasted"], false);
        assert_eq!(mock.requests.lock().unwrap().len(), 1);
        assert_eq!(
            fs::read_to_string(sandbox.0.join("calls")).unwrap(),
            "copy\n"
        );
        if !copy_fails {
            assert_eq!(
                fs::read_to_string(sandbox.0.join("clipboard")).unwrap(),
                "ข้อความ fallback"
            );
        }
    }
}

#[test]
fn diagnostics_do_not_echo_keys_or_untrusted_bodies() {
    for (status, body, expected) in [
        (401, "ci-synthetic-token", "check/replace"),
        (
            403,
            r#"{"ok":false,"error":"API key does not allow this operation"}"#,
            "scope dictate",
        ),
        (403, "error code: 1010 ci-synthetic-token", "Cloudflare"),
        (500, r#"{"error":"ci-synthetic-token"}"#, "server/pipeline"),
    ] {
        let sandbox = Sandbox::new();
        let mock = Mock::new(vec![(status, body.into())], Duration::ZERO);
        sandbox.configure(&mock.url);
        sandbox.pending("1.wav");
        let out = sandbox.run(&["retry"]);
        let diagnostic = String::from_utf8(out.stderr).unwrap();
        assert!(diagnostic.contains(expected), "{diagnostic}");
        assert!(!diagnostic.contains("ci-synthetic-token"));
        assert!(out.stdout.is_empty());
        assert!(sandbox.history().is_empty());
    }
    let sandbox = Sandbox::new();
    sandbox.configure("https://example.com");
    fs::write(
        sandbox.0.join("config/oliv/config.toml"),
        "[server]\ntoken = \"ci-synthetic-token\" oops",
    )
    .unwrap();
    sandbox.pending("1.wav");
    let out = sandbox.run(&["retry"]);
    assert!(!out.status.success());
    assert!(!String::from_utf8_lossy(&out.stderr).contains("ci-synthetic-token"));
}

#[test]
fn redirects_never_receive_audio_and_pending_is_retained() {
    for status in [301, 302, 303, 307, 308] {
        let sandbox = Sandbox::new();
        let trap = TcpListener::bind("127.0.0.1:0").unwrap();
        trap.set_nonblocking(true).unwrap();
        let mock = Mock::with_headers(
            vec![(status, "redirect".into())],
            Duration::ZERO,
            &format!("Location: http://{}/stolen\r\n", trap.local_addr().unwrap()),
        );
        sandbox.configure(&mock.url);
        let wav = sandbox.pending("1.wav");
        let out = sandbox.run(&["retry"]);
        assert!(!out.status.success());
        assert!(String::from_utf8_lossy(&out.stderr).contains("redirect rejected"));
        assert_eq!(
            trap.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        assert_eq!(fs::read(wav).unwrap(), silence());
        assert!(sandbox.history().is_empty());
    }
}
