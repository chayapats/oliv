//! `oliv`: native Linux/Windows push-to-talk dictation client.
//! See `README.md`, `docs/DEVELOPMENT.md` and `oliv --help`.

mod api;
#[cfg_attr(windows, path = "windows/capture.rs")]
mod capture;
mod config;
mod daemon;
mod draw;
#[cfg(windows)]
#[path = "windows/hotkey.rs"]
mod hotkey;
mod ipc;
#[cfg_attr(windows, path = "windows/notify.rs")]
mod notify;
#[cfg_attr(windows, path = "windows/overlay.rs")]
mod overlay;
#[cfg_attr(windows, path = "windows/paste.rs")]
mod paste;
#[cfg(windows)]
#[path = "windows/security.rs"]
mod security;
mod store;
#[cfg_attr(windows, path = "windows/transport.rs")]
mod transport;
mod wav;
#[cfg(all(test, not(windows)))]
#[path = "windows/audio.rs"]
mod windows_audio_tests;
#[cfg(all(test, not(windows)))]
#[path = "windows/hotkey_state.rs"]
mod windows_hotkey_tests;

use serde_json::{Value, json};

use ipc::Command;

const USAGE: &str = "\
usage: oliv <command>

  daemon            run the background service (hold Right Shift to dictate)
  start | stop      begin / end a recording
  cancel            drop the current recording without sending it
  status [--json]   what the daemon is doing, and how many recordings are pending
  health            public API liveness (does not check models or key)
  last              print the last dictated text
  retry             send the recordings kept in pending/ and print their text
  history [N] [--json]
                    the last N dictations (default 20)
";

fn ctl(cmd: Command) -> Result<(), String> {
    match ipc::send(cmd) {
        Ok(v) if v["ok"] == true => Ok(()),
        Ok(v) => Err(v["error"].as_str().unwrap_or("failed").to_string()),
        Err(e) => {
            if cmd == Command::Start {
                // Pressed from a key bind: nobody sees stderr.
                notify::notify("oliv daemon ไม่ได้ทำงาน");
            }
            Err(e)
        }
    }
}

fn status(json_out: bool) -> Result<(), String> {
    let pending = store::pending_files()?.len();
    match ipc::send(Command::Status) {
        Ok(mut v) => {
            if json_out {
                v["pending"] = json!(pending);
                println!("{v}");
            } else {
                println!("{}", ipc::status_line(&v, pending));
            }
            Ok(())
        }
        Err(e) => {
            if json_out {
                println!(
                    "{}",
                    json!({"ok": false, "state": "down", "pending": pending})
                );
            } else if pending > 0 {
                println!("daemon not running · pending {pending}");
            } else {
                println!("daemon not running");
            }
            Err(e)
        }
    }
}

fn last() -> Result<(), String> {
    let h = store::read_history()?;
    let text = h
        .iter()
        .rev()
        .filter_map(|e| e["final"].as_str())
        .find(|t| !t.trim().is_empty())
        .ok_or("no dictation yet")?;
    println!("{text}");
    Ok(())
}

/// `2026-09-29T14:03:07.120+07:00` -> `09-29 14:03`.
fn short_ts(ts: &str) -> String {
    match (ts.get(5..10), ts.get(11..16)) {
        (Some(d), Some(t)) => format!("{d} {t}"),
        _ => ts.to_string(),
    }
}

fn history_line(e: &Value) -> String {
    let text = match e["final"].as_str() {
        Some(t) if !t.trim().is_empty() => t.replace('\n', " ⏎ "),
        _ => format!("({})", api::NO_SPEECH),
    };
    let mark = if e["source"] == "retry" {
        " [retry]"
    } else {
        ""
    };
    format!(
        "{}{mark}  {text}",
        short_ts(e["ts"].as_str().unwrap_or("?"))
    )
}

fn history(args: &[String]) -> Result<(), String> {
    let mut n = 20;
    let mut json_out = false;
    for a in args {
        match a.as_str() {
            "--json" => json_out = true,
            s => n = s.parse().map_err(|_| format!("bad count: {s}"))?,
        }
    }
    let h = store::read_history()?;
    for e in &h[h.len().saturating_sub(n)..] {
        if json_out {
            println!("{e}");
        } else {
            println!("{}", history_line(e));
        }
    }
    Ok(())
}

