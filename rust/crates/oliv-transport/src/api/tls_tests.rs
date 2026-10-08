//! Real loopback TLS handshakes. Test roots are injected only into a test agent;
//! production continues to use rustls certificate and hostname verification.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use rcgen::{BasicConstraints, CertificateParams, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair};
use rustls::pki_types::PrivatePkcs8KeyDer;

use super::{Config, agent_config, dictate_with_agent};

struct TlsServer {
    url: String,
    ca: Vec<u8>,
    request: thread::JoinHandle<Result<String, String>>,
}

fn serve_tls(certificate_host: &str, status: u16, headers: &str, body: &str) -> TlsServer {
    let mut params = CertificateParams::new(Vec::<String>::new()).unwrap();
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca_key = KeyPair::generate().unwrap();
    let ca = params.self_signed(&ca_key).unwrap().der().to_vec();
    let issuer = Issuer::new(params, ca_key);
    let mut leaf = CertificateParams::new(vec![certificate_host.to_string()]).unwrap();
    leaf.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    let key = KeyPair::generate().unwrap();
    let cert = leaf.signed_by(&key, &issuer).unwrap();
    let server = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![cert.der().clone()],
            PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
        )
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("https://{}", listener.local_addr().unwrap());
    let response = format!(
        "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}",
        body.len()
    );
    let request = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let socket = loop {
            match listener.accept() {
                Ok((socket, _)) => break socket,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err("TLS test listener timed out".into());
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                Err(e) => return Err(e.to_string()),
            }
        };
        socket.set_nonblocking(false).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        socket
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let conn = rustls::ServerConnection::new(Arc::new(server)).unwrap();
        let mut reader = BufReader::new(rustls::StreamOwned::new(conn, socket));
        let mut request = String::new();
        let mut length = 0;
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                return Err("TLS peer closed without a request".into());
            }
            if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                length = value.trim().parse::<usize>().map_err(|e| e.to_string())?;
            }
            request.push_str(&line);
            if request.len() > 8192 || length > 1024 * 1024 {
                return Err("oversized synthetic request".into());
            }
            if line == "\r\n" {
                break;
            }
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).map_err(|e| e.to_string())?;
        request.push_str(&String::from_utf8(body).map_err(|e| e.to_string())?);
        let mut stream = reader.into_inner();
        stream
            .write_all(response.as_bytes())
            .map_err(|e| e.to_string())?;
        stream.conn.send_close_notify();
        stream.flush().map_err(|e| e.to_string())?;
        Ok(request)
    });
    TlsServer { url, ca, request }
}

fn cfg(url: &str) -> Config {
    Config::new(url, "test-device-token", 10).unwrap()
}

fn trust_test_ca(cfg: &Config, ca: &[u8]) -> ureq::Agent {
    let cert = ureq::tls::Certificate::from_der(ca).to_owned();
    let tls = ureq::tls::TlsConfig::builder()
        .root_certs(ureq::tls::RootCerts::new_with_certs(&[cert]))
        .build();
    // Same request policy as production; only the roots and ambient proxy differ.
    agent_config(cfg).proxy(None).tls_config(tls).build().into()
}

#[test]
fn https_with_trusted_test_ca_sends_contract_and_reads_reply() {
    let server = serve_tls(
        "127.0.0.1",
        200,
        "",
        r#"{"ok":true,"raw":"synthetic","final":"ทดสอบ TLS"}"#,
    );
    let cfg = cfg(&server.url);
    let reply = dictate_with_agent(&cfg, &[1, 2, 3], &trust_test_ca(&cfg, &server.ca)).unwrap();
    assert_eq!(reply.final_text, "ทดสอบ TLS");
    let request = server.request.join().unwrap().unwrap();
    assert!(request.starts_with("POST /v1/dictate HTTP/1.1\r\n"));
    assert!(
        request
            .to_ascii_lowercase()
            .contains("authorization: bearer test-device-token\r\n")
    );
    assert!(request.contains(r#""wav_b64":"AQID""#));
    assert!(
        request
            .to_ascii_lowercase()
            .contains(&format!("user-agent: {}\r\n", super::USER_AGENT))
    );
}

#[test]
fn production_tls_rejects_an_untrusted_certificate() {
    let server = serve_tls(
        "127.0.0.1",
        200,
        "",
        r#"{"ok":true,"final":"must not arrive"}"#,
    );
    let cfg = cfg(&server.url);
    let production_roots = agent_config(&cfg).proxy(None).build().into();
    let result = dictate_with_agent(&cfg, &[1], &production_roots);
    assert!(result.is_err(), "untrusted test CA was accepted");
    assert!(
        server.request.join().unwrap().is_err(),
        "HTTP credentials reached untrusted server"
    );
}

#[test]
fn trusted_ca_does_not_disable_hostname_verification() {
    let server = serve_tls("wrong-host.example.com", 200, "", r#"{"ok":true}"#);
    let cfg = cfg(&server.url);
    let result = dictate_with_agent(&cfg, &[1], &trust_test_ca(&cfg, &server.ca));
    assert!(result.is_err(), "wrong hostname certificate was accepted");
    assert!(
        server.request.join().unwrap().is_err(),
        "HTTP credentials reached wrong TLS host"
    );
}

#[test]
fn authenticated_https_never_follows_redirects() {
    for status in [301, 302, 303, 307, 308] {
        let trap = TcpListener::bind("127.0.0.1:0").unwrap();
        trap.set_nonblocking(true).unwrap();
        let headers = format!(
            "Location: https://{}/stolen\r\n",
            trap.local_addr().unwrap()
        );
        let server = serve_tls(
            "127.0.0.1",
            status,
            &headers,
            r#"{"ok":false,"error":"redirect"}"#,
        );
        let cfg = cfg(&server.url);
        let error = dictate_with_agent(&cfg, &[1], &trust_test_ca(&cfg, &server.ca)).unwrap_err();
        assert!(error.contains(&format!("HTTP {status}")), "{error}");
        server.request.join().unwrap().unwrap();
        assert_eq!(
            trap.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    }
}
