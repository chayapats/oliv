//! Client-side files: `~/.local/state/oliv/` (history.jsonl, pending/*.wav)
//! and `$XDG_RUNTIME_DIR` (the socket and the request lock).

use std::fs::{File, OpenOptions};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use serde_json::Value;

/// history.jsonl keeps the newest `HISTORY_KEEP` entries. It is trimmed only
/// once it passes `HISTORY_TRIM_AT`, so most appends don't rewrite the file.
pub const HISTORY_KEEP: usize = 1000;
pub const HISTORY_TRIM_AT: usize = 1200;

#[cfg(unix)]
pub fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".into())
}

#[cfg(windows)]
pub fn env_dir(name: &str) -> Result<PathBuf, String> {
    std::env::var_os(name)
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .filter(|d| d.is_absolute())
        .ok_or_else(|| format!("{name} must be an absolute directory"))
}

pub fn state_dir() -> Result<PathBuf, String> {
    #[cfg(windows)]
    let base = env_dir("LOCALAPPDATA")?;
    #[cfg(unix)]
    let base = match std::env::var_os("XDG_STATE_HOME") {
        Some(d) if !d.is_empty() => PathBuf::from(d),
        _ => home()?.join(".local/state"),
    };
    Ok(base.join("oliv"))
}

#[cfg(unix)]
pub fn runtime_dir() -> Result<PathBuf, String> {
    std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| "XDG_RUNTIME_DIR is not set".into())
}

#[cfg(windows)]
pub fn runtime_dir() -> Result<PathBuf, String> {
    let dir = state_dir()?.join("run");
    private_dir(&dir)?;
    Ok(dir)
}

#[cfg(windows)]
pub fn socket_path() -> Result<PathBuf, String> {
    crate::transport::pipe_path()
}

#[cfg(unix)]
pub fn socket_path() -> Result<PathBuf, String> {
    Ok(runtime_dir()?.join("oliv.sock"))
}

pub fn pending_dir() -> Result<PathBuf, String> {
    Ok(state_dir()?.join("pending"))
}

pub fn history_path() -> Result<PathBuf, String> {
    Ok(state_dir()?.join("history.jsonl"))
}

/// Recorded speech is private: directories 700, files 600.
#[cfg(unix)]
fn private_dir(dir: &Path) -> Result<(), String> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))
}

#[cfg(windows)]
fn private_dir(dir: &Path) -> Result<(), String> {
    crate::security::private_dir(dir)
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    options.mode(0o600);
    // Files inherit the protected user-only ACL of their directory on Windows.
    options.write(true);
    options
}

/// An exclusive lock held for as long as the value lives. oliv-api serves one
/// request at a time, so the daemon and `oliv retry` both take `oliv.lock`
/// around each request; history writes take `history.lock`.
pub struct Lock(#[allow(dead_code)] File);

pub fn lock(path: &Path) -> Result<Lock, String> {
    let f = private_options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    f.lock()
        .map_err(|e| format!("lock {}: {e}", path.display()))?;
    Ok(Lock(f))
}

pub fn request_lock() -> Result<Lock, String> {
    lock(&runtime_dir()?.join("oliv.lock"))
}

/// Shared across daemon/CLI and process restarts. Contains only an epoch time,
/// never a key. Conservative per-user cooldown also applies after config changes.
fn epoch_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn check_cooldown() -> Result<(), String> {
    let path = state_dir()?.join("retry-after");
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("cannot read API cooldown: {e}")),
    };
    let until: u64 = text
        .trim()
        .parse()
        .map_err(|_| "invalid API cooldown file")?;
    let remaining = until.saturating_sub(epoch_seconds());
    if remaining > 0 {
        return Err(format!(
            "API cooldown: wait {remaining} seconds before oliv retry (audio kept)"
        ));
    }
    Ok(())
}

