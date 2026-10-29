//! Personal dictionaries, stored per profile and synced by clients through
//! `GET/POST /v1/dictionary`; every dictate/clean request applies the caller's
//! dictionary automatically.
//!
//! A *profile* is one person's dictionary. API keys are per device, so a
//! profile links several keys (Mac + iPhone): `oliv-keys profile link`. A key
//! without a link is its own profile, so nothing needs configuring until two
//! devices should share one dictionary. Links live here, not in the key
//! store, so the key store format (and rollback to older binaries) is
//! untouched.
//!
//! Sync model: clients send operations (`upsert` by client-chosen id,
//! `delete` by id), applied atomically in order, last writer wins per entry.
//! Every change bumps the profile's `revision`; dictate replies carry it so a
//! client knows when to refresh its cached copy.

use std::fs::{self, OpenOptions};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::{Map, Value};

use crate::audit::now_ms;
use crate::user_dictionary::{Entry, UserDictionary, clean_field, dedupe_key};

/// Entries per profile.
pub const MAX_ENTRIES: usize = 1000;
/// Operations per sync request.
pub const MAX_OPS: usize = 1000;
/// Entry ids (client-chosen), key ids and profile names.
const MAX_NAME_CHARS: usize = 64;
const SOURCES: [&str; 3] = ["manual", "import", "autoLearn"];
const ENTRY_COLUMNS: &str = "id, word, correction, enabled, starred, source, updated_at";

pub type StoreResult<T> = Result<T, rusqlite::Error>;

/// One stored entry, as returned to clients.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct StoredEntry {
    pub id: String,
    pub word: String,
    pub correction: Option<String>,
    pub enabled: bool,
    pub starred: bool,
    pub source: String,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Snapshot {
    pub revision: i64,
    pub entries: Vec<StoredEntry>,
}

