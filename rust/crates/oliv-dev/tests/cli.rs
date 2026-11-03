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
fn contextasr_replay_refuses_a_missing_file_or_transcript() {
    let f = Fixture::new();
    let root = contextasr_fixture(&f);
    let run = |replay: &PathBuf| {
        tool()
            .args([
                "contextasr",
                "run",
                "--allow-unpinned",
                "--pipeline",
                "vocab",
            ])
            .args(["--conditions", "none", "--data-dir"])
            .arg(&root)
            .arg("--runtime-dir")
            .arg(f.0.join("no-runtime"))
            .arg("--stt-replay")
            .arg(replay)
            .arg("--out")
            .arg(f.0.join("out"))
            .output()
            .unwrap()
    };
    let absent = run(&f.0.join("absent.jsonl"));
    assert!(!absent.status.success());
    assert!(String::from_utf8_lossy(&absent.stderr).contains("--stt-replay file not found"));

    let partial = f.0.join("partial.jsonl");
    std::fs::write(
        &partial,
        json!({"utt_id":"b-1-1","raw":"เรียกแกร็บไปสยาม"}).to_string(),
    )
    .unwrap();
    let missing = run(&partial);
    assert!(!missing.status.success());
    let stderr = String::from_utf8_lossy(&missing.stderr);
    assert!(
        stderr.contains("1 of 2 selected utterances: c-1-1"),
        "{stderr}"
    );
    assert!(
        !f.0.join("out").exists(),
        "nothing is written for an incomplete replay"
    );
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

/// A corpus with five recorded sentences in every bucket the kit draws from.
fn speaker_corpus(f: &Fixture) -> (PathBuf, PathBuf) {
    let audio = f.0.join("corpus");
    std::fs::create_dir_all(audio.join("clips")).unwrap();
    let mut manifest = String::from("# fixture\n");
    for bucket in [
        "th", "xg", "lf", "en", "mx", "hx", "tc", "vb", "pn", "nu", "nm", "fm", "fl",
    ] {
        for i in 0..5 {
            let id = format!("{bucket}{i:02}");
            std::fs::write(audio.join(format!("clips/{id}.wav")), b"").unwrap();
            manifest.push_str(
                &json!({"id":id,"path":format!("clips/{id}.wav"),"reference":format!("PRIVATE-REF {id}")})
                    .to_string(),
            );
            manifest.push('\n');
        }
    }
    let path = f.0.join("manifest.jsonl");
    std::fs::write(&path, manifest).unwrap();
    (path, audio)
}
fn kit_command(manifest: &PathBuf, audio: &PathBuf, out: &PathBuf, seed: &str) -> Command {
    let mut c = tool();
    c.args(["speakers", "kit", "--seed", seed, "--manifests"])
        .arg(manifest)
        .arg("--audio-root")
        .arg(audio)
        .arg("--out")
        .arg(out);
    c
}

#[test]
fn speakers_kit_stays_out_of_commits_and_keeps_its_ids_stable() {
    let f = Fixture::new();
    let (manifest, audio) = speaker_corpus(&f);
    let repo = f.0.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .arg(&repo)
            .status()
            .unwrap()
            .success()
    );
    std::fs::write(repo.join(".gitignore"), "private/\n").unwrap();
    let tracked = kit_command(&manifest, &audio, &repo.join("public/kit"), "1")
        .output()
        .unwrap();
    assert!(!tracked.status.success());
    assert!(String::from_utf8_lossy(&tracked.stderr).contains("not ignored"));
    assert!(!repo.join("public").exists());

    let out = repo.join("private/speakers");
    let ok = kit_command(&manifest, &audio, &out, "1").output().unwrap();
    assert!(
        ok.status.success(),
        "{}",
        String::from_utf8_lossy(&ok.stderr)
    );
    assert!(!String::from_utf8_lossy(&ok.stdout).contains("PRIVATE-REF"));
    let kit = std::fs::read_to_string(out.join("kit.jsonl")).unwrap();
    let rows: Vec<Value> = kit
        .lines()
        .filter(|l| !l.starts_with('#'))
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(rows.len(), 30);
    let script = std::fs::read_to_string(out.join("script.md")).unwrap();
    assert!(script.contains("ความยินยอม") && script.contains("QuickTime Player"));
    assert!(script.contains(&format!("(`{}`)", rows[0]["id"].as_str().unwrap())));
    let consent: Value =
        serde_json::from_slice(&std::fs::read(out.join("consent.example.json")).unwrap()).unwrap();
    assert_eq!(consent["agreed"], false);

    // Same seed: same kit. Another seed would rename what people recorded.
    assert!(
        kit_command(&manifest, &audio, &out, "1")
            .status()
            .unwrap()
            .success()
    );
    let other = kit_command(&manifest, &audio, &out, "2").output().unwrap();
    assert!(!other.status.success());
    assert!(String::from_utf8_lossy(&other.stderr).contains("--force"));
    assert_eq!(std::fs::read_to_string(out.join("kit.jsonl")).unwrap(), kit);
}

