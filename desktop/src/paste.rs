//! Paste text into the focused window (Hyprland): back up the clipboard,
//! `wl-copy` our text, send the
//! paste chord through `hyprctl eval`, wait, then restore the old clipboard if
//! it still holds our text. Never wtype (it mangles Thai).

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

const TEXT_TYPE: &str = "text/plain;charset=utf-8";
/// How long the target app gets to read the clipboard before we restore it.
const SETTLE: Duration = Duration::from_millis(300);
/// Upper bound for one wl-paste / hyprctl call.
const CMD_TIMEOUT: Duration = Duration::from_secs(2);

/// Which clipboard type to back up. The first offered type can be an empty
/// app-private marker (kitty's `application/glfw+clipboard-*`), so rank real
/// types: image, UTF-8 text, any text, then any other MIME type.
pub fn backup_type<'a>(types: &[&'a str]) -> Option<&'a str> {
    let find = |f: &dyn Fn(&str) -> bool| types.iter().copied().find(|t| f(t));
    find(&|t| t.starts_with("image/"))
        .or_else(|| find(&|t| t == TEXT_TYPE))
        .or_else(|| find(&|t| t == "text/plain"))
        .or_else(|| find(&|t| t == "UTF8_STRING"))
        .or_else(|| find(&|t| t.starts_with("text/")))
        .or_else(|| find(&|t| t.contains('/') && !t.starts_with("application/glfw")))
}

/// A window tagged `terminal*` by Hyprland window rules (e.g. Omarchy's).
pub fn is_terminal(activewindow: &Value) -> bool {
    activewindow["tags"].as_array().is_some_and(|tags| {
        tags.iter()
            .any(|t| t.as_str().is_some_and(|t| t.starts_with("terminal")))
    })
}

/// Shift+Insert in terminals, Ctrl+V elsewhere.
pub fn chord(terminal: bool) -> (&'static str, &'static str) {
    if terminal {
        ("SHIFT", "Insert")
    } else {
        ("CTRL", "V")
    }
}

/// Lua for `hyprctl eval`: key down now, key up 50 ms later.
pub fn chord_lua(mods: &str, key: &str) -> String {
    let press = |state: &str| {
        format!(
            "hl.dispatch(hl.dsp.send_key_state({{ mods = '{mods}', key = '{key}', state = '{state}' }}))"
        )
    };
    format!(
        "{}; hl.timer(function() {} end, {{ timeout = 50, type = 'oneshot' }})",
        press("down"),
        press("up")
    )
}

/// Run `cmd` and return its stdout. A hung clipboard owner or compositor must
/// not stall the worker (and every recording queued behind it), so the command
/// is killed after `CMD_TIMEOUT`. Only a paste in progress waits here.
fn output(cmd: &mut Command) -> Result<Vec<u8>, String> {
    run(cmd.stdout(Stdio::piped()), None)
}

/// Spawn `cmd` (stdout already configured), feed it `input` if any, and wait
/// at most `CMD_TIMEOUT`, killing it after that. Both pipes are serviced on
/// helper threads so neither a full pipe nor a stalled reader blocks us.
fn run(cmd: &mut Command, input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    let name = format!("{:?}", cmd.get_program());
    let mut child = cmd
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("{name}: {e}"))?;
    let writer = match (input, child.stdin.take()) {
        (Some(data), Some(mut stdin)) => {
            let data = data.to_vec();
            // Dropping stdin when done sends EOF.
            Some(std::thread::spawn(move || stdin.write_all(&data)))
        }
        _ => None,
    };
    // Read concurrently: a large image would fill the pipe and block the child.
    let reader = child.stdout.take().map(|mut out| {
        std::thread::spawn(move || {
            let mut b = Vec::new();
            let _ = out.read_to_end(&mut b);
            b
        })
    });
    let t0 = Instant::now();
    let status = loop {
        match child.try_wait().map_err(|e| format!("{name}: {e}"))? {
            Some(s) => break s,
            None if t0.elapsed() < CMD_TIMEOUT => std::thread::sleep(Duration::from_millis(5)),
            None => {
                // The helper threads end once the child's pipe ends close.
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{name} timed out"));
            }
        }
    };
    if let Some(Ok(Err(e))) = writer.map(|w| w.join()) {
        return Err(format!("{name}: {e}"));
    }
    let data = reader
        .map(|r| r.join().unwrap_or_default())
        .unwrap_or_default();
    if !status.success() {
        return Err(format!("{name} failed: {status}"));
    }
    Ok(data)
}

/// Put `data` on the clipboard as `mime`. wl-copy forks a server and returns;
/// its stdout/stderr go to /dev/null so it never holds our pipes open.
pub fn copy(data: &[u8], mime: &str) -> Result<(), String> {
    run(
        Command::new("wl-copy")
            .args(["--type", mime])
            .stdout(Stdio::null()),
        Some(data),
    )
    .map(|_| ())
}

fn clear() {
    let _ = run(
        Command::new("wl-copy").arg("--clear").stdout(Stdio::null()),
        None,
    );
}

