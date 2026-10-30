//! Revocable API keys for the Linux server. Raw keys are never stored here.
//!
//! Store replacement is atomic; authentication opens and validates the current
//! file for every request, so revocation does not require a server restart.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::ffi::{CString, OsStr};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;

const STORE_NAME: &str = "api-keys.json";
const LOCK_NAME: &str = ".api-keys.lock";
const MAX_STORE_BYTES: u64 = 1_048_576;
const MAX_KEYS: usize = 256;
const MAX_HEADER_BYTES: usize = 512;
const SCOPES: [&str; 3] = ["dictate", "clean", "status"];

#[derive(Clone)]
pub struct Auth {
    source: Source,
}

#[derive(Clone)]
enum Source {
    KeyFile(PathBuf),
    Legacy([u8; 32]),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Principal {
    pub id: String,
    pub requests_per_minute: u32,
    pub daily_requests: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthError {
    Unauthorized,
    Forbidden,
    Unavailable,
}

impl Auth {
    pub fn key_file(path: PathBuf) -> Result<Self, String> {
        read_store_path(&path)?;
        Ok(Self {
            source: Source::KeyFile(path),
        })
    }

    /// Explicit private-network migration mode, with bounded default quotas.
    pub fn legacy(token: String) -> Self {
        Self {
            source: Source::Legacy(hash(token.as_bytes())),
        }
    }

    pub fn authenticate(&self, header: Option<&str>, scope: &str) -> Result<Principal, AuthError> {
        self.authenticate_observed(header, scope, &mut None)
    }

    pub(crate) fn authenticate_observed(
        &self,
        header: Option<&str>,
        scope: &str,
        key_id: &mut Option<String>,
    ) -> Result<Principal, AuthError> {
        // Load before inspecting credentials: an unusable store is unavailable,
        // and can never silently fall back to legacy authentication.
        let store = match &self.source {
            Source::KeyFile(path) => {
                Some(read_store_path(path).map_err(|_| AuthError::Unavailable)?)
            }
            Source::Legacy(_) => None,
        };
        let token = header
            .filter(|h| h.len() <= MAX_HEADER_BYTES)
            .and_then(|h| h.strip_prefix("Bearer "))
            .filter(|t| !t.is_empty() && t.bytes().all(|b| b.is_ascii_graphic()))
            .ok_or(AuthError::Unauthorized)?;
        let candidate = hash(token.as_bytes());
        if let Source::Legacy(expected) = &self.source {
            return if bool::from(candidate.ct_eq(expected)) {
                *key_id = Some("legacy".into());
                Ok(Principal {
                    id: "legacy".into(),
                    requests_per_minute: 10,
                    daily_requests: 500,
                })
            } else {
                Err(AuthError::Unauthorized)
            };
        }
        let id = token_id(token).ok_or(AuthError::Unauthorized)?;
        let store = store.ok_or(AuthError::Unavailable)?;
        let record = store
            .keys
            .iter()
            .find(|key| key.info.id == id)
            .ok_or(AuthError::Unauthorized)?;
        let expected = decode_hash(&record.sha256).ok_or(AuthError::Unavailable)?;
        if !bool::from(candidate.ct_eq(&expected)) {
            return Err(AuthError::Unauthorized);
        }
        *key_id = Some(record.info.id.clone());
        if record.info.revoked
            || now().map_err(|_| AuthError::Unavailable)? >= record.info.expires_at
        {
            return Err(AuthError::Unauthorized);
        }
        if !record.info.scopes.iter().any(|s| s == scope) {
            return Err(AuthError::Forbidden);
        }
        Ok(Principal {
            id: record.info.id.clone(),
            requests_per_minute: record.info.requests_per_minute,
            daily_requests: record.info.daily_requests,
        })
    }
}

/// Safe to print: contains neither the raw credential nor its hash.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct KeyInfo {
    pub id: String,
    pub name: String,
    pub created_at: u64,
    pub expires_at: u64,
    pub revoked: bool,
    pub scopes: Vec<String>,
    pub requests_per_minute: u32,
    pub daily_requests: u32,
    /// Issued by the free-trial service. Only these keys can ever be pruned;
    /// absent for every other key, so existing stores keep their exact shape.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub trial: bool,
}

pub struct CreateKey {
    pub name: String,
    pub expires_in_days: u32,
    pub scopes: Vec<String>,
    pub requests_per_minute: u32,
    pub daily_requests: u32,
    pub trial: bool,
}

impl Default for CreateKey {
    fn default() -> Self {
        Self {
            name: String::new(),
            expires_in_days: 90,
            scopes: vec!["dictate".into()],
            requests_per_minute: 10,
            daily_requests: 500,
            trial: false,
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Store {
    version: u32,
    keys: Vec<KeyRecord>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyRecord {
    info: KeyInfo,
    sha256: String,
}

/// Initialize without replacing an existing store or changing its permissions.
pub fn initialize_key_store(root: &Path) -> Result<(), String> {
    let dir = PrivateDir::create(root)?;
    let _lock = dir.lock()?;
    match dir.read_store() {
        Ok(_) => Ok(()),
        Err(StoreReadError::Missing) => dir
            .write_store(&Store {
                version: 1,
                keys: Vec::new(),
            })
            .map_err(|e| e.message),
        Err(StoreReadError::Invalid(e)) => Err(e),
    }
}

pub fn list_keys(root: &Path) -> Result<Vec<KeyInfo>, String> {
    Ok(PrivateDir::open(root)?
        .read_store()
        .map_err(StoreReadError::message)?
        .keys
        .into_iter()
        .map(|key| key.info)
        .collect())
}

/// Write the credential to a new private file before committing its hash.
/// Failed exports never create a usable key; existing output is never replaced.
pub fn create_key(root: &Path, options: CreateKey, out: &Path) -> Result<KeyInfo, String> {
    let created_at = now()?;
    if !(1..=3650).contains(&options.expires_in_days) {
        return Err("expires-in-days must be between 1 and 3650".into());
    }
    let mut info = KeyInfo {
        id: random_hex::<8>()?,
        name: options.name,
        created_at,
        expires_at: created_at + u64::from(options.expires_in_days) * 86_400,
        revoked: false,
        scopes: options.scopes,
        requests_per_minute: options.requests_per_minute,
        daily_requests: options.daily_requests,
        trial: options.trial,
    };
    validate_info(&info)?;
    let dir = PrivateDir::open(root)?;
    let _lock = dir.lock()?;
    let mut store = dir.read_store().map_err(StoreReadError::message)?;
    if store.keys.len() >= MAX_KEYS {
        return Err("key store is full (including revoked keys)".into());
    }
    while store.keys.iter().any(|key| key.info.id == info.id) {
        info.id = random_hex::<8>()?;
    }
    let raw = format!("oliv_{}_{}", info.id, random_hex::<32>()?);
    store.keys.push(KeyRecord {
        info: info.clone(),
        sha256: hex(&hash(raw.as_bytes())),
    });
    let (out_dir, out_name) = PrivateDir::parent(out)?;
    let mut output = out_dir.create_file(&out_name)?;
    let export_result = (|| {
        output
            .write_all(format!("{raw}\n").as_bytes())
            .and_then(|()| output.sync_all())
            .map_err(|_| "could not write the private key output file".to_string())?;
        // Ensure the output directory is writable/durable before the store can
        // reference the exported credential.
        out_dir
            .file
            .sync_all()
            .map_err(|_| "could not sync the key output directory".to_string())?;
        Ok(())
    })();
    let write_result = export_result
        .map_err(|message| StoreWriteError {
            message,
            committed: false,
        })
        .and_then(|()| dir.write_store(&store));
    if let Err(error) = write_result {
        if error.committed {
            return Err(format!(
                "key {} was committed but durability could not be confirmed; the private output was retained; inspect or revoke this ID",
                info.id
            ));
        }
        // Only our newly-created inode may be removed. Never follow or remove
        // a replacement symlink/file supplied by another process.
        if out_dir.remove_created_file(&out_name, &output).is_err() {
            return Err(format!(
                "{}; could not remove the unused private output file",
                error.message
            ));
        }
        return Err(error.message);
    }
    Ok(info)
}

pub fn revoke_key(root: &Path, id: &str) -> Result<(), String> {
    if !is_hex(id, 16) {
        return Err("invalid key ID".into());
    }
    let dir = PrivateDir::open(root)?;
    let _lock = dir.lock()?;
    let mut store = dir.read_store().map_err(StoreReadError::message)?;
    let key = store
        .keys
        .iter_mut()
        .find(|key| key.info.id == id)
        .ok_or_else(|| "unknown key ID".to_string())?;
    key.info.revoked = true;
    dir.write_store(&store).map_err(|e| e.message)
}

/// Removes trial keys that stopped working at least `grace_days` ago, so public
/// sign-ups can't fill the store (revoked keys count towards `MAX_KEYS`). Only
/// keys created as trials qualify, whatever any other key is called.
pub fn prune_trial_keys(root: &Path, grace_days: u32) -> Result<usize, String> {
    let cutoff = now()?.saturating_sub(u64::from(grace_days) * 86_400);
    let dir = PrivateDir::open(root)?;
    let _lock = dir.lock()?;
    let mut store = dir.read_store().map_err(StoreReadError::message)?;
    let before = store.keys.len();
    store
        .keys
        .retain(|key| !(key.info.trial && (key.info.revoked || key.info.expires_at <= cutoff)));
    let removed = before - store.keys.len();
    if removed > 0 {
        dir.write_store(&store).map_err(|e| e.message)?;
    }
    Ok(removed)
}

fn now() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|t| t.as_secs())
        .map_err(|_| "system clock is before the Unix epoch".into())
}

fn hash(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn random_hex<const N: usize>() -> Result<String, String> {
    let mut bytes = [0; N];
    getrandom::getrandom(&mut bytes).map_err(|_| "secure random source unavailable".to_string())?;
    Ok(hex(&bytes))
}

fn is_hex(text: &str, len: usize) -> bool {
    text.len() == len
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn decode_hash(text: &str) -> Option<[u8; 32]> {
    if !is_hex(text, 64) {
        return None;
    }
    let mut bytes = [0; 32];
    for (index, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).ok()?;
    }
    Some(bytes)
}

fn token_id(token: &str) -> Option<&str> {
    let (id, secret) = token.strip_prefix("oliv_")?.split_once('_')?;
    (is_hex(id, 16) && is_hex(secret, 64)).then_some(id)
}

fn validate_info(info: &KeyInfo) -> Result<(), String> {
    if !is_hex(&info.id, 16)
        || info.name.trim().is_empty()
        || info.name.len() > 120
        || info.name.chars().any(char::is_control)
        || info.expires_at <= info.created_at
        || info.scopes.is_empty()
        || info.scopes.len() > SCOPES.len()
        || !info.scopes.iter().all(|s| SCOPES.contains(&s.as_str()))
        || info.scopes.iter().collect::<HashSet<_>>().len() != info.scopes.len()
        || !(1..=10_000).contains(&info.requests_per_minute)
        || !(1..=1_000_000).contains(&info.daily_requests)
    {
        return Err("invalid key metadata, scopes, expiry, or request limits".into());
    }
    Ok(())
}

fn validate_store(store: &Store) -> Result<(), String> {
    if store.version != 1 || store.keys.len() > MAX_KEYS {
        return Err("unsupported or oversized key store".into());
    }
    let mut ids = HashSet::new();
    let mut hashes = HashSet::new();
    for key in &store.keys {
        validate_info(&key.info)?;
        if !is_hex(&key.sha256, 64) || !ids.insert(&key.info.id) || !hashes.insert(&key.sha256) {
            return Err("invalid or duplicate key record".into());
        }
    }
    Ok(())
}

fn read_store_path(path: &Path) -> Result<Store, String> {
    let (dir, name) = PrivateDir::parent(path)?;
    dir.read_named_store(&name).map_err(StoreReadError::message)
}

enum StoreReadError {
    Missing,
    Invalid(String),
}

struct StoreWriteError {
    message: String,
    committed: bool,
}

impl StoreReadError {
    fn message(self) -> String {
        match self {
            Self::Missing => "key store is missing; run oliv-keys init first".into(),
            Self::Invalid(message) => message,
        }
    }
}

/// Directory handles keep all mutations anchored even if a pathname is renamed.
/// Symlinks are rejected in every path component, not just the final file.
struct PrivateDir {
    file: File,
}

impl PrivateDir {
    fn open(path: &Path) -> Result<Self, String> {
        let dir = Self::traverse(path)?;
        let meta = dir
            .file
            .metadata()
            .map_err(|_| "could not inspect key directory".to_string())?;
        // SAFETY: geteuid has no arguments and no preconditions.
        if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o022 != 0 {
            return Err(
                "key directory must be owned by this user and not writable by others".into(),
            );
        }
        Ok(dir)
    }

    fn traverse(path: &Path) -> Result<Self, String> {
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()
                .map_err(|_| "could not resolve current directory".to_string())?
                .join(path)
        };
        let mut dir = File::open("/").map_err(|_| "could not open filesystem root".to_string())?;
        for part in absolute.components() {
            match part {
                Component::RootDir | Component::CurDir => continue,
                Component::Normal(name) => {
                    let child = open_at(
                        &dir,
                        name,
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
                        0,
                    )
                    .map_err(|_| {
                        "directory is missing, inaccessible, or contains a symlink".to_string()
                    })?;
                    let meta = child
                        .metadata()
                        .map_err(|_| "could not inspect directory".to_string())?;
                    // A different owner could rename a private descendant even
                    // without group/other write bits on their own directory.
                    // SAFETY: geteuid has no preconditions.
                    if meta.uid() != 0 && meta.uid() != unsafe { libc::geteuid() } {
                        return Err("key path contains a directory owned by another user".into());
                    }
                    // Root-owned sticky directories such as /tmp are safe
                    // ancestors: another user cannot replace our private child.
                    if meta.mode() & 0o022 != 0 && !(meta.uid() == 0 && meta.mode() & 0o1000 != 0) {
                        return Err("key path has a directory writable by other users".into());
                    }
                    dir = child;
                }
                _ => return Err("key paths must not contain parent-directory components".into()),
            }
        }
        Ok(Self { file: dir })
    }

    fn parent(path: &Path) -> Result<(Self, std::ffi::OsString), String> {
        let name = path
            .file_name()
            .ok_or_else(|| "expected a key file path".to_string())?;
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        Ok((Self::open(parent)?, name.to_os_string()))
    }

    fn create(path: &Path) -> Result<Self, String> {
        if let Ok(dir) = Self::open(path) {
            return Ok(dir);
        }
        let name = c_name(
            path.file_name()
                .ok_or_else(|| "expected a key directory path".to_string())?,
        )?;
        let parent_path = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        // A root-owned sticky parent (/tmp) may hold a newly-created private
        // root, but is never accepted as a key/output directory itself.
        let parent = Self::traverse(parent_path)?;
        // SAFETY: parent is an open directory and name is a NUL-terminated component.
        if unsafe { libc::mkdirat(parent.file.as_raw_fd(), name.as_ptr(), 0o700) } != 0
            && std::io::Error::last_os_error().kind() != std::io::ErrorKind::AlreadyExists
        {
            return Err("could not create private key directory".into());
        }
        Self::open(path)
    }

    fn create_file(&self, name: &OsStr) -> Result<File, String> {
        let file = open_at(
            &self.file,
            name,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW,
            0o600,
        )
        .map_err(|_| {
            "could not create a new private file (output must not already exist)".to_string()
        })?;
        // Creation never grants group/other access. Restore owner access if a
        // restrictive umask removed it; existing files are never chmodded.
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "could not set private file permissions".to_string())?;
        validate_file(&file)?;
        Ok(file)
    }

    fn lock(&self) -> Result<File, String> {
        let file = match open_at(
            &self.file,
            OsStr::new(LOCK_NAME),
            libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            0o600,
        ) {
            Ok(file) => {
                file.set_permissions(std::fs::Permissions::from_mode(0o600))
                    .map_err(|_| "could not set key lock permissions".to_string())?;
                file
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => open_at(
                &self.file,
                OsStr::new(LOCK_NAME),
                libc::O_RDWR | libc::O_NOFOLLOW | libc::O_NONBLOCK,
                0,
            )
            .map_err(|_| "could not safely open existing key store lock".to_string())?,
            Err(_) => return Err("could not create key store lock".into()),
        };
        validate_file(&file)?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match fs2::FileExt::try_lock_exclusive(&file) {
                Ok(()) => return Ok(file),
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => return Err("key store is locked or unavailable".into()),
            }
        }
    }

    fn read_store(&self) -> Result<Store, StoreReadError> {
        self.read_named_store(OsStr::new(STORE_NAME))
    }

    fn read_named_store(&self, name: &OsStr) -> Result<Store, StoreReadError> {
        let file = open_at(
            &self.file,
            name,
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            0,
        )
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                StoreReadError::Missing
            } else {
                StoreReadError::Invalid("could not safely open key store".into())
            }
        })?;
        validate_file(&file).map_err(StoreReadError::Invalid)?;
        let mut bytes = Vec::new();
        file.take(MAX_STORE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| StoreReadError::Invalid("could not read key store".into()))?;
        if bytes.len() as u64 > MAX_STORE_BYTES {
            return Err(StoreReadError::Invalid(
                "key store exceeds size limit".into(),
            ));
        }
        // Parsing errors deliberately omit serde's input-dependent messages.
        let store: Store = serde_json::from_slice(&bytes)
            .map_err(|_| StoreReadError::Invalid("key store is malformed".into()))?;
        validate_store(&store).map_err(StoreReadError::Invalid)?;
        Ok(store)
    }

    fn write_store(&self, store: &Store) -> Result<(), StoreWriteError> {
        let mut committed = false;
        let mut temporary = None;
        let result = (|| {
            validate_store(store)?;
            let bytes = serde_json::to_vec_pretty(store)
                .map_err(|_| "could not encode key store".to_string())?;
            if bytes.len() as u64 > MAX_STORE_BYTES {
                return Err("key store exceeds size limit".into());
            }
            let name = format!(".api-keys.{}.tmp", random_hex::<16>()?);
            let mut file = self.create_file(OsStr::new(&name))?;
            temporary = Some((
                name.clone(),
                file.try_clone()
                    .map_err(|_| "could not retain temporary file handle".to_string())?,
            ));
            file.write_all(&bytes)
                .and_then(|()| file.sync_all())
                .map_err(|_| "could not write key store".to_string())?;
            self.file
                .sync_all()
                .map_err(|_| "could not sync key directory".to_string())?;
            let from = c_name(OsStr::new(&name))?;
            let to = c_name(OsStr::new(STORE_NAME))?;
            // SAFETY: both names are components relative to the held directory.
            if unsafe {
                libc::renameat(
                    self.file.as_raw_fd(),
                    from.as_ptr(),
                    self.file.as_raw_fd(),
                    to.as_ptr(),
                )
            } != 0
            {
                return Err("could not atomically replace key store".into());
            }
            committed = true;
            self.file.sync_all().map_err(|_| {
                "key store was committed but directory durability could not be confirmed"
                    .to_string()
            })?;
            Ok(())
        })();
        if result.is_err()
            && !committed
            && let Some((name, file)) = temporary
        {
            let _ = self.remove_created_file(OsStr::new(&name), &file);
        }
        result.map_err(|message| StoreWriteError { message, committed })
    }

    fn remove_created_file(&self, name: &OsStr, created: &File) -> Result<(), String> {
        let file = open_at(
            &self.file,
            name,
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            0,
        )
        .map_err(|_| "could not open private file for removal".to_string())?;
        validate_file(&file)?;
        let current = file
            .metadata()
            .map_err(|_| "could not inspect cleanup file".to_string())?;
        let original = created
            .metadata()
            .map_err(|_| "could not inspect original file".to_string())?;
        if current.dev() != original.dev() || current.ino() != original.ino() {
            return Err("private output file was replaced; refusing removal".into());
        }
        let name = c_name(name)?;
        // SAFETY: valid held directory and NUL-terminated filename.
        if unsafe { libc::unlinkat(self.file.as_raw_fd(), name.as_ptr(), 0) } != 0 {
            return Err("could not remove private file".into());
        }
        Ok(())
    }
}

