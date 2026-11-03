use serde_json::{Value, json};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
fn run(requests: &[Value]) -> Vec<Value> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_oliv-sidecar"))
        .env_remove("OLIV_INFERENCE_EXECUTABLE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    for request in requests {
        writeln!(input, "{request}").unwrap();
    }
    drop(input);
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}
#[test]
fn ping_silence_and_text_work_without_inference() {
    let replies = run(&[
        json!({"id":4,"cmd":"ping"}),
        json!({"id":5,"cmd":"dictate","pcm_b64":"AAAAAA=="}),
        json!({"id":6,"cmd":"text","cleanup":false,"format_commands":true,"text":"hello new line world"}),
    ]);
    assert_eq!(replies.len(), 3);
    assert_eq!(replies[0]["runtime"], "rust-core");
    assert_eq!(replies[0]["id"], 4);
    assert_eq!(replies[1]["no_speech"], true);
    assert_eq!(replies[2]["final"], "hello\nworld");
}
#[test]
fn bad_request_does_not_poison_following_request() {
    let replies = run(&[
        json!(["not an object"]),
        json!({"id":2,"cmd":"dictate","pcm_b64":"invalid"}),
        json!({"id":3,"cmd":"ping"}),
    ]);
    assert_eq!(replies[0]["code"], "invalidRequest");
    assert_eq!(replies[1]["ok"], false);
    assert_eq!(replies[2]["ok"], true);
    assert_eq!(replies[2]["id"], 3);
}
#[test]
fn evaluation_replay_runs_text_stage_without_inference() {
    use base64::Engine;
    // One second of a 0.1-amplitude square wave: well above the silence gate.
    let pcm: Vec<u8> = (0..16000)
        .flat_map(|i| (if i % 2 == 0 { 0.1f32 } else { -0.1 }).to_le_bytes())
        .collect();
    let pcm = base64::engine::general_purpose::STANDARD.encode(pcm);
    let replies = run(&[
        json!({"id":1,"cmd":"dictate","pcm_b64":pcm,"stt_text":"ไปดูล็อกในกราฟาน่า",
            "cleanup_llm":false,"vocabulary":["Grafana"]}),
        json!({"id":2,"cmd":"dictate","pcm_b64":pcm,"stt_text":"สวัสดีครับ","cleanup":false}),
    ]);
    assert_eq!(replies[0]["ok"], true, "{}", replies[0]);
    assert_eq!(replies[0]["stt_replayed"], true);
    assert_eq!(replies[0]["raw"], "ไปดูล็อกในกราฟาน่า");
    assert!(replies[0]["final"].as_str().unwrap().contains("Grafana"));
    assert_eq!(replies[0]["guardrail_flag"], "llmError->dict");
    assert_eq!(replies[1]["final"], "สวัสดีครับ");
}

/// A model helper whose preview decode only ends when `cancel_preview` arrives
/// (or after 20 s); a plain STT request answers at once.
const SLOW_PREVIEW_HELPER: &str = r#"#!/bin/bash
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"cmd":"cancel_preview"'*) ;;
    *'"preview_seq"'*)
      : > "$(dirname "$0")/decoding"
      if IFS= read -r -t 20 next && [[ "$next" == *cancel_preview* ]]; then
        printf '{"id":%s,"ok":true,"text":"","skipped":"cancelled"}\n' "$id"
      else
        printf '{"id":%s,"ok":true,"text":"finished anyway"}\n' "$id"
      fi ;;
    *'"cmd":"stt"'*) printf '{"id":%s,"ok":true,"text":"final words","avg_logprob":-0.1}\n' "$id" ;;
    *) printf '{"id":%s,"ok":false}\n' "$id" ;;
  esac
done
"#;

/// A directory only this user can enter, made fresh for one test (never an
/// existing one another user could have planted) and removed afterwards.
struct PrivateDir(PathBuf);

impl PrivateDir {
    fn new(prefix: &str) -> PrivateDir {
        use std::hash::{BuildHasher, Hasher};
        for _ in 0..16 {
            // RandomState is seeded randomly per process; the time and pid
            // keep names apart across processes too.
            let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
            hasher.write_u128(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
            );
            hasher.write_u32(std::process::id());
            let path = std::env::temp_dir().join(format!("{prefix}-{:016x}", hasher.finish()));
            // Not create_dir_all: an existing directory (or symlink) is refused.
            match std::fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => return PrivateDir(path),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => panic!("could not create {}: {e}", path.display()),
            }
        }
        panic!("no fresh temporary directory for {prefix}");
    }
}

