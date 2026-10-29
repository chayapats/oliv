//! The daemon's unix socket protocol: the client writes one command line,
//! the daemon answers with one JSON line and closes the connection.

use std::io::{BufRead, BufReader, Write};
use std::time::Duration;

use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Command {
    Start,
    Stop,
    Cancel,
    Status,
}

impl Command {
    pub fn parse(line: &str) -> Option<Command> {
        match line.trim() {
            "start" => Some(Command::Start),
            "stop" => Some(Command::Stop),
            "cancel" => Some(Command::Cancel),
            "status" => Some(Command::Status),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Command::Start => "start",
            Command::Stop => "stop",
            Command::Cancel => "cancel",
            Command::Status => "status",
        }
    }
}

/// Send one command to the running daemon and return its reply.
pub fn send(cmd: Command) -> Result<Value, String> {
    let path = crate::store::socket_path()?;
    let mut s = crate::transport::Stream::connect(&path)
        .map_err(|_| "oliv daemon is not running".to_string())?;
    // Longer than the daemon's own 5 s wait, so its "busy" reply still arrives.
    s.set_read_timeout(Some(Duration::from_secs(8)))
        .and_then(|_| s.set_write_timeout(Some(Duration::from_secs(5))))
        .and_then(|_| writeln!(s, "{}", cmd.as_str()))
        .map_err(|e| format!("oliv daemon: {e}"))?;
    let mut line = String::new();
    BufReader::new(&mut s)
        .read_line(&mut line)
        .map_err(|e| format!("oliv daemon: {e}"))?;
    #[cfg(windows)]
    s.write_all(&[1]).map_err(|e| format!("oliv daemon: {e}"))?;
    serde_json::from_str(&line).map_err(|_| "oliv daemon: bad reply".to_string())
}

/// One line for `oliv status`.
pub fn status_line(v: &Value, pending: usize) -> String {
    let mut parts = Vec::new();
    match v["state"].as_str() {
        Some("recording") => parts.push(format!(
            "recording {:.1}s",
            v["recording_s"].as_f64().unwrap_or(0.0)
        )),
        _ if v["queued"].as_u64().unwrap_or(0) == 0 => parts.push("idle".into()),
        _ => {}
    }
    match v["queued"].as_u64().unwrap_or(0) {
        0 => {}
        1 => parts.push("processing".into()),
        n => parts.push(format!("processing {n}")),
    }
    if pending > 0 {
        parts.push(format!("pending {pending}"));
    }
    parts.join(" · ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn commands_round_trip() {
        for c in [
            Command::Start,
            Command::Stop,
            Command::Cancel,
            Command::Status,
        ] {
            assert_eq!(Command::parse(&format!("{}\n", c.as_str())), Some(c));
        }
        assert_eq!(Command::parse(" stop "), Some(Command::Stop));
        assert_eq!(Command::parse("retry"), None);
        assert_eq!(Command::parse(""), None);
    }

    #[test]
    fn status_lines() {
        assert_eq!(status_line(&json!({"state":"idle","queued":0}), 0), "idle");
        assert_eq!(
            status_line(&json!({"state":"idle","queued":0}), 2),
            "idle · pending 2"
        );
        assert_eq!(
            status_line(
                &json!({"state":"recording","recording_s":3.42,"queued":0}),
                0
            ),
            "recording 3.4s"
        );
        assert_eq!(
            status_line(&json!({"state":"idle","queued":1}), 0),
            "processing"
        );
        assert_eq!(
            status_line(
                &json!({"state":"recording","recording_s":1.0,"queued":2}),
                1
            ),
            "recording 1.0s · processing 2 · pending 1"
        );
    }
}
