use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

pub struct Worker {
    child: Child,
    input: Option<ChildStdin>,
    replies: Receiver<Result<Value, String>>,
    next: u64,
}
impl Worker {
    pub fn new(directory: &Path, name: &str, args: &[String]) -> Result<Self, String> {
        let mut command = Command::new(directory.join(name));
        command
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        command.env(
            "OLIV_INFERENCE_EXECUTABLE",
            directory.join("oliv-inference"),
        );
        command.env(
            "OLIV_WHISPER_TOKENIZER",
            directory.join("whisper-tokenizer"),
        );
        if std::env::var_os("HF_HOME").is_none()
            && let Some(home) = std::env::var_os("HOME")
        {
            let cache = Path::new(&home).join("Library/Application Support/OLIV/models");
            if cache.is_dir() {
                command.env("HF_HOME", cache);
            }
        }
        let mut child = command
            .spawn()
            .map_err(|e| format!("Cannot start {name}: {e}"))?;
        let input = child.stdin.take();
        let output = child.stdout.take().unwrap();
        let (send, replies) = mpsc::sync_channel(8);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(output);
            loop {
                let mut line = Vec::new();
                let result = (|| {
                    loop {
                        let buffer = reader.fill_buf().map_err(|e| e.to_string())?;
                        if buffer.is_empty() {
                            return Err("Native worker closed stdout".into());
                        }
                        let count = buffer
                            .iter()
                            .position(|b| *b == 10)
                            .map_or(buffer.len(), |i| i + 1);
                        let complete = buffer[count - 1] == 10;
                        if line.len() + count > 2 * 1024 * 1024 {
                            return Err("Native reply exceeds 2 MiB".into());
                        }
                        line.extend_from_slice(&buffer[..count]);
                        reader.consume(count);
                        if complete {
                            break;
                        }
                    }
                    serde_json::from_slice(&line).map_err(|e| format!("Invalid native reply: {e}"))
                })();
                let failed = result.is_err();
                if send.send(result).is_err() || failed {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            input,
            replies,
            next: 0,
        })
    }
    pub fn request(&mut self, mut body: Value, timeout: Duration) -> Result<Value, String> {
        self.next += 1;
        body["id"] = self.next.into();
        let input = self.input.as_mut().ok_or("Closed worker")?;
        serde_json::to_writer(&mut *input, &body).map_err(|e| e.to_string())?;
        input
            .write_all(b"\n")
            .and_then(|_| input.flush())
            .map_err(|e| e.to_string())?;
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let reply = self
                .replies
                .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
                .map_err(|_| "Native worker timed out or exited".to_string())??;
            if reply["id"] != self.next || reply.get("event").is_some() {
                continue;
            }
            if reply["ok"] != true {
                return Err("Native worker rejected request (enable local inference diagnostics for details)".into());
            }
            return Ok(reply);
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.input.take();
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