#[test]
fn speakers_score_needs_consent_before_any_model_starts() {
    let f = Fixture::new();
    let (manifest, audio) = speaker_corpus(&f);
    let dir = f.0.join("speakers");
    assert!(
        kit_command(&manifest, &audio, &dir, "1")
            .status()
            .unwrap()
            .success()
    );
    let kit = std::fs::read_to_string(dir.join("kit.jsonl")).unwrap();
    let first: Value = serde_json::from_str(kit.lines().nth(1).unwrap()).unwrap();
    let id = first["id"].as_str().unwrap();
    for name in ["s1", "s2"] {
        std::fs::create_dir_all(dir.join(name)).unwrap();
        std::fs::write(dir.join(name).join(format!("{id}.m4a")), b"").unwrap();
    }
    std::fs::write(dir.join("s1/notes.txt"), b"").unwrap();
    std::fs::write(
        dir.join("s2/consent.json"),
        json!({"agreed": false, "date": "YYYY-MM-DD"}).to_string(),
    )
    .unwrap();
    let score = || {
        tool()
            .args(["speakers", "score", "--model-dir"])
            .arg(f.0.join("no-labse"))
            .arg("--speakers-dir")
            .arg(&dir)
            .arg("--audio-root")
            .arg(&audio)
            .args(["--runtime-dir", "/nonexistent/runtime"])
            .arg("--out")
            .arg(f.0.join("out"))
            .output()
            .unwrap()
    };
    let refused = score();
    assert!(!refused.status.success());
    let stdout = String::from_utf8_lossy(&refused.stdout);
    assert!(
        stdout.contains("Skipped s1: no readable consent.json"),
        "{stdout}"
    );
    assert!(
        stdout.contains("Skipped s2: consent.json needs"),
        "{stdout}"
    );
    assert!(String::from_utf8_lossy(&refused.stderr).contains("No consented speaker"));

    std::fs::write(
        dir.join("s2/consent.json"),
        json!({"agreed": true, "date": "2026-11-03", "mic": "built-in"}).to_string(),
    )
    .unwrap();
    let accepted = score();
    assert!(!accepted.status.success());
    // s2 is accepted; the run then stops at the missing LaBSE snapshot.
    assert!(String::from_utf8_lossy(&accepted.stderr).contains("No LaBSE snapshot"));
    assert!(!f.0.join("out/results.json").exists());
}

#[test]
fn speakers_report_rebuilds_aggregates_without_transcripts() {
    let f = Fixture::new();
    let clip = |speaker: &str, sentence: &str, sim: f64| {
        json!({"speaker":speaker,"sentence":sentence,"group":"everyday","id":sentence,
            "reference":"SECRET reference","raw":"SECRET raw","final":"SECRET final",
            "sim":sim,"raw_sim":sim,"wer":0.1,"cer":0.05,"raw_wer":0.2,"raw_cer":0.1,"latency_s":1.2})
    };
    let results = f.json(
        "results.json",
        &json!({"kind":"speakers","meta":{"git_commit":"0123456789"},
            "groups":[{"key":"everyday","label":"Everyday","buckets":["th"]}],
            "speakers":[{"name":"developer","baseline":true},{"name":"s1","mic":"built-in"},{"name":"s2"}],
            "clips":[clip("developer","th01",0.9),clip("developer","th02",0.9),
                     clip("s1","th01",0.5),clip("s2","th01",0.9),clip("s2","th02",0.85)]}),
    );
    let r = tool()
        .args(["speakers", "report", "--results"])
        .arg(&results)
        .output()
        .unwrap();
    assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stderr));
    let md = std::fs::read_to_string(f.0.join("report.md")).unwrap();
    let summary = std::fs::read_to_string(f.0.join("summary.json")).unwrap();
    for text in [
        &md,
        &summary,
        &String::from_utf8_lossy(&r.stdout).into_owned(),
    ] {
        assert!(!text.contains("SECRET"));
    }
    assert!(md.contains("All 2 people, pooled"), "{md}");
    let summary: Value = serde_json::from_str(&summary).unwrap();
    assert_eq!(summary["speakers"]["s1"]["meaning_match_pct"], 0.0);
    assert_eq!(summary["against_baseline"]["s2"]["sentences"], 2);

    let fleurs = f.json(
        "fleurs.json",
        &json!({"kind":"fleurs","meta":{"seed":"2026","sentences_sampled":1,"sentences_with_readers":3},
            "clips":[clip("a","1",0.9),clip("b","1",0.6)]}),
    );
    std::fs::create_dir_all(f.0.join("fl")).unwrap();
    std::fs::rename(&fleurs, f.0.join("fl/results.json")).unwrap();
    let r = tool()
        .args(["speakers", "report", "--results"])
        .arg(f.0.join("fl/results.json"))
        .output()
        .unwrap();
    assert!(r.status.success());
    let md = std::fs::read_to_string(f.0.join("fl/report.md")).unwrap();
    assert!(md.contains("Readers disagree") && !md.contains("SECRET"));
}