impl Drop for PrivateDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Write an executable script at `dir/name`, refusing a file (or symlink)
/// that is already there rather than writing through it.
fn install_helper(dir: &Path, name: &str, script: &str) -> std::io::Result<PathBuf> {
    let path = dir.join(name);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o700)
        .open(&path)?;
    file.write_all(script.as_bytes())?;
    // On the open file, not the path: a later swap can't redirect it.
    file.set_permissions(std::fs::Permissions::from_mode(0o700))?;
    Ok(path)
}

#[test]
fn helper_directory_is_fresh_and_private() {
    let first = PrivateDir::new("oliv-ipc-test");
    let second = PrivateDir::new("oliv-ipc-test");
    assert_ne!(first.0, second.0);
    for dir in [&first, &second] {
        let meta = std::fs::symlink_metadata(&dir.0).unwrap();
        assert!(meta.is_dir());
        assert_eq!(meta.permissions().mode() & 0o777, 0o700);
    }
}

#[test]
fn helper_install_refuses_an_existing_file_or_symlink() {
    let dir = PrivateDir::new("oliv-ipc-test");
    let victim = dir.0.join("victim");
    std::fs::write(&victim, "keep me").unwrap();
    std::fs::set_permissions(&victim, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::os::unix::fs::symlink(&victim, dir.0.join("helper.sh")).unwrap();
    std::fs::write(dir.0.join("planted.sh"), "planted").unwrap();
    for name in ["helper.sh", "planted.sh"] {
        let err = install_helper(&dir.0, name, SLOW_PREVIEW_HELPER).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists, "{name}");
    }
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep me");
    assert_eq!(
        std::fs::metadata(&victim).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        std::fs::read_to_string(dir.0.join("planted.sh")).unwrap(),
        "planted"
    );
}

#[test]
fn release_cancels_a_preview_mid_decode_so_dictate_is_not_queued_behind_it() {
    use base64::Engine;
    use std::io::{BufRead, BufReader};
    use std::time::{Duration, Instant};
    let private = PrivateDir::new("oliv-preview-cancel");
    let dir = &private.0;
    let helper = install_helper(dir, "helper.sh", SLOW_PREVIEW_HELPER).unwrap();
    let speech: Vec<u8> = (0..16000)
        .flat_map(|i| (if i % 2 == 0 { 0.1f32 } else { -0.1 }).to_le_bytes())
        .collect();
    let pcm = base64::engine::general_purpose::STANDARD.encode(speech);
    let mut child = Command::new(env!("CARGO_BIN_EXE_oliv-sidecar"))
        .env("OLIV_INFERENCE_EXECUTABLE", &helper)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut reply = || {
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        serde_json::from_str::<Value>(&line).unwrap()
    };
    writeln!(
        input,
        "{}",
        json!({"id":1,"cmd":"preview","engine":"typhoon-turbo-mlx","preview_seq":7,"pcm_b64":pcm})
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !dir.join("decoding").exists() {
        assert!(
            Instant::now() < deadline,
            "the helper never started the preview"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // Release: cancel out of band, then the final pass right behind it.
    let released = Instant::now();
    writeln!(input, "{}", json!({"cmd":"cancel_preview","through":7})).unwrap();
    writeln!(
        input,
        "{}",
        json!({"id":2,"cmd":"dictate","engine":"typhoon-turbo-mlx","cleanup":false,"pcm_b64":pcm})
    )
    .unwrap();
    let preview = reply();
    let dictate = reply();
    let waited = released.elapsed();
    drop(input);
    assert!(child.wait().unwrap().success());
    assert_eq!(preview["id"], 1);
    assert_eq!(preview["skipped"], "cancelled", "{preview}");
    assert_eq!(preview["text"], "");
    assert_eq!(dictate["id"], 2);
    assert_eq!(dictate["final"], "final words", "{dictate}");
    assert!(waited < Duration::from_secs(5), "dictate waited {waited:?}");
}
