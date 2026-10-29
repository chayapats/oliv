//! Exercise the installed-tool interface, including output redaction.
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "oliv-keys-cli-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        Self(root)
    }

    fn run(&self, arguments: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_oliv-keys"))
            .arg("--root")
            .arg(&self.0)
            .args(arguments)
            .output()
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn cli_create_list_revoke_and_export_collision_keep_secrets_out_of_output() {
    let fixture = Fixture::new();
    assert!(fixture.run(&["init"]).status.success());
    let out = fixture.0.join("ผู้ใช้'s key.txt");
    let created = fixture.run(&[
        "create",
        "--name",
        "ผู้ใช้'s laptop",
        "--out",
        out.to_str().unwrap(),
        "--scopes",
        "dictate,clean",
        "--requests-per-minute",
        "3",
        "--daily-requests",
        "20",
    ]);
    assert!(
        created.status.success(),
        "{}",
        String::from_utf8_lossy(&created.stderr)
    );
    let raw = std::fs::read_to_string(&out).unwrap();
    assert_eq!(std::fs::metadata(&out).unwrap().mode() & 0o777, 0o600);
    assert!(!String::from_utf8_lossy(&created.stdout).contains(raw.trim()));
    assert!(created.stderr.is_empty());
    let listed = fixture.run(&["list"]);
    assert!(listed.status.success());
    let text = String::from_utf8(listed.stdout).unwrap();
    assert!(!text.contains("sha256"));
    assert!(!text.contains(raw.trim()));
    let info: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(info[0]["requests_per_minute"], 3);
    assert_eq!(info[0]["daily_requests"], 20);
    let id = info[0]["id"].as_str().unwrap();
    assert!(fixture.run(&["revoke", id]).status.success());
    let collision = fixture.run(&[
        "create",
        "--name",
        "collision",
        "--out",
        out.to_str().unwrap(),
    ]);
    assert!(!collision.status.success());
    assert!(collision.stdout.is_empty());
    assert!(!String::from_utf8_lossy(&collision.stderr).contains(raw.trim()));
    assert_eq!(
        std::fs::read_to_string(out).unwrap().as_bytes(),
        raw.as_bytes()
    );
    let listed: serde_json::Value = serde_json::from_slice(&fixture.run(&["list"]).stdout).unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["revoked"], true);
}

#[test]
fn cli_invalid_options_never_create_credentials() {
    let fixture = Fixture::new();
    assert!(fixture.run(&["init"]).status.success());
    let output = fixture.run(&[
        "create",
        "--name",
        "alice",
        "--out",
        fixture.0.join("out").to_str().unwrap(),
        "--scopes",
        "admin",
    ]);
    assert!(!output.status.success());
    assert!(!fixture.0.join("out").exists());
    assert!(!fixture.run(&["create", "--name"]).status.success());
    assert!(!fixture.run(&["list", "unexpected"]).status.success());
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&fixture.run(&["list"]).stdout).unwrap(),
        serde_json::json!([])
    );
}

#[test]
fn restrictive_umask_still_creates_usable_mode_600_files() {
    let fixture = Fixture::new();
    let run = |arguments: &[&str]| {
        let mut command = Command::new(env!("CARGO_BIN_EXE_oliv-keys"));
        command.arg("--root").arg(&fixture.0).args(arguments);
        // SAFETY: this child-only hook calls only async-signal-safe umask and
        // returns; the parent process and parallel tests keep their umask.
        unsafe {
            command.pre_exec(|| {
                libc::umask(0o777);
                Ok(())
            });
        }
        command.output().unwrap()
    };
    assert!(run(&["init"]).status.success());
    let out = fixture.0.join("out");
    let result = run(&["create", "--name", "alice", "--out", out.to_str().unwrap()]);
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert_eq!(std::fs::metadata(out).unwrap().mode() & 0o777, 0o600);
    assert!(fixture.run(&["list"]).status.success());
}

#[test]
fn cli_links_keys_to_a_shared_dictionary_profile() {
    let fixture = Fixture::new();
    assert!(fixture.run(&["init"]).status.success());
    let mut ids = Vec::new();
    for name in ["mac", "iphone"] {
        let out = fixture.0.join(format!("{name}.key"));
        let created = fixture.run(&["create", "--name", name, "--out", out.to_str().unwrap()]);
        assert!(created.status.success());
    }
    let listed: serde_json::Value = serde_json::from_slice(&fixture.run(&["list"]).stdout).unwrap();
    for key in listed.as_array().unwrap() {
        ids.push(key["id"].as_str().unwrap().to_string());
    }
    let (mac, iphone) = (&ids[0], &ids[1]);

    let linked = fixture.run(&["profile", "link", iphone, mac]);
    assert!(
        linked.status.success(),
        "{}",
        String::from_utf8_lossy(&linked.stderr)
    );
    let links: serde_json::Value =
        serde_json::from_slice(&fixture.run(&["profile", "list"]).stdout).unwrap();
    assert_eq!(
        links,
        serde_json::json!([{"key_id": iphone, "profile": mac}])
    );

    // Unknown keys and malformed profile names are refused.
    assert!(
        !fixture
            .run(&["profile", "link", "0000000000000000", mac])
            .status
            .success()
    );
    assert!(
        !fixture
            .run(&["profile", "link", mac, "bad name"])
            .status
            .success()
    );
    assert!(!fixture.run(&["profile", "bogus"]).status.success());

    assert!(fixture.run(&["profile", "unlink", iphone]).status.success());
    let links: serde_json::Value =
        serde_json::from_slice(&fixture.run(&["profile", "list"]).stdout).unwrap();
    assert_eq!(links, serde_json::json!([]));
}