pub fn save_cooldown(delay: std::time::Duration) -> Result<(), String> {
    let dir = state_dir()?;
    private_dir(&dir)?;
    let tmp = dir.join("retry-after.tmp");
    let until = epoch_seconds()
        .saturating_add(delay.as_secs())
        .saturating_add(1);
    private_options()
        .create(true)
        .truncate(true)
        .open(&tmp)
        .and_then(|mut f| {
            write!(f, "{until}")?;
            f.sync_all()
        })
        .and_then(|_| std::fs::rename(tmp, dir.join("retry-after")))
        .map_err(|e| format!("cannot save API cooldown: {e}"))
}

// ---- local time -------------------------------------------------------------

/// Broken-down local time with its UTC offset in seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Stamp {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub min: u32,
    pub sec: u32,
    pub millis: u32,
    pub offset: i64,
}

impl Stamp {
    #[cfg(unix)]
    pub fn now() -> Stamp {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let secs = t.as_secs() as libc::time_t;
        // SAFETY: localtime_r only writes the `tm` we hand it.
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        unsafe { libc::localtime_r(&secs, &mut tm) };
        Stamp {
            year: tm.tm_year + 1900,
            month: (tm.tm_mon + 1) as u32,
            day: tm.tm_mday as u32,
            hour: tm.tm_hour as u32,
            min: tm.tm_min as u32,
            sec: tm.tm_sec as u32,
            millis: t.subsec_millis(),
            offset: tm.tm_gmtoff,
        }
    }

    #[cfg(windows)]
    pub fn now() -> Stamp {
        use windows_sys::Win32::Foundation::{FILETIME, SYSTEMTIME};
        use windows_sys::Win32::System::SystemInformation::GetSystemTime;
        use windows_sys::Win32::System::Time::{
            SystemTimeToFileTime, SystemTimeToTzSpecificLocalTime,
        };
        let mut utc: SYSTEMTIME = unsafe { std::mem::zeroed() };
        let mut local: SYSTEMTIME = unsafe { std::mem::zeroed() };
        // SAFETY: all output pointers reference initialized, correctly sized structs.
        unsafe {
            GetSystemTime(&mut utc);
            if SystemTimeToTzSpecificLocalTime(std::ptr::null(), &utc, &mut local) == 0 {
                local = utc;
            }
        }
        let ticks = |st: &SYSTEMTIME| {
            let mut ft: FILETIME = unsafe { std::mem::zeroed() };
            unsafe { SystemTimeToFileTime(st, &mut ft) };
            ((u64::from(ft.dwHighDateTime) << 32) | u64::from(ft.dwLowDateTime)) as i64
        };
        Stamp {
            year: i32::from(local.wYear),
            month: u32::from(local.wMonth),
            day: u32::from(local.wDay),
            hour: u32::from(local.wHour),
            min: u32::from(local.wMinute),
            sec: u32::from(local.wSecond),
            millis: u32::from(local.wMilliseconds),
            offset: (ticks(&local) - ticks(&utc)) / 10_000_000,
        }
    }

    /// `2026-09-29T14:03:07.120+07:00`: history's `ts`.
    pub fn iso(&self) -> String {
        let sign = if self.offset < 0 { '-' } else { '+' };
        let off = self.offset.abs();
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}{sign}{:02}:{:02}",
            self.year,
            self.month,
            self.day,
            self.hour,
            self.min,
            self.sec,
            self.millis,
            off / 3600,
            off % 3600 / 60
        )
    }

    /// `20260929-140307-120`: pending file names, which sort oldest first.
    pub fn file_stem(&self) -> String {
        format!(
            "{:04}{:02}{:02}-{:02}{:02}{:02}-{:03}",
            self.year, self.month, self.day, self.hour, self.min, self.sec, self.millis
        )
    }
}

// ---- pending ------------------------------------------------------------------

/// Keep a WAV that could not be sent, for `oliv retry`.
pub fn save_pending(wav: &[u8], stamp: &Stamp) -> Result<PathBuf, String> {
    save_pending_in(&pending_dir()?, wav, stamp)
}