/// Send each pending WAV, oldest first, one at a time. Text goes to stdout and
/// history; nothing is pasted (the focused window is not where it was spoken).
/// Stops at the first failure; files not yet sent stay pending.
fn retry() -> Result<(), String> {
    if store::pending_files()?.is_empty() {
        eprintln!("nothing pending");
        return Ok(());
    }
    // Serialize the whole queue, not only HTTP: another retry must not read a
    // WAV before this process removes it and then send that stale copy again.
    let _retry = store::lock(&store::runtime_dir()?.join("retry.lock"))?;
    let files = store::pending_files()?;
    let cfg = config::load()?;
    let mut texts = Vec::new();
    let mut failed = None;
    for f in &files {
        match retry_one(&cfg, f) {
            Ok(Some(text)) => texts.push(text),
            Ok(None) => {}
            Err(e) => {
                failed = Some(e);
                break;
            }
        }
    }
    if let [only] = texts.as_slice() {
        paste::copy(only.as_bytes(), "text/plain;charset=utf-8")?;
        eprintln!("(copied to the clipboard)");
    }
    failed.map_or(Ok(()), Err)
}

/// Send one pending file; once the server has answered, the file is removed
/// before anything else can fail, so it is never sent twice.
fn retry_one(cfg: &config::Config, f: &std::path::Path) -> Result<Option<String>, String> {
    let _lock = store::request_lock()?;
    // Another retry may have consumed this snapshot entry while we waited.
    if !f.exists() {
        return Ok(None);
    }
    let name = f.file_name().unwrap_or_default().to_string_lossy();
    let wav = std::fs::read(f).map_err(|e| format!("{}: {e}", f.display()))?;
    let (res, t_total) = api::dictate_guarded(cfg, &wav);
    let reply = res.map_err(|e| format!("{name}: {e} (still pending)"))?;
    std::fs::remove_file(f).map_err(|e| format!("{}: {e}", f.display()))?;
    let mut entry = api::history_entry(
        &store::Stamp::now().iso(),
        "retry",
        wav::seconds(&wav),
        &reply,
        t_total,
        false,
    );
    entry["recorded"] = json!(f.file_stem().unwrap_or_default().to_string_lossy());
    if let Err(e) = store::append_history(&entry) {
        eprintln!("history: {e}");
    }
    match api::action(&reply) {
        api::Action::Paste(text) => {
            println!("{text}");
            Ok(Some(text.to_string()))
        }
        api::Action::Notice(msg) => {
            eprintln!("{name}: {msg}");
            Ok(None)
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let cmd = args.first().map(String::as_str);
    let rest = args.get(1..).unwrap_or_default();
    let no_more = || match rest {
        [] => Ok(()),
        _ => Err(format!("unexpected argument: {}\n\n{USAGE}", rest[0])),
    };
    match cmd {
        Some("daemon") => no_more().and_then(|_| daemon::run()),
        Some("start") => no_more().and_then(|_| ctl(Command::Start)),
        Some("stop") => no_more().and_then(|_| ctl(Command::Stop)),
        Some("cancel") => no_more().and_then(|_| ctl(Command::Cancel)),
        Some("status") => match rest {
            [] => status(false),
            [j] if j == "--json" => status(true),
            _ => Err(USAGE.into()),
        },
        Some("health") => no_more().and_then(|_| {
            api::health(&config::load()?).map_err(|e| e.to_string())?;
            println!("API alive (model/pipeline readiness and key validity not checked)");
            Ok(())
        }),
        Some("last") => no_more().and_then(|_| last()),
        Some("retry") => no_more().and_then(|_| retry()),
        Some("history") => history(rest),
        Some("-h" | "--help" | "help") => {
            print!("{USAGE}");
            Ok(())
        }
        _ => Err(USAGE.into()),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(e) = run(&args) {
        eprintln!("oliv: {}", e.trim_end());
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn history_lines() {
        let e = json!({"ts": "2026-09-29T14:03:07.120+07:00", "source": "dictate", "final": "สวัสดี\nครับ"});
        assert_eq!(history_line(&e), "09-29 14:03  สวัสดี ⏎ ครับ");
        let e = json!({"ts": "2026-09-29T14:03:07.120+07:00", "source": "retry", "final": ""});
        assert_eq!(history_line(&e), "09-29 14:03 [retry]  (ไม่ได้ยินเสียงพูด)");
    }

    #[test]
    fn args() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert!(run(&s(&["nope"])).is_err());
        assert!(run(&s(&["start", "x"])).is_err());
        assert!(run(&s(&["history", "abc"])).is_err());
    }
}
