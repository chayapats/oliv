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

fn contextasr_fixture(f: &Fixture) -> PathBuf {
    use std::io::Write;
    let root = f.0.join("bench");
    std::fs::create_dir_all(root.join("data")).unwrap();
    let utterances = [
        json!({"utt_id":"b-1-1","text":"เรียกแกร็บไปสยาม","split":"synthetic","entity_free":false,
            "entities":[{"span_text":"แกร็บ","form_th":"แกร็บ","form_latin":"Grab"}]}),
        json!({"utt_id":"c-1-1","text":"วันนี้อากาศดี","split":"real","entity_free":true,"entities":[]}),
    ];
    let lines: Vec<String> = utterances.iter().map(Value::to_string).collect();
    std::fs::write(root.join("data/utterances.jsonl"), lines.join("\n")).unwrap();
    let lists = [
        json!({"utt_id":"b-1-1","condition":"bias@0","entries":["Grab"],"gold_listed":{"แกร็บ":"Grab"}}),
        json!({"utt_id":"b-1-1","condition":"dis@50","entries":["Netflix"],"gold_listed":{}}),
        json!({"utt_id":"c-1-1","condition":"dis@50","entries":["Netflix","สยาม"],"gold_listed":{}}),
    ];
    let mut gz = flate2::write::GzEncoder::new(
        std::fs::File::create(root.join("data/bias_lists.jsonl.gz")).unwrap(),
        flate2::Compression::default(),
    );
    for l in lists {
        writeln!(gz, "{l}").unwrap();
    }
    gz.finish().unwrap();
    root
}

fn write_hyps(f: &Fixture, name: &str, rows: &[(&str, &str, &str)]) -> PathBuf {
    let path = f.0.join(name).join("hyps.jsonl");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let lines: Vec<String> = rows
        .iter()
        .map(|(u, c, t)| json!({"utt_id":u,"condition":c,"text":t}).to_string())
        .collect();
    std::fs::write(&path, lines.join("\n")).unwrap();
    path
}

fn score_hyps(root: &PathBuf, hyps: &PathBuf, out: &PathBuf, pinned: bool) -> std::process::Output {
    let mut cmd = tool();
    cmd.args(["contextasr", "score", "--data-dir"])
        .arg(root)
        .arg("--hyps")
        .arg(hyps)
        .arg("--out")
        .arg(out);
    if !pinned {
        cmd.arg("--allow-unpinned");
    }
    cmd.output().unwrap()
}