fn c_name(name: &OsStr) -> Result<CString, String> {
    if name.as_bytes().contains(&b'/') || name == "." || name == ".." {
        return Err("expected a single filename".into());
    }
    CString::new(name.as_bytes()).map_err(|_| "filename contains NUL".into())
}

fn open_at(dir: &File, name: &OsStr, flags: i32, mode: libc::mode_t) -> std::io::Result<File> {
    let name = c_name(name).map_err(std::io::Error::other)?;
    // SAFETY: openat receives an owned directory descriptor, a valid C string,
    // and mode when creation flags need it. Successful descriptors are owned.
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_CLOEXEC,
            mode,
        )
    };
    if fd < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        // SAFETY: fd is newly created by openat and not owned elsewhere.
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

fn validate_file(file: &File) -> Result<(), String> {
    let meta = file
        .metadata()
        .map_err(|_| "could not inspect private file".to_string())?;
    // SAFETY: geteuid has no preconditions.
    if !meta.is_file()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o777 != 0o600
        || meta.nlink() != 1
    {
        return Err(
            "key files must be regular, owned by this user, mode 600, and not hard-linked".into(),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    #[test]
    fn prune_removes_only_finished_trial_keys() {
        let fixture = Fixture::new();
        // The last two only look like trials: the name carries no authority.
        for (name, trial) in [
            ("old", true),
            ("recent", true),
            ("live", true),
            ("revoked", true),
            ("trial-expired-operator", false),
            ("trial-revoked-operator", false),
        ] {
            let options = CreateKey {
                name: name.into(),
                trial,
                ..CreateKey::default()
            };
            create_key(&fixture.0, options, &fixture.0.join(format!("{name}.key"))).unwrap();
        }
        let keys = list_keys(&fixture.0).unwrap();
        revoke_key(&fixture.0, &keys[3].id).unwrap();
        revoke_key(&fixture.0, &keys[5].id).unwrap();
        let today = now().unwrap();
        fixture.edit(|store| {
            for (index, age_days) in [(0, 40), (1, 5), (4, 40)] {
                store["keys"][index]["info"]["created_at"] = 1.into();
                store["keys"][index]["info"]["expires_at"] = (today - age_days * 86_400).into();
            }
        });
        assert_eq!(prune_trial_keys(&fixture.0, 30).unwrap(), 2);
        let names: Vec<_> = list_keys(&fixture.0)
            .unwrap()
            .into_iter()
            .map(|key| key.name)
            .collect();
        assert_eq!(
            names,
            [
                "recent",
                "live",
                "trial-expired-operator",
                "trial-revoked-operator"
            ]
        );
        assert_eq!(prune_trial_keys(&fixture.0, 30).unwrap(), 0);
    }

    #[test]
    fn non_trial_keys_keep_their_stored_shape() {
        let fixture = Fixture::new();
        let out = fixture.0.join("a.key");
        create_key(
            &fixture.0,
            CreateKey {
                name: "a".into(),
                ..CreateKey::default()
            },
            &out,
        )
        .unwrap();
        let stored = std::fs::read_to_string(fixture.0.join(STORE_NAME)).unwrap();
        assert!(!stored.contains("\"trial\""));
    }

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .join(format!("oliv-keys-test-{}", random_hex::<12>().unwrap()));
            // temp_dir commonly resolves to a symlink on some systems. These
            // server tests intentionally use the actual filesystem directory.
            let path = path
                .parent()
                .unwrap()
                .canonicalize()
                .unwrap()
                .join(path.file_name().unwrap());
            initialize_key_store(&path).unwrap();
            Self(path)
        }

        fn auth(&self) -> Auth {
            Auth::key_file(self.0.join(STORE_NAME)).unwrap()
        }

        fn create(&self, name: &str) -> (KeyInfo, String) {
            let out = self.0.join(format!("{name}.key"));
            let info = create_key(
                &self.0,
                CreateKey {
                    name: name.into(),
                    ..CreateKey::default()
                },
                &out,
            )
            .unwrap();
            (
                info,
                format!("Bearer {}", std::fs::read_to_string(out).unwrap().trim()),
            )
        }

        fn edit(&self, edit: impl FnOnce(&mut serde_json::Value)) {
            let path = self.0.join(STORE_NAME);
            let mut value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            edit(&mut value);
            std::fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn auth_scope_expiry_revocation_and_reload() {
        let fixture = Fixture::new();
        let auth = fixture.auth();
        let (info, header) = fixture.create("alice");
        assert_eq!(
            auth.authenticate(Some(&header), "dictate").unwrap().id,
            info.id
        );
        assert_eq!(
            auth.authenticate(Some(&header), "clean"),
            Err(AuthError::Forbidden)
        );
        assert_eq!(
            auth.authenticate(Some(&header), "status"),
            Err(AuthError::Forbidden)
        );
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unauthorized)
        );
        let incorrect = format!("Bearer oliv_{}_{}", info.id, "0".repeat(64));
        assert_eq!(
            auth.authenticate(Some(&incorrect), "dictate"),
            Err(AuthError::Unauthorized)
        );
        fixture.edit(|store| {
            store["keys"][0]["info"]["created_at"] = 1.into();
            store["keys"][0]["info"]["expires_at"] = 2.into();
        });
        assert_eq!(
            auth.authenticate(Some(&header), "dictate"),
            Err(AuthError::Unauthorized)
        );
        fixture
            .edit(|store| store["keys"][0]["info"]["expires_at"] = (now().unwrap() + 600).into());
        assert!(auth.authenticate(Some(&header), "dictate").is_ok());
        revoke_key(&fixture.0, &info.id).unwrap();
        assert_eq!(
            auth.authenticate(Some(&header), "dictate"),
            Err(AuthError::Unauthorized)
        );
        revoke_key(&fixture.0, &info.id).unwrap();
        assert!(list_keys(&fixture.0).unwrap()[0].revoked);
    }

    #[test]
    fn auth_fails_closed_on_store_damage_and_recovers_after_replacement() {
        let fixture = Fixture::new();
        let (_, header) = fixture.create("alice");
        let auth = fixture.auth();
        let path = fixture.0.join(STORE_NAME);
        let original = std::fs::read(&path).unwrap();
        for bad in [
            b"{broken".as_slice(),
            b"{\"version\":1,\"keys\":[],\"unexpected\":true}",
        ] {
            std::fs::write(&path, bad).unwrap();
            assert_eq!(
                auth.authenticate(Some(&header), "dictate"),
                Err(AuthError::Unavailable)
            );
            assert!(Auth::key_file(path.clone()).is_err());
        }
        std::fs::write(&path, &original).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            auth.authenticate(Some(&header), "dictate"),
            Err(AuthError::Unavailable)
        );
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(auth.authenticate(Some(&header), "dictate").is_ok());
        std::fs::remove_file(&path).unwrap();
        assert_eq!(
            auth.authenticate(Some(&header), "dictate"),
            Err(AuthError::Unavailable)
        );
        initialize_key_store(&fixture.0).unwrap();
        assert_eq!(
            auth.authenticate(Some(&header), "dictate"),
            Err(AuthError::Unauthorized)
        );
    }

    #[test]
    fn secrets_are_only_in_private_new_output_and_not_metadata_or_store() {
        let fixture = Fixture::new();
        let (info, header) = fixture.create("alice");
        let raw = header.strip_prefix("Bearer ").unwrap();
        let store = std::fs::read_to_string(fixture.0.join(STORE_NAME)).unwrap();
        let listed = serde_json::to_string(&list_keys(&fixture.0).unwrap()).unwrap();
        assert!(!store.contains(raw));
        assert!(!listed.contains(raw));
        assert!(!listed.contains("sha256"));
        assert!(store.contains(&hex(&hash(raw.as_bytes()))));
        assert_eq!(raw.len(), 5 + 16 + 1 + 64);
        assert_eq!(info.expires_at - info.created_at, 90 * 86_400);
        for path in [STORE_NAME, LOCK_NAME, "alice.key"] {
            assert_eq!(
                std::fs::metadata(fixture.0.join(path)).unwrap().mode() & 0o777,
                0o600
            );
        }
        let before = std::fs::read(fixture.0.join(STORE_NAME)).unwrap();
        assert!(
            create_key(
                &fixture.0,
                CreateKey {
                    name: "collision".into(),
                    ..CreateKey::default()
                },
                &fixture.0.join("alice.key")
            )
            .is_err()
        );
        assert_eq!(std::fs::read(fixture.0.join(STORE_NAME)).unwrap(), before);
        initialize_key_store(&fixture.0).unwrap();
        assert_eq!(std::fs::read(fixture.0.join(STORE_NAME)).unwrap(), before);
    }

    #[test]
    fn rejects_symlinks_hard_links_and_writable_directories() {
        let fixture = Fixture::new();
        let auth = fixture.auth();
        let path = fixture.0.join(STORE_NAME);
        std::fs::rename(&path, fixture.0.join("original")).unwrap();
        symlink("original", &path).unwrap();
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unavailable)
        );
        assert!(initialize_key_store(&fixture.0).is_err());
        std::fs::remove_file(&path).unwrap();
        std::fs::hard_link(fixture.0.join("original"), &path).unwrap();
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unavailable)
        );
        std::fs::remove_file(fixture.0.join("original")).unwrap();
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unauthorized)
        );
        let linked = fixture.0.join("linked");
        symlink(&fixture.0, &linked).unwrap();
        assert!(Auth::key_file(linked.join(STORE_NAME)).is_err());
        assert!(
            create_key(
                &fixture.0,
                CreateKey {
                    name: "link".into(),
                    ..CreateKey::default()
                },
                &linked.join("out.key")
            )
            .is_err()
        );
        assert!(!fixture.0.join("out.key").exists());
        std::fs::set_permissions(&fixture.0, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unavailable)
        );
        std::fs::set_permissions(&fixture.0, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn malformed_oversized_and_duplicate_records_are_unavailable() {
        let fixture = Fixture::new();
        let auth = fixture.auth();
        let path = fixture.0.join(STORE_NAME);
        std::fs::write(&path, vec![b' '; MAX_STORE_BYTES as usize + 1]).unwrap();
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unavailable)
        );
        std::fs::remove_file(&path).unwrap();
        initialize_key_store(&fixture.0).unwrap();
        fixture.create("one");
        fixture.edit(|store| {
            let key = store["keys"][0].clone();
            store["keys"].as_array_mut().unwrap().push(key);
        });
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unavailable)
        );
        fixture.edit(|store| {
            store["keys"].as_array_mut().unwrap().pop();
            store["keys"][0]["sha256"] = "invalid".into();
        });
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unavailable)
        );
    }

    #[test]
    fn parallel_creates_preserve_every_key_and_revoke_is_immediate() {
        let fixture = Fixture::new();
        let auth = fixture.auth();
        let handles: Vec<_> = (0..12)
            .map(|index| {
                let root = fixture.0.clone();
                std::thread::spawn(move || {
                    create_key(
                        &root,
                        CreateKey {
                            name: format!("alice-{index}"),
                            ..CreateKey::default()
                        },
                        &root.join(format!("{index}.key")),
                    )
                    .unwrap()
                })
            })
            .collect();
        let keys: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        assert_eq!(list_keys(&fixture.0).unwrap().len(), 12);
        for (index, info) in keys.iter().enumerate() {
            let token = std::fs::read_to_string(fixture.0.join(format!("{index}.key"))).unwrap();
            let header = format!("Bearer {}", token.trim());
            assert_eq!(
                auth.authenticate(Some(&header), "dictate").unwrap().id,
                info.id
            );
            revoke_key(&fixture.0, &info.id).unwrap();
            assert_eq!(
                auth.authenticate(Some(&header), "dictate"),
                Err(AuthError::Unauthorized)
            );
        }
    }

    #[test]
    fn rejects_invalid_creation_before_writing_output() {
        let fixture = Fixture::new();
        for options in [
            CreateKey {
                name: "bad\nname".into(),
                ..CreateKey::default()
            },
            CreateKey {
                name: "alice".into(),
                scopes: vec!["admin".into()],
                ..CreateKey::default()
            },
            CreateKey {
                name: "alice".into(),
                scopes: vec!["dictate".into(), "dictate".into()],
                ..CreateKey::default()
            },
            CreateKey {
                name: "alice".into(),
                expires_in_days: 0,
                ..CreateKey::default()
            },
            CreateKey {
                name: "alice".into(),
                requests_per_minute: 0,
                ..CreateKey::default()
            },
        ] {
            assert!(create_key(&fixture.0, options, &fixture.0.join("out")).is_err());
            assert!(!fixture.0.join("out").exists());
            assert!(list_keys(&fixture.0).unwrap().is_empty());
        }
    }

    #[test]
    fn failed_atomic_replace_cleans_up_and_does_not_touch_target() {
        let fixture = Fixture::new();
        std::fs::remove_file(fixture.0.join(STORE_NAME)).unwrap();
        std::fs::create_dir(fixture.0.join(STORE_NAME)).unwrap();
        let result = PrivateDir::open(&fixture.0).unwrap().write_store(&Store {
            version: 1,
            keys: vec![],
        });
        assert!(result.is_err_and(|e| !e.committed));
        assert!(fixture.0.join(STORE_NAME).is_dir());
        assert_eq!(std::fs::read_dir(&fixture.0).unwrap().count(), 2);
    }

    #[test]
    fn legacy_is_explicit_and_limited() {
        let auth = Auth::legacy("private-migration-test-token".into());
        let principal = auth
            .authenticate(Some("Bearer private-migration-test-token"), "status")
            .unwrap();
        assert_eq!(principal.requests_per_minute, 10);
        assert_eq!(principal.daily_requests, 500);
        assert_eq!(
            auth.authenticate(Some("Bearer wrong"), "dictate"),
            Err(AuthError::Unauthorized)
        );
        assert_eq!(
            auth.authenticate(Some("Bearer "), "dictate"),
            Err(AuthError::Unauthorized)
        );
    }

    #[test]
    fn fifo_store_is_rejected_without_waiting_for_a_writer() {
        let fixture = Fixture::new();
        let auth = fixture.auth();
        let path = fixture.0.join(STORE_NAME);
        std::fs::remove_file(&path).unwrap();
        let path = CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: path is a valid NUL-terminated pathname in our disposable dir.
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unavailable)
        );
    }

    #[test]
    fn excessive_record_count_is_rejected_even_within_byte_limit() {
        let fixture = Fixture::new();
        fixture.create("first");
        let auth = fixture.auth();
        fixture.edit(|store| {
            let record = store["keys"][0].clone();
            let keys = store["keys"].as_array_mut().unwrap();
            for index in 1..=MAX_KEYS {
                let mut key = record.clone();
                key["info"]["id"] = format!("{index:016x}").into();
                key["sha256"] = format!("{index:064x}").into();
                keys.push(key);
            }
        });
        assert!(std::fs::metadata(fixture.0.join(STORE_NAME)).unwrap().len() < MAX_STORE_BYTES);
        assert_eq!(
            auth.authenticate(None, "dictate"),
            Err(AuthError::Unavailable)
        );
    }
}
