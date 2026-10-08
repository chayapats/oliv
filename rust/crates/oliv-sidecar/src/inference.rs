//! Lazy, private stdio connection to the native MLX model helper.
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Mutex, mpsc};
use std::time::Duration;

const MAX_REPLY: u64 = 2 * 1024 * 1024;
struct Session {
    child: Child,
    input: ChildStdin,
    replies: mpsc::Receiver<Result<Value, String>>,
    next_id: u64,
}
impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Session {
    fn spawn() -> Result<Self, String> {
        let executable = std::env::var_os("OLIV_INFERENCE_EXECUTABLE")
            .ok_or("Inference runtime not configured")?;
        let mut child = Command::new(executable)
            .env_remove("GROQ_API_KEY")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "Could not start inference runtime")?;
        let input = child.stdin.take().unwrap();
        let mut reader = BufReader::new(child.stdout.take().unwrap());
        let (sender, replies) = mpsc::sync_channel(8);
        std::thread::spawn(move || {
            loop {
                let mut line = Vec::new();
                // Take implements BufRead and bounds a malicious or corrupt reply.
                let read = (&mut reader)
                    .take(MAX_REPLY + 1)
                    .read_until(b'\n', &mut line);
                let result = match read {
                    Ok(0) => Err("Inference process stopped".to_string()),
                    Ok(_) if line.len() as u64 > MAX_REPLY => {
                        Err("Inference reply too large".to_string())
                    }
                    Ok(_) => serde_json::from_slice(&line)
                        .map_err(|_| "Invalid inference reply".to_string()),
                    Err(_) => Err("Could not read inference reply".to_string()),
                };
                let failed = result.is_err();
                if sender.send(result).is_err() || failed {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            input,
            replies,
            next_id: 0,
        })
    }
    fn request(
        &mut self,
        mut body: Value,
        timeout: Duration,
        outer_id: &Value,
    ) -> Result<Value, String> {
        self.next_id += 1;
        body["id"] = json!(self.next_id);
        let bytes = serde_json::to_vec(&body).map_err(|_| "Could not encode inference request")?;
        self.input
            .write_all(&bytes)
            .and_then(|_| self.input.write_all(b"\n"))
            .and_then(|_| self.input.flush())
            .map_err(|_| "Inference process stopped")?;
        loop {
            let mut reply = self
                .replies
                .recv_timeout(timeout)
                .map_err(|_| "Inference request timed out")??;
            if reply["id"] != self.next_id {
                return Err("Inference reply did not match request".into());
            }
            if reply["event"] == "progress" {
                reply["id"] = outer_id.clone();
                crate::emit(&reply).map_err(|_| "Could not report model progress")?;
                continue;
            }
            if reply["ok"] != true && body["cmd"] != "download" {
                return Err("Inference failed; check models and runtime".into());
            }
            return Ok(reply);
        }
    }
}

#[derive(Default)]
pub struct Inference(Mutex<Option<Session>>);
impl Inference {
    pub fn request(
        &self,
        body: Value,
        timeout: Duration,
        outer_id: &Value,
    ) -> Result<Value, String> {
        let mut session = self.0.lock().map_err(|_| "Inference state unavailable")?;
        if session.is_none() {
            *session = Some(Session::spawn()?);
        }
        let result = session.as_mut().unwrap().request(body, timeout, outer_id);
        // On an unknown process state, discard it. Next explicit call respawns;
        // never resend this inference request.
        if result.is_err() {
            *session = None;
        }
        result
    }
}
