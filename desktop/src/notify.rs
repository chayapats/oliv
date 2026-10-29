//! Short notices: shown by the overlay when it is running, otherwise (the CLI
//! process, or no layer-shell) through `notify-send`.

use std::process::{Command, Stdio};

use crate::draw::Kind;
use crate::overlay;

/// Show `msg` briefly; each notice replaces the previous one.
pub fn notify(msg: &str) {
    show(Kind::Info, msg);
}

/// Like `notify`, for something that went wrong.
pub fn alert(msg: &str) {
    show(Kind::Error, msg);
}

fn show(kind: Kind, msg: &str) {
    if overlay::notice(kind, msg) {
        return;
    }
    let _ = Command::new("notify-send")
        .args([
            "--app-name=oliv",
            "--expire-time=2500",
            "--hint=string:x-canonical-private-synchronous:oliv",
            "oliv",
            msg,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}
