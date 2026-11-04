//! Lazy, private stdio connection to the native MLX model helper.
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

const MAX_REPLY: u64 = 2 * 1024 * 1024;
/// The helper's stdin. Shared so a live-preview cancel can be written while a
/// request (the preview itself) holds the session lock.
type Input = Arc<Mutex<ChildStdin>>;
struct Session {
    child: Child,
    input: Input,
    replies: mpsc::Receiver<Result<Value, String>>,
    next_id: u64,
    cleanup_policy: Option<u64>,
}
impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn write_line(input: &Input, body: &Value) -> Result<(), String> {
    let bytes = serde_json::to_vec(body).map_err(|_| "Could not encode inference request")?;
    let mut input = input.lock().map_err(|_| "Inference input unavailable")?;
    input
        .write_all(&bytes)
        .and_then(|_| input.write_all(b"\n"))
        .and_then(|_| input.flush())
        .map_err(|_| "Inference process stopped".to_string())
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
        let input = Arc::new(Mutex::new(child.stdin.take().unwrap()));
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
            cleanup_policy: None,
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
        write_line(&self.input, &body)?;
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

pub struct Inference {
    session: Mutex<Option<Session>>,
    /// The live helper's stdin, reachable without the session lock.
    input: Mutex<Option<Input>>,
    /// Live previews up to this sequence number are cancelled. Monotonic.
    cancelled_through: AtomicU64,
    cleanup_idle_seconds: AtomicU64,
}
impl Default for Inference {
    fn default() -> Self {
        Self {
            session: Mutex::new(None),
            input: Mutex::new(None),
            cancelled_through: AtomicU64::new(0),
            cleanup_idle_seconds: AtomicU64::new(u64::MAX),
        }
    }
}
impl Inference {
    pub fn set_cleanup_idle_seconds(&self, seconds: u64) {
        self.cleanup_idle_seconds.store(seconds, Ordering::SeqCst);
    }

    fn sync_cleanup_policy(&self, session: &mut Session, id: &Value) -> Result<(), String> {
        let seconds = self.cleanup_idle_seconds.load(Ordering::SeqCst);
        if seconds != u64::MAX && session.cleanup_policy != Some(seconds) {
            session.request(
                json!({"cmd":"memory_policy","cleanup_idle_seconds":seconds}),
                Duration::from_secs(120),
                id,
            )?;
            session.cleanup_policy = Some(seconds);
        }
        Ok(())
    }

    /// Update an existing helper, retaining a lazy spawn when no model is in use.
    pub fn apply_cleanup_policy(&self, id: &Value) -> Result<(), String> {
        let mut session = self
            .session
            .lock()
            .map_err(|_| "Inference state unavailable")?;
        let result = session
            .as_mut()
            .map(|s| self.sync_cleanup_policy(s, id))
            .unwrap_or(Ok(()));
        if result.is_err() {
            if let Ok(mut input) = self.input.lock() {
                *input = None;
            }
            *session = None;
        }
        result
    }
    pub fn request(
        &self,
        body: Value,
        timeout: Duration,
        outer_id: &Value,
    ) -> Result<Value, String> {
        let mut session = self
            .session
            .lock()
            .map_err(|_| "Inference state unavailable")?;
        if session.is_none() {
            let spawned = Session::spawn()?;
            if let Ok(mut input) = self.input.lock() {
                *input = Some(spawned.input.clone());
            }
            *session = Some(spawned);
        }
        let active = session.as_mut().unwrap();
        let result = self
            .sync_cleanup_policy(active, outer_id)
            .and_then(|()| active.request(body, timeout, outer_id));
        // On an unknown process state, discard it. Next explicit call respawns;
        // never resend this inference request.
        if result.is_err() {
            if let Ok(mut input) = self.input.lock() {
                *input = None;
            }
            *session = None;
        }
        result
    }

    /// Stop every live preview up to `through`, including one the helper is
    /// decoding right now. Out of band: called from the stdin reader while the
    /// request loop may be waiting on that preview. The helper sends no reply.
    pub fn cancel_previews(&self, through: u64) {
        self.cancelled_through.fetch_max(through, Ordering::SeqCst);
        let input = self.input.lock().ok().and_then(|input| input.clone());
        if let Some(input) = input {
            // A dead helper is noticed (and replaced) by the next request.
            let _ = write_line(&input, &json!({"cmd":"cancel_preview","through":through}));
        }
    }

    /// Whether preview `seq` was cancelled before it reached the helper.
    pub fn preview_cancelled(&self, seq: u64) -> bool {
        seq <= self.cancelled_through.load(Ordering::SeqCst)
    }

    /// Stop the helper now (worker exit), even mid-request.
    pub fn shutdown(&self) {
        if let Ok(mut input) = self.input.lock() {
            *input = None;
        }
        // A request still holding the lock is abandoned with the process.
        if let Ok(mut session) = self.session.try_lock() {
            *session = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_policy_is_lazy_and_retained_without_spawning_a_helper() {
        let inference = Inference::default();
        assert_eq!(
            inference.cleanup_idle_seconds.load(Ordering::SeqCst),
            u64::MAX
        );
        inference.set_cleanup_idle_seconds(0);
        inference.apply_cleanup_policy(&Value::Null).unwrap();
        assert!(inference.session.lock().unwrap().is_none());
        assert_eq!(inference.cleanup_idle_seconds.load(Ordering::SeqCst), 0);
        inference.set_cleanup_idle_seconds(30);
        inference.apply_cleanup_policy(&Value::Null).unwrap();
        assert_eq!(inference.cleanup_idle_seconds.load(Ordering::SeqCst), 30);
    }

    #[test]
    fn cancelling_previews_is_monotonic_and_needs_no_helper() {
        let inference = Inference::default();
        assert!(!inference.preview_cancelled(1));
        inference.cancel_previews(5);
        assert!(inference.preview_cancelled(5));
        assert!(inference.preview_cancelled(3));
        assert!(!inference.preview_cancelled(6));
        // A late cancel for an older preview never un-cancels a newer one.
        inference.cancel_previews(2);
        assert!(inference.preview_cancelled(5));
    }
}
