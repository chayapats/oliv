//! Durable request metadata only. Never accept credentials, URLs or payloads.
use std::fs::{self, OpenOptions};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, params};

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[derive(Default)]
pub struct Observation {
    pub key_id: Option<String>,
    pub charged: bool,
}

pub struct Audit(Mutex<Connection>);

impl Audit {
    pub fn open(root: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        let directory = root.join("usage");
        fs::create_dir_all(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let path = directory.join("requests.sqlite3");
        OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let connection = Connection::open(path)?;
        connection.busy_timeout(Duration::from_secs(2))?;
        connection.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS metadata (name TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS requests (
                id INTEGER PRIMARY KEY, started_at INTEGER NOT NULL, finished_at INTEGER NOT NULL,
                key_id TEXT, method TEXT NOT NULL, route TEXT NOT NULL, status INTEGER NOT NULL,
                elapsed_ms INTEGER NOT NULL, quota_charged INTEGER NOT NULL,
                no_speech INTEGER, cleanup_failed INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS requests_key_id ON requests(key_id, id);
            CREATE INDEX IF NOT EXISTS requests_started ON requests(started_at, id);
            CREATE INDEX IF NOT EXISTS requests_key_started ON requests(key_id, started_at);",
        )?;
        connection.execute(
            "INSERT OR IGNORE INTO metadata VALUES ('recording_since', ?1)",
            [now_ms()],
        )?;
        Ok(Self(Mutex::new(connection)))
    }

    pub fn record(
        &self,
        observation: &Observation,
        method: &str,
        route: &str,
        started_at: i64,
        elapsed_ms: i64,
        reply: &crate::api::Reply,
    ) -> rusqlite::Result<()> {
        let method = match method {
            "GET" => "GET",
            "POST" => "POST",
            _ => "other",
        };
        let route = match route {
            "/v1/dictate" => "/v1/dictate",
            "/v1/clean" => "/v1/clean",
            "/v1/status" => "/v1/status",
            "/v1/dictionary" => "/v1/dictionary",
            _ => "other",
        };
        self.0.lock().unwrap_or_else(|e| e.into_inner()).execute(
            "INSERT INTO requests (started_at, finished_at, key_id, method, route, status,
                elapsed_ms, quota_charged, no_speech, cleanup_failed)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                started_at,
                now_ms(),
                observation.key_id,
                method,
                route,
                reply.0,
                elapsed_ms,
                observation.charged,
                reply.1.get("no_speech").and_then(|v| v.as_bool()),
                reply.1.get("cleanup_error").is_some_and(|v| !v.is_null())
            ],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persists_after_reopen_and_ignores_sensitive_reply_and_path() {
        let root =
            std::env::temp_dir().join(format!("oliv-audit-{}-{}", std::process::id(), now_ms()));
        let audit = Audit::open(&root).unwrap();
        let observed = Observation {
            key_id: Some("0123456789abcdef".into()),
            charged: true,
        };
        audit.record(&observed, "POST", "/private-secret-path", 100, 50,
            &(200, serde_json::json!({"raw":"private transcript", "token":"private credential", "no_speech":false}))).unwrap();
        drop(audit);
        let audit = Audit::open(&root).unwrap();
        let db = audit.0.lock().unwrap();
        let row: (String, String, i64, i64) = db
            .query_row(
                "SELECT key_id, route, status, quota_charged FROM requests",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!(row, ("0123456789abcdef".into(), "other".into(), 200, 1));
        drop(db);
        drop(audit);
        let bytes = fs::read(root.join("usage/requests.sqlite3")).unwrap();
        assert!(!bytes.windows(7).any(|b| b == b"private"));
        fs::remove_dir_all(root).unwrap();
    }
}
