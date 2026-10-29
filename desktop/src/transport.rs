//! Linux local transport. Windows supplies the same interface using named pipes.
use std::os::unix::fs::PermissionsExt;
pub use std::os::unix::net::{UnixListener as Listener, UnixStream as Stream};

pub fn bind() -> Result<Listener, String> {
    let path = crate::store::socket_path()?;
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
    Ok(listener)
}
