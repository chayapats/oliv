//! Notices use the native, non-activating overlay. CLI commands and overlay
//! startup failures also have a console fallback, so errors are never silent.

use crate::draw::Kind;
use crate::overlay;

pub fn notify(message: &str) {
    show(Kind::Info, message);
}

pub fn alert(message: &str) {
    show(Kind::Error, message);
}

fn show(kind: Kind, message: &str) {
    if !overlay::notice(kind, message) {
        eprintln!("oliv: {message}");
    }
}