/// A validated sync operation.
#[derive(Clone, Debug, PartialEq)]
pub enum Op {
    Upsert(NewEntry),
    Delete(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct NewEntry {
    pub id: String,
    pub word: String,
    pub correction: Option<String>,
    pub enabled: bool,
    pub starred: bool,
    pub source: String,
}

/// An operation that was valid but could not be applied.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Rejection {
    pub index: usize,
    pub id: String,
    /// `duplicate` (same word + correction as another entry) or `limit`
    /// ([`MAX_ENTRIES`] reached).
    pub reason: &'static str,
}

pub struct DictionaryStore(Mutex<Connection>);

impl DictionaryStore {
    /// `ROOT/dictionary/dictionary.sqlite3`, private (0700 dir, 0600 file).
    pub fn open(root: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        let directory = root.join("dictionary");
        fs::create_dir_all(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let path = directory.join("dictionary.sqlite3");
        OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let connection = Connection::open(path)?;
        connection.busy_timeout(Duration::from_secs(2))?;
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")?;
        Ok(Self::with(connection)?)
    }

    /// A throwaway store for tests.
    pub fn in_memory() -> Self {
        Self::with(Connection::open_in_memory().expect("in-memory sqlite"))
            .expect("dictionary schema")
    }

    fn with(connection: Connection) -> StoreResult<Self> {
        migrate(&connection)?;
        Ok(Self(Mutex::new(connection)))
    }

    fn connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The profile a key belongs to (the key itself unless linked).
    pub fn profile_of(&self, key_id: &str) -> StoreResult<String> {
        profile_of(&self.connection(), key_id)
    }

    pub fn snapshot(&self, key_id: &str) -> StoreResult<Snapshot> {
        let c = self.connection();
        let profile = profile_of(&c, key_id)?;
        snapshot(&c, &profile)
    }

    /// The caller's dictionary, compiled for the pipeline, and its revision.
    pub fn compiled(&self, key_id: &str) -> StoreResult<(UserDictionary, i64)> {
        let snap = self.snapshot(key_id)?;
        let entries: Vec<Entry> = snap
            .entries
            .into_iter()
            .map(|e| Entry {
                word: e.word,
                correction: e.correction,
                enabled: e.enabled,
                starred: e.starred,
            })
            .collect();
        Ok((UserDictionary::new(&entries), snap.revision))
    }

    /// Apply operations atomically, in order. Returns the new snapshot and the
    /// operations that could not be applied.
    pub fn apply(&self, key_id: &str, ops: &[Op]) -> StoreResult<(Snapshot, Vec<Rejection>)> {
        let mut c = self.connection();
        let profile = profile_of(&c, key_id)?;
        let tx = c.transaction()?;
        let mut rejected = Vec::new();
        let mut changed = false;
        for (index, op) in ops.iter().enumerate() {
            match apply_one(&tx, &profile, op)? {
                Applied::Changed => changed = true,
                Applied::Unchanged => {}
                Applied::Rejected(reason) => rejected.push(Rejection {
                    index,
                    id: op.id().to_string(),
                    reason,
                }),
            }
        }
        if changed {
            tx.execute(
                "INSERT INTO profiles (id, revision) VALUES (?1, 1)
                 ON CONFLICT(id) DO UPDATE SET revision = revision + 1",
                [&profile],
            )?;
        }
        tx.commit()?;
        Ok((snapshot(&c, &profile)?, rejected))
    }

    /// Share `profile`'s dictionary with `key_id` (moving the key off its
    /// previous profile; that profile's entries stay where they are).
    pub fn link(&self, key_id: &str, profile: &str) -> Result<(), String> {
        valid_name(key_id, "key id")?;
        valid_name(profile, "profile")?;
        self.connection()
            .execute(
                "INSERT INTO key_profiles (key_id, profile_id) VALUES (?1, ?2)
                 ON CONFLICT(key_id) DO UPDATE SET profile_id = excluded.profile_id",
                [key_id, profile],
            )
            .map(drop)
            .map_err(|_| "dictionary store unavailable".into())
    }

    /// Make the key its own profile again.
    pub fn unlink(&self, key_id: &str) -> Result<(), String> {
        self.connection()
            .execute("DELETE FROM key_profiles WHERE key_id = ?1", [key_id])
            .map(drop)
            .map_err(|_| "dictionary store unavailable".into())
    }

    /// `(key_id, profile)` for every linked key.
    pub fn links(&self) -> StoreResult<Vec<(String, String)>> {
        let c = self.connection();
        let mut stmt = c.prepare("SELECT key_id, profile_id FROM key_profiles ORDER BY key_id")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect()
    }
}

impl Op {
    fn id(&self) -> &str {
        match self {
            Op::Upsert(e) => &e.id,
            Op::Delete(id) => id,
        }
    }
}

enum Applied {
    Changed,
    Unchanged,
    Rejected(&'static str),
}

/// Schema migrations keyed by `PRAGMA user_version`; append new steps.
fn migrate(c: &Connection) -> StoreResult<()> {
    let version: i64 = c.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version < 1 {
        c.execute_batch(
            "BEGIN;
            CREATE TABLE profiles (id TEXT PRIMARY KEY, revision INTEGER NOT NULL);
            CREATE TABLE key_profiles (key_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL);
            CREATE TABLE entries (
                profile_id TEXT NOT NULL, id TEXT NOT NULL,
                word TEXT NOT NULL, correction TEXT,
                enabled INTEGER NOT NULL, starred INTEGER NOT NULL, source TEXT NOT NULL,
                identity TEXT NOT NULL, position INTEGER NOT NULL, updated_at INTEGER NOT NULL,
                PRIMARY KEY (profile_id, id));
            CREATE UNIQUE INDEX entries_identity ON entries(profile_id, identity);
            PRAGMA user_version = 1;
            COMMIT;",
        )?;
    }
    Ok(())
}

fn profile_of(c: &Connection, key_id: &str) -> StoreResult<String> {
    Ok(c.query_row(
        "SELECT profile_id FROM key_profiles WHERE key_id = ?1",
        [key_id],
        |r| r.get(0),
    )
    .optional()?
    .unwrap_or_else(|| key_id.to_string()))
}

fn row_entry(r: &rusqlite::Row) -> StoreResult<StoredEntry> {
    Ok(StoredEntry {
        id: r.get(0)?,
        word: r.get(1)?,
        correction: r.get(2)?,
        enabled: r.get(3)?,
        starred: r.get(4)?,
        source: r.get(5)?,
        updated_at: r.get(6)?,
    })
}

fn snapshot(c: &Connection, profile: &str) -> StoreResult<Snapshot> {
    let revision = c
        .query_row(
            "SELECT revision FROM profiles WHERE id = ?1",
            [profile],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0);
    let mut stmt = c.prepare(&format!(
        "SELECT {ENTRY_COLUMNS} FROM entries WHERE profile_id = ?1 ORDER BY position"
    ))?;
    let entries = stmt
        .query_map([profile], row_entry)?
        .collect::<StoreResult<_>>()?;
    Ok(Snapshot { revision, entries })
}

/// Word + correction identity, matching the clients' de-duplication.
fn identity(word: &str, correction: Option<&str>) -> String {
    format!(
        "{}\u{1f}{}",
        dedupe_key(word),
        correction.map(dedupe_key).unwrap_or_default()
    )
}

fn apply_one(tx: &Transaction, profile: &str, op: &Op) -> StoreResult<Applied> {
    let e = match op {
        Op::Delete(id) => {
            let n = tx.execute(
                "DELETE FROM entries WHERE profile_id = ?1 AND id = ?2",
                [profile, id],
            )?;
            return Ok(if n > 0 {
                Applied::Changed
            } else {
                Applied::Unchanged
            });
        }
        Op::Upsert(e) => e,
    };
    let identity = identity(&e.word, e.correction.as_deref());
    let owner: Option<String> = tx
        .query_row(
            "SELECT id FROM entries WHERE profile_id = ?1 AND identity = ?2",
            [profile, &identity],
            |r| r.get(0),
        )
        .optional()?;
    if owner.as_deref().is_some_and(|owner| owner != e.id) {
        return Ok(Applied::Rejected("duplicate"));
    }
    let existing = tx
        .query_row(
            &format!("SELECT {ENTRY_COLUMNS} FROM entries WHERE profile_id = ?1 AND id = ?2"),
            [profile, &e.id],
            row_entry,
        )
        .optional()?;
    match existing {
        Some(old) => {
            let same = old.word == e.word
                && old.correction == e.correction
                && old.enabled == e.enabled
                && old.starred == e.starred
                && old.source == e.source;
            if same {
                return Ok(Applied::Unchanged);
            }
            tx.execute(
                "UPDATE entries SET word = ?3, correction = ?4, enabled = ?5, starred = ?6,
                     source = ?7, identity = ?8, updated_at = ?9
                 WHERE profile_id = ?1 AND id = ?2",
                params![
                    profile,
                    e.id,
                    e.word,
                    e.correction,
                    e.enabled,
                    e.starred,
                    e.source,
                    identity,
                    now_ms()
                ],
            )?;
        }
        None => {
            let count: i64 = tx.query_row(
                "SELECT COUNT(*) FROM entries WHERE profile_id = ?1",
                [profile],
                |r| r.get(0),
            )?;
            if count as usize >= MAX_ENTRIES {
                return Ok(Applied::Rejected("limit"));
            }
            tx.execute(
                "INSERT INTO entries (profile_id, id, word, correction, enabled, starred, source,
                     identity, position, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8,
                     (SELECT COALESCE(MAX(position), 0) + 1 FROM entries WHERE profile_id = ?1),
                     ?9)",
                params![
                    profile,
                    e.id,
                    e.word,
                    e.correction,
                    e.enabled,
                    e.starred,
                    e.source,
                    identity,
                    now_ms()
                ],
            )?;
        }
    }
    Ok(Applied::Changed)
}

fn valid_name(s: &str, what: &str) -> Result<(), String> {
    let ok = !s.is_empty()
        && s.len() <= MAX_NAME_CHARS
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    ok.then_some(())
        .ok_or_else(|| format!("{what} must be 1-64 ASCII letters, digits, '-', '_' or '.'"))
}

/// Parse and validate a `POST /v1/dictionary` body:
/// `{"ops": [{"op": "upsert", "entry": {...}} | {"op": "delete", "id": "..."}]}`.
pub fn parse_ops(body: &Map<String, Value>) -> Result<Vec<Op>, String> {
    if body.keys().any(|k| k != "ops") {
        return Err("only `ops` is allowed".into());
    }
    let ops = body
        .get("ops")
        .and_then(Value::as_array)
        .ok_or("ops must be a list")?;
    if ops.len() > MAX_OPS {
        return Err(format!("at most {MAX_OPS} ops per request"));
    }
    ops.iter()
        .enumerate()
        .map(|(i, op)| parse_op(op).map_err(|e| format!("ops[{i}]: {e}")))
        .collect()
}

fn parse_op(op: &Value) -> Result<Op, String> {
    let op = op.as_object().ok_or("must be an object")?;
    let kind = op
        .get("op")
        .and_then(Value::as_str)
        .ok_or("op must be a string")?;
    let only = |allowed: &[&str]| {
        op.keys()
            .all(|k| allowed.contains(&k.as_str()))
            .then_some(())
            .ok_or(format!("{kind} allows only {}", allowed.join(", ")))
    };
    match kind {
        "delete" => {
            only(&["op", "id"])?;
            Ok(Op::Delete(entry_id(op.get("id"))?))
        }
        "upsert" => {
            only(&["op", "entry"])?;
            let e = op
                .get("entry")
                .and_then(Value::as_object)
                .ok_or("entry must be an object")?;
            const FIELDS: [&str; 6] = ["id", "word", "correction", "enabled", "starred", "source"];
            if let Some(k) = e.keys().find(|k| !FIELDS.contains(&k.as_str())) {
                return Err(format!("unknown entry field `{k}`"));
            }
            let word = e
                .get("word")
                .and_then(Value::as_str)
                .ok_or("word must be a string")?;
            let word =
                clean_field(word).ok_or("word must be 1-100 chars with a letter or digit")?;
            let correction = match e.get("correction") {
                None | Some(Value::Null) => None,
                Some(Value::String(c)) if crate::pyu::strip(c).is_empty() => None,
                Some(Value::String(c)) => Some(
                    clean_field(c)
                        .ok_or("correction must be 1-100 chars with a letter or digit")?
                        .to_string(),
                ),
                Some(_) => return Err("correction must be a string or null".into()),
            };
            let flag = |key: &str, default: bool| match e.get(key) {
                None | Some(Value::Null) => Ok(default),
                Some(Value::Bool(b)) => Ok(*b),
                Some(_) => Err(format!("{key} must be true or false")),
            };
            let source = match e.get("source") {
                None | Some(Value::Null) => "manual",
                Some(Value::String(s)) if SOURCES.contains(&s.as_str()) => s.as_str(),
                Some(_) => return Err(format!("source must be one of {}", SOURCES.join(", "))),
            };
            Ok(Op::Upsert(NewEntry {
                id: entry_id(e.get("id"))?,
                word: word.to_string(),
                correction,
                enabled: flag("enabled", true)?,
                starred: flag("starred", false)?,
                source: source.to_string(),
            }))
        }
        _ => Err("op must be upsert or delete".into()),
    }
}

fn entry_id(v: Option<&Value>) -> Result<String, String> {
    let id = v.and_then(Value::as_str).ok_or("id must be a string")?;
    let ok = !id.is_empty()
        && id.len() <= MAX_NAME_CHARS
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    ok.then(|| id.to_string())
        .ok_or_else(|| "id must be 1-64 ASCII letters, digits, '-' or '_'".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ops(v: Value) -> Vec<Op> {
        parse_ops(v.as_object().unwrap()).unwrap()
    }

    fn upsert(id: &str, word: &str, correction: Option<&str>) -> Value {
        json!({"op": "upsert", "entry": {"id": id, "word": word, "correction": correction}})
    }

    #[test]
    fn upsert_update_delete_bump_the_revision_once_per_change() {
        let s = DictionaryStore::in_memory();
        assert_eq!(
            s.snapshot("k1").unwrap(),
            Snapshot {
                revision: 0,
                entries: vec![]
            }
        );

        let (snap, rejected) = s
            .apply("k1", &ops(json!({"ops": [upsert("a", "SHA256", None), upsert("b", "Koolify", Some("koolify"))]})))
            .unwrap();
        assert!(rejected.is_empty());
        assert_eq!(snap.revision, 1);
        let words: Vec<_> = snap.entries.iter().map(|e| e.word.as_str()).collect();
        assert_eq!(words, ["SHA256", "Koolify"]);

        // Re-sending the same entry changes nothing.
        let (snap, _) = s
            .apply("k1", &ops(json!({"ops": [upsert("a", "SHA256", None)]})))
            .unwrap();
        assert_eq!(snap.revision, 1);

        // Editing keeps the position; deleting a missing id is a no-op.
        let (snap, _) = s
            .apply(
                "k1",
                &ops(json!({"ops": [upsert("a", "SHA512", None), {"op": "delete", "id": "zz"}]})),
            )
            .unwrap();
        assert_eq!(snap.revision, 2);
        assert_eq!(snap.entries[0].word, "SHA512");

        let (snap, _) = s
            .apply("k1", &ops(json!({"ops": [{"op": "delete", "id": "a"}]})))
            .unwrap();
        assert_eq!((snap.revision, snap.entries.len()), (3, 1));
    }

    #[test]
    fn duplicates_and_the_entry_limit_are_rejected_per_op() {
        let s = DictionaryStore::in_memory();
        let (snap, rejected) = s
            .apply(
                "k1",
                &ops(json!({"ops": [
                    upsert("a", "Koolify", None),
                    upsert("b", "KOOLIFY", None),
                    upsert("c", "Koolify", Some("koolify")),
                ]})),
            )
            .unwrap();
        assert_eq!(
            snap.entries.len(),
            2,
            "word-only and correction entries are distinct"
        );
        assert_eq!(
            rejected,
            [Rejection {
                index: 1,
                id: "b".into(),
                reason: "duplicate"
            }]
        );

        let many: Vec<Value> = (0..MAX_ENTRIES)
            .map(|i| upsert(&format!("n{i}"), &format!("w{i}"), None))
            .collect();
        let (snap, rejected) = s.apply("k1", &ops(json!({ "ops": many }))).unwrap();
        assert_eq!(snap.entries.len(), MAX_ENTRIES);
        assert_eq!(rejected.len(), 2);
        assert!(rejected.iter().all(|r| r.reason == "limit"));
    }

    #[test]
    fn linked_keys_share_one_profile() {
        let s = DictionaryStore::in_memory();
        s.apply("mac", &ops(json!({"ops": [upsert("a", "Grafana", None)]})))
            .unwrap();
        assert!(s.snapshot("iphone").unwrap().entries.is_empty());

        s.link("iphone", "mac").unwrap();
        assert_eq!(s.profile_of("iphone").unwrap(), "mac");
        assert_eq!(s.snapshot("iphone").unwrap().entries.len(), 1);
        let (dict, revision) = s.compiled("iphone").unwrap();
        assert_eq!(
            (dict.vocabulary(), revision),
            (&["Grafana".to_string()][..], 1)
        );
        assert_eq!(
            s.links().unwrap(),
            [("iphone".to_string(), "mac".to_string())]
        );

        s.unlink("iphone").unwrap();
        assert!(s.snapshot("iphone").unwrap().entries.is_empty());
        assert!(s.link("bad key", "p").is_err());
    }

    #[test]
    fn parse_rejects_bad_shapes_and_values() {
        let bad = [
            json!({}),
            json!({"ops": "x"}),
            json!({"ops": [], "extra": 1}),
            json!({"ops": [{"op": "rename", "id": "a"}]}),
            json!({"ops": [{"op": "delete", "id": "a b"}]}),
            json!({"ops": [{"op": "delete", "id": "a", "word": "x"}]}),
            json!({"ops": [{"op": "upsert", "entry": {"id": "a", "word": "!!!"}}]}),
            json!({"ops": [{"op": "upsert", "entry": {"id": "a", "word": "x", "enabled": "yes"}}]}),
            json!({"ops": [{"op": "upsert", "entry": {"id": "a", "word": "x", "source": "web"}}]}),
            json!({"ops": [{"op": "upsert", "entry": {"id": "a", "word": "x", "usage": 3}}]}),
        ];
        for b in bad {
            assert!(parse_ops(b.as_object().unwrap()).is_err(), "{b}");
        }
        let ok = ops(json!({"ops": [
            {"op": "upsert", "entry": {"id": "a-1", "word": "  สมชาย ", "correction": " ", "starred": true, "source": "autoLearn"}}
        ]}));
        assert_eq!(
            ok,
            [Op::Upsert(NewEntry {
                id: "a-1".into(),
                word: "สมชาย".into(),
                correction: None,
                enabled: true,
                starred: true,
                source: "autoLearn".into(),
            })]
        );
    }
}
