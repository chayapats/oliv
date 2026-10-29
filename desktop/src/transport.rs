//! Linux local transport. Windows supplies the same interface using named pipes.
use std::fs::{File, OpenOptions, TryLockError};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
pub use std::os::unix::net::{UnixListener as Listener, UnixStream as Stream};
use std::sync::OnceLock;

/// Held for the daemon's lifetime. Without it two daemons starting together
/// can both find no live socket, and the second unlinks the first's.
static OWNER: OnceLock<File> = OnceLock::new();

pub fn bind() -> Result<Listener, String> {
    let path = crate::store::socket_path()?;
    let lock_path = path.with_extension("lock");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(&lock_path)
        .map_err(|e| format!("{}: {e}", lock_path.display()))?;
    match lock.try_lock() {
        Ok(()) => {}
        Err(TryLockError::WouldBlock) => {
            return Err(format!(
                "another oliv daemon is running ({})",
                path.display()
            ));
        }
        Err(TryLockError::Error(e)) => return Err(format!("{}: {e}", lock_path.display())),
    }
    // A daemon from before the lock existed still answers on the socket.
    if Stream::connect(&path).is_ok() {
        return Err(format!(
            "another oliv daemon is running ({})",
            path.display()
        ));
    }
    let _ = std::fs::remove_file(&path);
    let listener = Listener::bind(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("{}: {e}", path.display()))?;
    OWNER
        .set(lock)
        .map_err(|_| "the daemon socket was bound twice".to_string())?;
    Ok(listener)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn second_owner_is_refused_while_the_first_holds_the_lock() {
        let dir = std::env::temp_dir().join(format!("oliv-transport-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let lock_path = dir.join("oliv.lock");
        let open = || {
            OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(&lock_path)
                .unwrap()
        };
        let first = open();
        first.try_lock().unwrap();
        assert!(matches!(open().try_lock(), Err(TryLockError::WouldBlock)));
        drop(first);
        open().try_lock().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