fn save_pending_in(dir: &Path, wav: &[u8], stamp: &Stamp) -> Result<PathBuf, String> {
    private_dir(dir)?;
    let path = dir.join(format!("{}.wav", stamp.file_stem()));
    let mut f = private_options()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    f.write_all(wav)
        .and_then(|_| f.sync_all())
        .map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path)
}

/// Pending WAVs, oldest first.
pub fn pending_files() -> Result<Vec<PathBuf>, String> {
    let dir = pending_dir()?;
    let rd = match std::fs::read_dir(&dir) {
        Ok(rd) => rd,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    };
    let mut files: Vec<PathBuf> = rd
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "wav"))
        .collect();
    files.sort();
    Ok(files)
}

// ---- history ------------------------------------------------------------------

/// The newest `keep` lines of `text` when it has more than `trim_at`, else None.
pub fn trimmed(text: &str, keep: usize, trim_at: usize) -> Option<String> {
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.len() <= trim_at {
        return None;
    }
    let mut out = lines[lines.len() - keep..].join("\n");
    out.push('\n');
    Some(out)
}

/// Append one entry to history.jsonl, trimming it to the newest 1,000.
pub fn append_history(entry: &Value) -> Result<(), String> {
    let path = history_path()?;
    let dir = state_dir()?;
    private_dir(&dir)?;
    let _lock = lock(&dir.join("history.lock"))?;
    let mut line = serde_json::to_string(entry).map_err(|e| e.to_string())?;
    line.push('\n');
    let err = |e: std::io::Error| format!("{}: {e}", path.display());
    private_options()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut f| f.write_all(line.as_bytes()))
        .map_err(err)?;
    let text = std::fs::read_to_string(&path).map_err(err)?;
    if let Some(kept) = trimmed(&text, HISTORY_KEEP, HISTORY_TRIM_AT) {
        let tmp = path.with_extension("jsonl.tmp");
        private_options()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&tmp)
            .and_then(|mut f| f.write_all(kept.as_bytes()).and_then(|_| f.sync_all()))
            .and_then(|_| std::fs::rename(&tmp, &path))
            .map_err(err)?;
    }
    Ok(())
}

/// Every history entry, oldest first; unreadable lines are skipped.
pub fn read_history() -> Result<Vec<Value>, String> {
    let path = history_path()?;
    match std::fs::read_to_string(&path) {
        Ok(text) => Ok(text
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_audio_is_private_durable_and_never_overwritten() {
        let dir = std::env::temp_dir().join(format!("oliv-pending-test-{}", std::process::id()));
        let stamp = Stamp::now();
        let wav = crate::wav::encode(&vec![0; 16000], 16000);
        let path = save_pending_in(&dir, &wav, &stamp).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), wav);
        // Windows privacy comes from the directory's protected user-only ACL,
        // which the native Windows tests check; mode bits are Unix-only.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        assert!(save_pending_in(&dir, b"do not replace", &stamp).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), wav);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn trim_keeps_newest() {
        let text: String = (0..13).map(|i| format!("{i}\n")).collect();
        assert_eq!(trimmed(&text, 10, 13), None);
        let text = format!("{text}13\n");
        assert_eq!(
            trimmed(&text, 10, 13).unwrap(),
            "4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n"
        );
    }

    #[test]
    fn stamp_formats() {
        let s = Stamp {
            year: 2026,
            month: 9,
            day: 2,
            hour: 7,
            min: 3,
            sec: 9,
            millis: 45,
            offset: 7 * 3600,
        };
        assert_eq!(s.iso(), "2026-09-02T07:03:09.045+07:00");
        assert_eq!(s.file_stem(), "20260902-070309-045");
        let w = Stamp {
            offset: -(3 * 3600 + 30 * 60),
            ..s
        };
        assert!(w.iso().ends_with("-03:30"));
    }

    #[test]
    fn now_is_sane() {
        let s = Stamp::now();
        assert!(s.year >= 2026 && (1..=12).contains(&s.month) && s.millis < 1000);
    }
}
