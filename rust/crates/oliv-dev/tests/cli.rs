use serde_json::{Value, json};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
static COUNTER: AtomicUsize = AtomicUsize::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "oliv-dev-tests-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn json(&self, name: &str, value: &Value) -> PathBuf {
        let path = self.0.join(name);
        std::fs::write(&path, serde_json::to_vec(value).unwrap()).unwrap();
        path
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn tool() -> Command {
    Command::new(env!("CARGO_BIN_EXE_oliv-dev"))
}

#[test]
fn rescore_preserves_raw_output_and_corrects_metrics() {
    let f = Fixture::new();
    let input=f.json("input.json",&json!({"clips":[{"id":"en1","reference":"Hello world","final":"Hello","raw":"hello","latency_s":0.25,"wer":999}]}));
    let out = f.0.join("nested/score.json");
    let result = tool()
        .args(["score", "--input"])
        .arg(&input)
        .arg("--out")
        .arg(&out)
        .output()
        .unwrap();
    assert!(result.status.success());
    assert!(!String::from_utf8_lossy(&result.stdout).contains("Hello"));
    let report: Value = serde_json::from_slice(&std::fs::read(&out).unwrap()).unwrap();
    assert_eq!(report["clips"][0]["raw"], "hello");
    assert_eq!(report["clips"][0]["wer"], 0.5);
    assert_eq!(report["overall"]["n"], 1);
    assert_eq!(report["aggregate"]["en"]["mean_latency_s"], 0.25);
}
#[test]
fn report_escapes_clip_content_and_does_not_export_audio() {
    let f = Fixture::new();
    let input=f.json("input.json",&json!({"label":"<unsafe>","clips":[{"id":"en1","reference":"<script>alert(1)</script>","final":"& text","wer":0.5,"cer":0.25}]}));
    let out = f.0.join("report.html");
    let result = tool()
        .arg("report")
        .arg("--input")
        .arg(&input)
        .arg("--out")
        .arg(&out)
        .output()
        .unwrap();
    assert!(result.status.success());
    let html = std::fs::read_to_string(&out).unwrap();
    assert!(!html.contains("<script>"));
    assert!(html.contains("&lt;script&gt;"));
    assert!(html.contains("&amp; text"));
    assert!(!html.contains("<audio"));
}
#[test]
fn empty_evaluation_fails_before_model_launch() {
    let f = Fixture::new();
    let manifest = f.0.join("empty.jsonl");
    std::fs::write(&manifest, "# no clips\n").unwrap();
    let result = tool()
        .args(["eval", "--manifest"])
        .arg(&manifest)
        .args(["--runtime-dir", "/nonexistent/runtime"])
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("No selected manifest rows"));
}