#[test]
fn contextasr_scores_upstream_hyps_and_compares_identical_pairs() {
    let f = Fixture::new();
    let root = contextasr_fixture(&f);
    let base = write_hyps(
        &f,
        "base",
        &[
            ("b-1-1", "none", "เรียกแกร็บไปสยาม"),
            ("b-1-1", "bias@0", "เรียกแกร็บไปสยาม"),
            ("b-1-1", "dis@50", "เรียกแกร็บไปสยาม"),
            ("c-1-1", "none", "วันนี้อากาศดี"),
            ("c-1-1", "dis@50", "วันนี้ Netflix อากาศดี"),
        ],
    );
    let cand = write_hyps(
        &f,
        "cand",
        &[
            ("b-1-1", "none", "เรียกแกร็บไปสยาม"),
            ("b-1-1", "bias@0", "เรียก Grab ไปสยาม"),
            ("b-1-1", "dis@50", "เรียกแกร็บไปสยาม"),
            ("c-1-1", "none", "วันนี้อากาศดี"),
            ("c-1-1", "dis@50", "วันนี้อากาศดี"),
        ],
    );
    // The fixture lists are not the pinned upstream file.
    assert!(
        !score_hyps(&root, &base, &f.0.join("rb"), true)
            .status
            .success()
    );
    for (hyps, out) in [(&base, "rb"), (&cand, "rc")] {
        let r = score_hyps(&root, hyps, &f.0.join(out), false);
        assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stderr));
    }
    let m: Value =
        serde_json::from_slice(&std::fs::read(f.0.join("rb/metrics.json")).unwrap()).unwrap();
    let c = &m["conditions"];
    assert_eq!(c["none"]["cer"], 0.0);
    assert_eq!(c["bias@0"]["entity_recall"], 1.0);
    assert_eq!(c["bias@0"]["script_compliance"], 0.0);
    // "Netflix" fired on the entity-free utterance, counted as one biased insertion.
    assert_eq!(c["dis@50"]["counts"]["fired"], json!([1, 3]));
    assert_eq!(c["dis@50"]["counts"]["biased"]["ins"], 1);
    let m: Value =
        serde_json::from_slice(&std::fs::read(f.0.join("rc/metrics.json")).unwrap()).unwrap();
    assert_eq!(m["conditions"]["bias@0"]["script_compliance"], 1.0);
    assert_eq!(m["conditions"]["bias@0"]["cer"], 0.0);
    for name in ["metrics.csv", "report.md", "scores.jsonl"] {
        assert!(f.0.join("rc").join(name).is_file());
    }
    let report = std::fs::read_to_string(f.0.join("rc/report.md")).unwrap();
    assert!(
        !report.contains("วันนี้"),
        "reports must not quote transcripts"
    );
    let out = f.0.join("cmp/compare.md");
    let r = tool()
        .args(["contextasr", "compare", "--baseline"])
        .arg(f.0.join("rb"))
        .arg("--candidate")
        .arg(f.0.join("rc"))
        .arg("--out")
        .arg(&out)
        .output()
        .unwrap();
    assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stderr));
    let cmp: Value =
        serde_json::from_slice(&std::fs::read(out.with_extension("json")).unwrap()).unwrap();
    assert_eq!(
        cmp["conditions"]["dis@50"]["Distractor fire rate"]["delta"]
            .as_f64()
            .unwrap(),
        -1.0 / 3.0
    );
    // A run over different pairs is refused.
    let partial = write_hyps(&f, "partial", &[("b-1-1", "none", "เรียกแกร็บไปสยาม")]);
    assert!(
        score_hyps(&root, &partial, &f.0.join("rp"), false)
            .status
            .success()
    );
    let r = tool()
        .args(["contextasr", "compare", "--baseline"])
        .arg(f.0.join("rb"))
        .arg("--candidate")
        .arg(f.0.join("rp"))
        .arg("--out")
        .arg(f.0.join("cmp/bad.md"))
        .output()
        .unwrap();
    assert!(!r.status.success());
}

#[test]
fn contextasr_rejects_duplicate_and_unknown_hypotheses() {
    let f = Fixture::new();
    let root = contextasr_fixture(&f);
    let dup = write_hyps(&f, "dup", &[("c-1-1", "none", "a"), ("c-1-1", "none", "b")]);
    assert!(
        !score_hyps(&root, &dup, &f.0.join("o1"), false)
            .status
            .success()
    );
    let unknown = write_hyps(&f, "unknown", &[("z-9-9", "none", "a")]);
    assert!(
        !score_hyps(&root, &unknown, &f.0.join("o2"), false)
            .status
            .success()
    );
    let unlisted = write_hyps(&f, "unlisted", &[("c-1-1", "bias@0", "a")]);
    assert!(
        !score_hyps(&root, &unlisted, &f.0.join("o3"), false)
            .status
            .success()
    );
}

#[test]
fn contextasr_compare_restricts_to_a_shard() {
    let f = Fixture::new();
    let root = contextasr_fixture(&f);
    let rows = [
        ("b-1-1", "none", "เรียกแกร็บ"),
        ("c-1-1", "none", "วันนี้อากาศดี"),
    ];
    let hyps = write_hyps(&f, "h", &rows);
    assert!(
        score_hyps(&root, &hyps, &f.0.join("r"), false)
            .status
            .success()
    );
    let mut sizes = Vec::new();
    for shard in ["0/2", "1/2"] {
        let out = f.0.join(format!("cmp{}.md", &shard[..1]));
        let r = tool()
            .args(["contextasr", "compare", "--shard", shard, "--baseline"])
            .arg(f.0.join("r"))
            .arg("--candidate")
            .arg(f.0.join("r"))
            .arg("--out")
            .arg(&out)
            .output()
            .unwrap();
        // An empty shard is refused rather than reported as zero deltas.
        if r.status.success() {
            let cmp: Value =
                serde_json::from_slice(&std::fs::read(out.with_extension("json")).unwrap())
                    .unwrap();
            sizes.push(cmp["n_pairs"].as_u64().unwrap());
        } else {
            sizes.push(0);
        }
    }
    assert_eq!(sizes.iter().sum::<u64>(), 2);
}