/// The current clipboard as (type, bytes), or None when it is empty.
fn backup() -> Option<(String, Vec<u8>)> {
    let list = output(Command::new("wl-paste").arg("--list-types")).ok()?;
    let list = String::from_utf8_lossy(&list);
    let types: Vec<&str> = list.lines().collect();
    let t = backup_type(&types)?.to_string();
    let data = output(Command::new("wl-paste").args(["--no-newline", "--type", &t])).ok()?;
    Some((t, data))
}

fn still_ours(text: &str) -> bool {
    output(Command::new("wl-paste").args(["--no-newline", "--type", TEXT_TYPE]))
        .is_ok_and(|b| b == text.as_bytes())
}

/// Paste `text` into the focused window and put the old clipboard back.
/// `Err` means the paste chord was not sent; our text may still be on the
/// clipboard, which is the useful fallback. A failed restore is only logged:
/// the text is already in the window by then.
pub fn paste(text: &str) -> Result<(), String> {
    let old = backup();
    copy(text.as_bytes(), TEXT_TYPE)?;
    let win = output(Command::new("hyprctl").args(["activewindow", "-j"]))?;
    let win: Value = serde_json::from_slice(&win).unwrap_or(Value::Null);
    let (mods, key) = chord(is_terminal(&win));
    output(Command::new("hyprctl").args(["eval", &chord_lua(mods, key)]))?;
    std::thread::sleep(SETTLE);
    if still_ours(text) {
        match old {
            Some((t, data)) => {
                if let Err(e) = copy(&data, &t) {
                    eprintln!("paste: could not restore the clipboard: {e}");
                }
            }
            None => clear(),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn kitty_marker_is_skipped() {
        let kitty = [
            "application/glfw+clipboard-12345-1",
            "TEXT",
            "STRING",
            "UTF8_STRING",
            "text/plain;charset=utf-8",
            "text/plain",
        ];
        assert_eq!(backup_type(&kitty), Some("text/plain;charset=utf-8"));
    }

    #[test]
    fn ranking() {
        assert_eq!(
            backup_type(&["text/html", "image/png", TEXT_TYPE]),
            Some("image/png")
        );
        assert_eq!(
            backup_type(&["text/html", "text/plain"]),
            Some("text/plain")
        );
        assert_eq!(backup_type(&["STRING", "UTF8_STRING"]), Some("UTF8_STRING"));
        assert_eq!(
            backup_type(&["TEXT", "text/uri-list"]),
            Some("text/uri-list")
        );
        assert_eq!(
            backup_type(&["application/glfw+x", "application/x-thing", "TEXT"]),
            Some("application/x-thing")
        );
        assert_eq!(backup_type(&["application/glfw+x", "TEXT"]), None);
        assert_eq!(backup_type(&[]), None);
    }

    #[test]
    fn terminal_tag() {
        assert!(is_terminal(
            &json!({"tags": ["default-opacity*", "terminal*"]})
        ));
        assert!(is_terminal(&json!({"tags": ["terminal"]})));
        assert!(!is_terminal(&json!({"tags": ["default-opacity*"]})));
        assert!(!is_terminal(&json!({})));
        assert!(!is_terminal(&Value::Null));
        assert_eq!(chord(true), ("SHIFT", "Insert"));
        assert_eq!(chord(false), ("CTRL", "V"));
    }

    #[test]
    fn output_reads_big_stdout_and_times_out() {
        let big = output(Command::new("head").args(["-c", "1000000", "/dev/zero"])).unwrap();
        assert_eq!(big.len(), 1_000_000);
        assert!(output(&mut Command::new("false")).is_err());
        let t0 = Instant::now();
        let e = output(Command::new("sleep").arg("10")).unwrap_err();
        assert!(e.contains("timed out"), "{e}");
        assert!(t0.elapsed() < CMD_TIMEOUT + Duration::from_secs(1));
    }

    #[test]
    fn input_is_fed_and_a_stalled_reader_times_out() {
        let echoed = run(Command::new("cat").stdout(Stdio::piped()), Some(b"OLIV")).unwrap();
        assert_eq!(echoed, b"OLIV");
        // A child that never reads its stdin: the write blocks once the pipe
        // fills, and must not block the caller past the deadline.
        let t0 = Instant::now();
        let big = vec![0u8; 4 << 20];
        let e = run(
            Command::new("sleep").arg("10").stdout(Stdio::null()),
            Some(&big),
        )
        .unwrap_err();
        assert!(e.contains("timed out"), "{e}");
        assert!(t0.elapsed() < CMD_TIMEOUT + Duration::from_secs(1));
    }

    #[test]
    fn lua() {
        assert_eq!(
            chord_lua("CTRL", "V"),
            "hl.dispatch(hl.dsp.send_key_state({ mods = 'CTRL', key = 'V', state = 'down' })); \
             hl.timer(function() hl.dispatch(hl.dsp.send_key_state({ mods = 'CTRL', key = 'V', state = 'up' })) end, \
             { timeout = 50, type = 'oneshot' })"
        );
    }
}
