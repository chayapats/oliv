//! Accuracy on voices other than the developer's: a private recording kit,
//! per-speaker scoring next to the developer's recordings of the same
//! sentences, and a public multi-reader proxy on FLEURS Thai (CC-BY-4.0).
//! Reference text, audio and transcripts stay in gitignored files; Markdown
//! reports and summaries hold aggregates only.
mod stats;

use crate::contextasr::{CLEANUP_REPO, command_line, engine_repo, model_revision, sha256_hex};
use crate::worker::Worker;
use crate::{Pipeline, Result, benchmark_path, metrics, read_json, similarity, write_json};
use clap::{Args, Subcommand};
use serde_json::{Value, json};
use stats::{Clip, Group, Speaker};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const KIT_FILE: &str = "kit.jsonl";
/// The developer's recordings of the kit sentences, scored in the same run.
pub const BASELINE: &str = "developer";
const AUDIO_EXTENSIONS: &[&str] = &[
    "wav", "m4a", "aiff", "aif", "caf", "mp3", "flac", "ogg", "webm", "mp4",
];
/// Kit groups (the issue's buckets) and the corpus buckets each draws from.
/// (group key, label, [(corpus bucket, sentences)]).
pub type KitGroup = (&'static str, &'static str, &'static [(&'static str, usize)]);
pub const KIT_PLAN: &[KitGroup] = &[
    (
        "everyday",
        "Everyday Thai and English",
        &[("th", 3), ("xg", 2), ("lf", 1), ("en", 2)],
    ),
    (
        "tech",
        "Thai–English tech talk",
        &[("mx", 3), ("hx", 4), ("tc", 2), ("vb", 3)],
    ),
    ("names", "Names and places", &[("pn", 2), ("nu", 2)]),
    ("numbers", "Numbers and dates", &[("nm", 3)]),
    (
        "formatting",
        "Spoken formatting and fillers",
        &[("fm", 2), ("fl", 1)],
    ),
];
/// google/fleurs revision and the sha256 of its `data/th_th/test.tsv`.
pub const FLEURS_REVISION: &str = "70bb2e84b976b7e960aa89f1c648e09c59f894dd";
pub const FLEURS_TSV_SHA256: &str =
    "8db09d12ac384654f6677e141f6e55bf5bc42028160cbc0d2d9f7fac4fe25271";

#[derive(Subcommand)]
pub enum Task {
    /// Write the private recording kit: sentence list, speaker script, consent template.
    Kit(KitArgs),
    /// Score every consented speaker next to the developer on the same sentences.
    Score(ScoreArgs),
    /// Rebuild report.md and summary.json from a results.json (no models).
    Report(ReportArgs),
    /// Record the kit with a macOS text-to-speech voice: a synthetic speaker.
    Synth(SynthArgs),
    /// Multi-reader proxy: FLEURS Thai sentences, each read by up to three people.
    Fleurs(FleursArgs),
}

#[derive(Args)]
pub struct KitArgs {
    /// Corpus manifests to draw from, comma-separated. D2 is left out by
    /// default because its `nu` bucket holds numbers, not names.
    #[arg(
        long,
        default_value = "data/manifest_all.jsonl,data/manifest_holdout.jsonl"
    )]
    pub manifests: String,
    /// Root of the developer's recordings named by each row's `path`.
    #[arg(long, default_value = "data")]
    pub audio_root: PathBuf,
    #[arg(long, default_value = "2026")]
    pub seed: String,
    /// Private output directory; inside a checkout it must be gitignored.
    #[arg(long, default_value = "data/speakers")]
    pub out: PathBuf,
    /// Replace a different existing kit (recordings are named after its ids).
    #[arg(long)]
    pub force: bool,
}

#[derive(Args)]
pub struct ScoreArgs {
    /// LaBSE snapshot directory (config.json, tokenizer.json, model.safetensors).
    #[arg(long)]
    pub model_dir: PathBuf,
    /// Holds kit.jsonl and one directory of recordings per speaker.
    #[arg(long, default_value = "data/speakers")]
    pub speakers_dir: PathBuf,
    /// Only these speakers (comma-separated directory names).
    #[arg(long, default_value = "")]
    pub only: String,
    /// Root of the developer's recordings named by the kit's `path`.
    #[arg(long, default_value = "data")]
    pub audio_root: PathBuf,
    #[arg(long, default_value = "typhoon-turbo-mlx")]
    pub engine: String,
    #[arg(long, default_value = "build/native-runtime")]
    pub runtime_dir: PathBuf,
    #[arg(long, default_value = "build/native-tools")]
    pub tools_dir: PathBuf,
    /// Output directory: results.json (private), summary.json and report.md.
    #[arg(long, default_value = "benchmark/eval_results/speakers")]
    pub out: PathBuf,
}

#[derive(Args)]
pub struct ReportArgs {
    /// results.json from `score` or `fleurs`; the report is written next to it.
    #[arg(long)]
    pub results: PathBuf,
}

#[derive(Args)]
pub struct SynthArgs {
    /// macOS voice (`say -v '?'` lists them); Kanya is the built-in Thai voice.
    #[arg(long, default_value = "Kanya")]
    pub voice: String,
    /// Speaker directory name; default tts-<voice>.
    #[arg(long)]
    pub name: Option<String>,
    #[arg(long, default_value = "data/speakers")]
    pub speakers_dir: PathBuf,
}

#[derive(Args)]
pub struct FleursArgs {
    #[arg(long, required_unless_present = "manifest_out")]
    pub model_dir: Option<PathBuf>,
    /// Output of scripts/fetch_fleurs_th.sh. Default: $OLIV_FLEURS_DIR or
    /// ~/.cache/oliv-bench/fleurs-th.
    #[arg(long)]
    pub data_dir: Option<PathBuf>,
    /// Sentences to sample, each with every recording of it (0 = all).
    #[arg(long, default_value_t = 80)]
    pub sentences: usize,
    #[arg(long, default_value = "2026")]
    pub seed: String,
    #[arg(long, default_value = "typhoon-turbo-mlx")]
    pub engine: String,
    #[arg(long, default_value = "build/native-runtime")]
    pub runtime_dir: PathBuf,
    #[arg(long, default_value = "build/native-tools")]
    pub tools_dir: PathBuf,
    #[arg(long, default_value = "benchmark/eval_results/fleurs")]
    pub out: PathBuf,
    /// Accept a test.tsv that differs from the pinned revision (fixtures only).
    #[arg(long)]
    pub allow_unpinned: bool,
    /// Only write the sampled recordings as an `eval` manifest (absolute audio
    /// paths; pass `--audio-root /`) to this ignored file, and run nothing:
    /// the same clips for engines outside the sidecar.
    #[arg(long)]
    pub manifest_out: Option<PathBuf>,
}

pub fn main(task: Task) -> Result<()> {
    match task {
        Task::Kit(args) => kit(args),
        Task::Score(args) => score(args),
        Task::Report(args) => {
            let results = read_json(&args.results)?;
            let dir = args.results.parent().unwrap_or(Path::new("."));
            render(&results, dir)
        }
        Task::Synth(args) => synth(args),
        Task::Fleurs(args) => fleurs(args),
    }
}

/// Inside a git checkout, private text and audio may only go to ignored paths:
/// every file in `files` that will be written under `dir` must be ignored.
/// Outside a checkout there is nothing to protect. A git that can't answer is
/// an error, never permission.
pub(crate) fn ensure_private(dir: &Path, files: &[String]) -> Result<()> {
    let absolute = if dir.is_absolute() {
        dir.to_path_buf()
    } else {
        std::env::current_dir()?.join(dir)
    };
    let mut base = absolute.clone();
    let mut rest = Vec::new();
    while !base.exists() {
        rest.push(
            base.file_name()
                .ok_or("Output directory has no usable name")?
                .to_owned(),
        );
        if !base.pop() {
            break;
        }
    }
    let base = base.canonicalize()?;
    let mut target = base.clone();
    for part in rest.iter().rev() {
        target.push(part);
    }
    let git = |args: &[&str], path: Option<&Path>| {
        let mut command = Command::new("git");
        command.arg("-C").arg(&base).args(args);
        if let Some(path) = path {
            command.arg(path);
        }
        command
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|e| {
                format!(
                    "Could not run git to check that {} stays private: {e}",
                    dir.display()
                )
            })
    };
    // 0 = inside a work tree, 128 = not a checkout at all.
    match git(&["rev-parse", "--is-inside-work-tree"], None)?.code() {
        Some(0) => {}
        Some(128) => return Ok(()),
        other => {
            return Err(format!(
                "git failed ({other:?}) checking {}; not writing private files",
                dir.display()
            )
            .into());
        }
    }
    for file in files {
        // 0 = ignored, 1 = would be committed.
        match git(&["check-ignore", "-q", "--"], Some(&target.join(file)))?.code() {
            Some(0) => {}
            Some(1) => {
                return Err(format!(
                    "{} is in a git checkout and {file} there is not ignored; recordings, reference text and transcripts must stay out of commits",
                    dir.display()
                )
                .into())
            }
            other => {
                return Err(format!("git failed ({other:?}) checking {}; not writing private files", dir.display()).into())
            }
        }
    }
    Ok(())
}

/// `synth` writes into a speaker directory only when it is new, empty, or
/// already holds the SAME synthetic voice: never over a person's recordings
/// or consent, and never mixing two voices under one name.
pub(crate) fn check_synth_target(out: &Path, voice: &str) -> Result<()> {
    let Ok(mut entries) = std::fs::read_dir(out) else {
        return Ok(());
    };
    if entries.next().is_none() {
        return Ok(());
    }
    let meta: Option<Value> = std::fs::read(out.join("consent.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok());
    match meta {
        Some(m) if m["synthetic"] == true && m["voice"] == voice => Ok(()),
        Some(m) if m["synthetic"] == true => Err(format!(
            "{} holds the synthetic voice {}, not {voice}; pass a different --name",
            out.display(),
            m["voice"]
        )
        .into()),
        _ => Err(format!(
            "{} already holds recordings that are not this synthetic voice; pass a different --name",
            out.display()
        )
        .into()),
    }
}

/// What the speaker says: the row's `say` (fillers, spoken commands) or its
/// reference. A multi-line reference without `say` cannot be read aloud
/// unambiguously and is not used.
pub(crate) fn speakable(row: &Value) -> Option<String> {
    let reference = row["reference"].as_str()?.trim();
    if reference.is_empty() {
        return None;
    }
    match row["say"].as_str().map(str::trim) {
        Some(say) if !say.is_empty() && !say.contains('\n') => Some(say.to_owned()),
        Some(_) => None,
        None if reference.contains('\n') => None,
        None => Some(reference.to_owned()),
    }
}

/// Deterministic kit: per bucket, the first usable rows in sha256(seed:id)
/// order. Rows need `_audio: true` (the developer's recording exists).
pub(crate) fn select_kit(rows: &[Value], seed: &str) -> Result<Vec<Value>> {
    let mut ids = BTreeSet::new();
    let mut pools: BTreeMap<String, Vec<(String, &Value, String)>> = BTreeMap::new();
    for row in rows {
        let id = row["id"].as_str().ok_or("Manifest row has no id")?;
        if !ids.insert(id) {
            return Err(format!("Duplicate manifest id {id}").into());
        }
        if row["_audio"] != true {
            continue;
        }
        if let Some(say) = speakable(row) {
            pools.entry(metrics::bucket(id)).or_default().push((
                sha256_hex(format!("{seed}:{id}").as_bytes()),
                row,
                say,
            ));
        }
    }
    let mut kit = Vec::new();
    for (group, _, plan) in KIT_PLAN {
        for (bucket, count) in *plan {
            let mut pool = pools.remove(*bucket).unwrap_or_default();
            if pool.len() < *count {
                return Err(format!(
                    "Bucket {bucket} has {} usable recorded sentences; the kit needs {count}",
                    pool.len()
                )
                .into());
            }
            pool.sort_by(|a, b| a.0.cmp(&b.0));
            for (_, row, say) in pool.into_iter().take(*count) {
                let mut item = json!({"n":kit.len()+1,"id":row["id"],"group":group,"bucket":bucket,
                    "source":row["_source"],"say":say,"reference":row["reference"],"path":row["path"]});
                for key in ["keywords", "vocab", "dictionary"] {
                    if let Some(v) = row.get(key) {
                        item[key] = v.clone();
                    }
                }
                kit.push(item);
            }
        }
    }
    Ok(kit)
}

fn groups_json() -> Value {
    KIT_PLAN
        .iter()
        .map(|(key, label, plan)| {
            json!({"key":key,"label":label,"buckets":plan.iter().map(|(b, _)| *b).collect::<Vec<_>>()})
        })
        .collect()
}

const SCRIPT_TH: &str = "\
# ชุดอัดเสียงทดสอบ OLIV

ตัวเลขความแม่นยำของ OLIV ตอนนี้วัดจากเสียงของผู้พัฒนาเพียงคนเดียว เราอยากรู้ว่าเมื่อเป็นเสียง สำเนียง \
และไมโครโฟนของคนอื่น OLIV ยังจับใจความได้ดีเท่าเดิมหรือไม่ ชุดนี้มี {N} ประโยค ใช้เวลาราว 15–20 นาที

## ความยินยอม

- ไฟล์เสียงของคุณใช้วัดความแม่นยำของ OLIV เท่านั้น เก็บไว้ในเครื่องของผู้ดูแลโครงการ ไม่อัปโหลดขึ้น GitHub และไม่เผยแพร่
- สิ่งที่เผยแพร่มีแค่ตัวเลขสรุป เช่น เปอร์เซ็นต์ประโยคที่ได้ความหมายถูก โดยใช้ชื่อแทนอย่าง s1 ไม่ใช้ชื่อจริง
- ถอนความยินยอมได้ทุกเมื่อ แค่บอกผู้ดูแล ไฟล์เสียงของคุณจะถูกลบ
- ถ้ายินยอม บอกผู้ดูแลได้เลย ผู้ดูแลจะบันทึกวันที่ที่คุณยินยอม พร้อมรุ่นไมโครโฟนและลักษณะห้องที่ใช้อัด

## วิธีอัดบน Mac

1. อัดในห้องที่เงียบ ใช้ไมโครโฟนในตัวของ Mac หรือไมโครโฟนที่ใช้อยู่ประจำ และใช้ตัวเดียวกันทุกประโยค
2. เปิด QuickTime Player แล้วเลือก File > New Audio Recording (⌥⌘N) กดลูกศรข้างปุ่มอัดเพื่อเลือกไมโครโฟน
3. กดอัด เว้นจังหวะครู่หนึ่ง พูดหนึ่งประโยค แล้วกดหยุด
4. เลือก File > Save แล้วตั้งชื่อไฟล์ตามรหัสในวงเล็บ เช่น `th03.m4a`
5. อัดครบแล้ว ส่งไฟล์ทั้งหมดให้ผู้ดูแลทางช่องทางส่วนตัว เช่น AirDrop

## พูดอย่างไร

- พูดเป็นธรรมชาติเหมือนพิมพ์ด้วยเสียงตอนทำงาน ไม่ต้องอ่านแบบผู้ประกาศข่าว คำภาษาอังกฤษออกเสียงตามที่พูดปกติ
- พูดให้ครบทุกคำ รวมถึงคำเติมอย่าง \"เอ่อ\" \"อืม\" และคำสั่งอย่าง \"ขึ้นบรรทัดใหม่\" หรือ \"new line\" ที่อยู่ในประโยค
- ถ้าพูดผิดหรือสะดุด อัดใหม่ได้เลย ใช้เทคที่พูดครบ

";

const SCRIPT_EN: &str = "\
# OLIV recording kit

OLIV's accuracy figures come from one speaker, the developer. This kit checks whether other voices, \
accents and microphones get the same results. It has {N} sentences and takes about 15–20 minutes.

## Consent

- Your recordings are used only to measure OLIV's accuracy. They stay on the maintainer's computer, \
are never uploaded to GitHub and are never published.
- Only summary numbers are published, such as the share of sentences whose meaning came out right, \
under a pseudonym such as s1, never your name.
- You can withdraw at any time: tell the maintainer and your recordings are deleted.
- If you agree, tell the maintainer. They record the date you agreed, your microphone and the kind of room.

## Recording on a Mac

1. Use a quiet room and the Mac's built-in microphone or the one you normally use. Keep the same one for every sentence.
2. Open QuickTime Player and choose File > New Audio Recording (⌥⌘N). Pick the microphone with the arrow next to the record button.
3. Press record, wait a moment, say one sentence, then press stop.
4. Choose File > Save and name the file after the code in brackets, for example `th03.m4a`.
5. When you are done, send all files to the maintainer privately, for example over AirDrop.

## How to speak

- Speak naturally, as when you dictate at work, not like a news reader. Say English words the way you usually do.
- Say every word, including fillers such as \"เอ่อ\" or \"อืม\" and spoken commands such as \"ขึ้นบรรทัดใหม่\" or \"new line\".
- If you stumble, record that sentence again. Keep a take where you said every word.

";

fn script(kit: &[Value]) -> String {
    let n = kit.len().to_string();
    let mut md = format!(
        "<!-- Private: generated by `oliv-dev speakers kit`. Never commit or publish. -->\n\n{}{}## ประโยคที่ต้องอัด / Sentences\n\n",
        SCRIPT_TH.replace("{N}", &n),
        SCRIPT_EN.replace("{N}", &n)
    );
    for row in kit {
        md.push_str(&format!(
            "**{}.** (`{}`)\n> {}\n\n",
            row["n"],
            row["id"].as_str().unwrap_or(""),
            row["say"].as_str().unwrap_or("")
        ));
    }
    md
}

fn consent_template() -> Value {
    json!({"agreed": false, "date": "YYYY-MM-DD",
        "scope": "Recordings used only to measure OLIV accuracy; kept private; aggregate results published under this directory's pseudonym.",
        "mic": "MacBook Pro built-in microphone", "room": "quiet room", "notes": ""})
}

fn kit(args: KitArgs) -> Result<()> {
    let audio_root = benchmark_path(&args.audio_root);
    let mut rows = Vec::new();
    for name in args
        .manifests
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        let path = benchmark_path(Path::new(name));
        let source = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        for line in std::fs::read_to_string(&path)
            .map_err(|e| format!("Cannot read manifest {}: {e}", path.display()))?
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
        {
            let mut row: Value = serde_json::from_str(line)?;
            let recorded = row["path"]
                .as_str()
                .is_some_and(|p| audio_root.join(p).is_file());
            row["_source"] = source.clone().into();
            row["_audio"] = recorded.into();
            rows.push(row);
        }
    }
    let kit = select_kit(&rows, &args.seed)?;
    let out = benchmark_path(&args.out);
    let written = [KIT_FILE, "script.md", "consent.example.json"].map(String::from);
    ensure_private(&out, &written)?;
    std::fs::create_dir_all(&out)?;
    let mut body = format!(
        "# Private OLIV recording kit (seed {}). Generated by `oliv-dev speakers kit`; never commit.\n",
        args.seed
    );
    for row in &kit {
        body.push_str(&serde_json::to_string(row)?);
        body.push('\n');
    }
    let path = out.join(KIT_FILE);
    if path.is_file() && !args.force && std::fs::read_to_string(&path)? != body {
        return Err(format!(
            "A different kit exists at {}; recordings are named after its ids. Pass --force to replace it",
            path.display()
        )
        .into());
    }
    std::fs::write(&path, body)?;
    std::fs::write(out.join("script.md"), script(&kit))?;
    write_json(&out.join("consent.example.json"), &consent_template())?;
    println!(
        "Wrote a {}-sentence kit, script.md and consent.example.json to {}",
        kit.len(),
        out.display()
    );
    Ok(())
}

fn load_kit(path: &Path) -> Result<Vec<Value>> {
    let text = std::fs::read_to_string(path).map_err(|_| {
        format!(
            "No kit at {}; run `oliv-dev speakers kit` first",
            path.display()
        )
    })?;
    let kit: Vec<Value> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(serde_json::from_str)
        .collect::<std::result::Result<_, _>>()?;
    if kit.is_empty() {
        return Err("The kit is empty".into());
    }
    Ok(kit)
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 32
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
        && name.as_bytes()[0].is_ascii_alphanumeric()
}

struct Voice {
    info: Value,
    clips: BTreeMap<String, PathBuf>,
}

/// Speaker directories with a usable consent record, and their recordings by
/// kit id. Returns notes about skipped directories and stray files.
fn discover(
    dir: &Path,
    kit: &[Value],
    only: &BTreeSet<String>,
) -> Result<(Vec<Voice>, Vec<String>)> {
    let ids: BTreeSet<&str> = kit.iter().filter_map(|r| r["id"].as_str()).collect();
    let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_dir())
        .collect();
    entries.sort();
    let mut voices = Vec::new();
    let mut notes = Vec::new();
    let mut seen = BTreeSet::new();
    for path in entries {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if name.starts_with('.') || (!only.is_empty() && !only.contains(&name)) {
            continue;
        }
        seen.insert(name.clone());
        if !valid_name(&name) || name == BASELINE {
            notes.push(format!(
                "Skipped {name:?}: use a short lowercase pseudonym such as s1 (\"{BASELINE}\" is the baseline)"
            ));
            continue;
        }
        let consent = match std::fs::read(path.join("consent.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        {
            Some(c) => c,
            None => {
                notes.push(format!(
                    "Skipped {name}: no readable consent.json (copy consent.example.json)"
                ));
                continue;
            }
        };
        let synthetic = consent["synthetic"] == true;
        let dated = consent["date"]
            .as_str()
            .is_some_and(|d| !d.trim().is_empty() && d != "YYYY-MM-DD");
        if !synthetic && !(consent["agreed"] == true && dated) {
            notes.push(format!(
                "Skipped {name}: consent.json needs \"agreed\": true and the date they agreed"
            ));
            continue;
        }
        let mut clips = BTreeMap::new();
        let mut stray = 0;
        for file in std::fs::read_dir(&path)?.filter_map(|e| e.ok().map(|e| e.path())) {
            let file_name = file
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            if !file.is_file() || file_name.starts_with('.') || file_name == "consent.json" {
                continue;
            }
            let (stem, ext) = match file_name.rsplit_once('.') {
                Some((s, e)) => (s.to_owned(), e.to_ascii_lowercase()),
                None => (file_name.clone(), String::new()),
            };
            if !ids.contains(stem.as_str()) || !AUDIO_EXTENSIONS.contains(&ext.as_str()) {
                stray += 1;
                continue;
            }
            if clips.insert(stem.clone(), file).is_some() {
                return Err(format!("{name} has two recordings of {stem}; keep one").into());
            }
        }
        if stray > 0 {
            notes.push(format!(
                "{name}: ignored {stray} file(s) not named <kit id>.<audio extension>"
            ));
        }
        let missing = ids.len() - clips.len();
        voices.push(Voice {
            info: json!({"name":name,"baseline":false,"synthetic":synthetic,
                "mic":consent["mic"].as_str().unwrap_or(""),"room":consent["room"].as_str().unwrap_or(""),
                "voice":consent["voice"].clone(),"missing":missing}),
            clips,
        });
    }
    if let Some(unknown) = only.iter().find(|n| !seen.contains(*n)) {
        return Err(format!("No speaker directory {unknown} under {}", dir.display()).into());
    }
    Ok((voices, notes))
}

fn environment(engine: &str, runtime_dir: &Path) -> Value {
    let hash = |p: PathBuf| std::fs::read(p).ok().map(|b| sha256_hex(&b));
    json!({
        "date": command_line("date", &["+%F"]),
        "git_commit": command_line("git", &["rev-parse", "HEAD"]),
        "git_dirty": command_line("git", &["status", "--porcelain", "--untracked-files=no"]).map(|s| !s.is_empty()),
        "engine": engine, "engine_repo": engine_repo(engine), "engine_revision": model_revision(engine_repo(engine)),
        "cleanup_repo": CLEANUP_REPO, "cleanup_revision": model_revision(CLEANUP_REPO),
        "sidecar_sha256": hash(runtime_dir.join("oliv-sidecar")),
        "inference_sha256": hash(runtime_dir.join("oliv-inference")),
        "macos": command_line("sw_vers", &["-productVersion"]),
        "chip": command_line("sysctl", &["-n", "machdep.cpu.brand_string"]),
        "metric_version": "newmm_nfc_v1",
        "semantic": {"model": "sentence-transformers/LaBSE", "threshold": stats::THRESHOLD,
            "metric_version": "v2_newmm_seg_native_mlx"},
    })
}

/// One clip per (row, audio); each result carries `speaker`, `sentence` and
/// `group`. A first discarded clip keeps model warm-up out of the latencies.
fn run_clips(
    pipeline: &Pipeline,
    runtime_dir: &Path,
    tools_dir: &Path,
    model_dir: &Path,
    jobs: &[(String, &Value, PathBuf)],
) -> Result<Vec<Value>> {
    if !model_dir.join("model.safetensors").is_file() {
        return Err(format!(
            "No LaBSE snapshot at {} (needs config.json, tokenizer.json, model.safetensors)",
            model_dir.display()
        )
        .into());
    }
    let mut clips = Vec::new();
    {
        let mut runtime = pipeline.start(runtime_dir)?;
        if let Some((_, row, audio)) = jobs.first() {
            pipeline.dictate(&mut runtime, row, audio, None)?;
        }
        for (speaker, row, audio) in jobs {
            // One retry: a busy machine can push a single decode past the
            // sidecar's timeouts without anything being wrong with the clip.
            let mut clip = match pipeline.dictate(&mut runtime, row, audio, None) {
                Ok(clip) => clip,
                Err(e) => {
                    println!("Retrying clip {} after: {e}", clips.len() + 1);
                    pipeline.dictate(&mut runtime, row, audio, None)?
                }
            };
            let attempts = retry_cleanup(pipeline, &mut runtime, row, audio, &mut clip);
            clip["cleanup_attempts"] = attempts.into();
            let raw = metrics::score(
                row["reference"].as_str().unwrap_or(""),
                clip["raw"].as_str().unwrap_or(""),
                &[],
            );
            clip["raw_wer"] = raw["wer"].clone();
            clip["raw_cer"] = raw["cer"].clone();
            clip["speaker"] = speaker.clone().into();
            clip["sentence"] = row["sentence"].clone();
            clip["group"] = row["group"].clone();
            clips.push(clip);
            println!("Dictated {}/{} clips", clips.len(), jobs.len());
        }
    }
    let mut semantic = Worker::new(
        tools_dir,
        "oliv-semantic",
        &[model_dir.to_string_lossy().into_owned()],
    )?;
    for clip in &mut clips {
        let reference = clip["reference"].as_str().unwrap_or("").to_owned();
        let sim = similarity(
            &mut semantic,
            &reference,
            clip["final"].as_str().unwrap_or(""),
        )?;
        let raw_sim = similarity(
            &mut semantic,
            &reference,
            clip["raw"].as_str().unwrap_or(""),
        )?;
        clip["sim"] = sim.into();
        clip["raw_sim"] = raw_sim.into();
    }
    println!("Scored meaning for {} clips", clips.len());
    Ok(clips)
}

/// Cleanup attempts allowed per clip. A timeout says the machine was busy,
/// not what the model writes, so a timed-out cleanup is replayed on the same
/// transcript.
const CLEANUP_ATTEMPTS: u32 = 3;
/// Keys a cleanup replay replaces; the transcript, STT time and end-to-end
/// latency stay those of the first decode.
const CLEANUP_KEYS: &[&str] = &[
    "final",
    "llm_ran",
    "guardrail_flag",
    "guardrail",
    "gate_reason",
    "fillers_removed",
    "format_commands_fired",
    "replacements_fired",
    "thai_format_fired",
    "t_cleanup",
    "cleanup_error",
    "exact",
    "wer",
    "cer",
    "kw_recall",
];

/// Replays a clip whose cleanup failed through cleanup alone (`stt_text`),
/// up to `CLEANUP_ATTEMPTS` in all. Returns the attempts used.
fn retry_cleanup(
    pipeline: &Pipeline,
    runtime: &mut Worker,
    row: &Value,
    audio: &Path,
    clip: &mut Value,
) -> u32 {
    let mut attempts = 1;
    while pipeline.cleanup
        && !clip["cleanup_error"].is_null()
        && clip["raw"].is_string()
        && attempts < CLEANUP_ATTEMPTS
    {
        attempts += 1;
        let raw = clip["raw"].clone();
        match pipeline.dictate(runtime, row, audio, Some(&raw)) {
            Ok(replay) => merge_cleanup(clip, &replay),
            Err(e) => println!("Cleanup replay failed: {e}"),
        }
    }
    attempts
}

pub(crate) fn merge_cleanup(clip: &mut Value, replay: &Value) {
    for key in CLEANUP_KEYS {
        clip[*key] = replay[*key].clone();
    }
}

fn score(args: ScoreArgs) -> Result<()> {
    let dir = benchmark_path(&args.speakers_dir);
    let kit = load_kit(&dir.join(KIT_FILE))?;
    let only: BTreeSet<String> = args
        .only
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    let (voices, notes) = discover(&dir, &kit, &only)?;
    for note in &notes {
        println!("{note}");
    }
    let mut voices: Vec<Voice> = voices
        .into_iter()
        .filter(|v| {
            let empty = v.clips.is_empty();
            if empty {
                println!(
                    "{}: no recordings yet",
                    v.info["name"].as_str().unwrap_or("")
                );
            }
            !empty
        })
        .collect();
    if voices.is_empty() {
        return Err(format!(
            "No consented speaker has recordings under {}; see benchmark/speakers.md",
            dir.display()
        )
        .into());
    }
    let audio_root = benchmark_path(&args.audio_root);
    let baseline: BTreeMap<String, PathBuf> = kit
        .iter()
        .filter_map(|r| {
            let path = audio_root.join(r["path"].as_str()?);
            path.is_file()
                .then(|| (r["id"].as_str().unwrap_or("").to_owned(), path))
        })
        .collect();
    if baseline.is_empty() {
        println!(
            "No developer recordings under {}; reporting speakers without a baseline",
            audio_root.display()
        );
    } else {
        voices.insert(
            0,
            Voice {
                info: json!({"name":BASELINE,"baseline":true,"synthetic":false,"mic":"","room":"",
                    "missing":kit.len()-baseline.len()}),
                clips: baseline,
            },
        );
    }
    ensure_private(&args.out, &["results.json".to_owned()])?;
    let rows: Vec<Value> = kit
        .iter()
        .map(|r| {
            let mut row = r.clone();
            row["sentence"] = r["id"].clone();
            row
        })
        .collect();
    // Interleaved by sentence so drift on a shared machine hits every voice alike.
    let mut jobs = Vec::new();
    for row in &rows {
        let id = row["id"].as_str().unwrap_or("");
        for voice in &voices {
            if let Some(path) = voice.clips.get(id) {
                let name = voice.info["name"].as_str().unwrap_or("").to_owned();
                jobs.push((name, row, path.clone()));
            }
        }
    }
    let pipeline = Pipeline {
        engine: args.engine.clone(),
        cleanup: true,
        no_vocab: false,
        no_llm: false,
        screen: Vec::new(),
        screen_keywords: false,
    };
    let clips = run_clips(
        &pipeline,
        &args.runtime_dir,
        &args.tools_dir,
        &args.model_dir,
        &jobs,
    )?;
    let kit_text = std::fs::read(dir.join(KIT_FILE))?;
    let mut meta = environment(&args.engine, &args.runtime_dir);
    meta["kit_sha256"] = sha256_hex(&kit_text).into();
    meta["kit_sentences"] = kit.len().into();
    let results = json!({"kind":"speakers","meta":meta,"groups":groups_json(),
        "speakers":voices.iter().map(|v| v.info.clone()).collect::<Vec<_>>(),"clips":clips});
    write_json(&args.out.join("results.json"), &results)?;
    render(&results, &args.out)
}

/// Writes summary.json and report.md (aggregates only) next to results.json.
pub(crate) fn render(results: &Value, out: &Path) -> Result<()> {
    let clips: Vec<Clip> = results["clips"]
        .as_array()
        .ok_or("Results have no clips")?
        .iter()
        .map(Clip::from_json)
        .collect::<std::result::Result<_, _>>()?;
    let meta = &results["meta"];
    let (summary, md) = match results["kind"].as_str() {
        Some("speakers") => {
            let speakers: Vec<Speaker> = results["speakers"]
                .as_array()
                .ok_or("Results have no speakers")?
                .iter()
                .map(Speaker::from_json)
                .collect::<std::result::Result<_, _>>()?;
            let groups_value = results["groups"].as_array().cloned().unwrap_or_default();
            let groups: Vec<Group> = groups_value
                .iter()
                .map(|g| Group {
                    key: g["key"].as_str().unwrap_or(""),
                    label: g["label"].as_str().unwrap_or(""),
                    buckets: g["buckets"]
                        .as_array()
                        .map(|a| a.iter().filter_map(Value::as_str).collect())
                        .unwrap_or_default(),
                })
                .collect();
            let (summary, md) = stats::speakers_report(meta, &speakers, &clips, &groups);
            for (name, s) in summary["speakers"].as_object().into_iter().flatten() {
                println!(
                    "{name}: {} clips, meaning match {:.1}%, CER {:.3}",
                    s["n"],
                    s["meaning_match_pct"].as_f64().unwrap_or(0.0),
                    s["mean_cer"].as_f64().unwrap_or(0.0)
                );
            }
            (summary, md)
        }
        Some("fleurs") => {
            let (summary, md) = stats::fleurs_report(meta, &clips);
            println!(
                "{} recordings, meaning match {:.1}%, CER {:.3}",
                summary["overall"]["n"],
                summary["overall"]["meaning_match_pct"]
                    .as_f64()
                    .unwrap_or(0.0),
                summary["overall"]["mean_cer"].as_f64().unwrap_or(0.0)
            );
            (summary, md)
        }
        _ => return Err("Unknown results kind (expected speakers or fleurs)".into()),
    };
    let failed = clips.iter().filter(|c| c.cleanup_failed).count();
    if failed > 0 {
        println!(
            "Warning: cleanup failed on {failed} of {} clips, which lowers meaning match; \
a busy machine is the usual cause. Rerun before publishing.",
            clips.len()
        );
    }
    write_json(&out.join("summary.json"), &summary)?;
    std::fs::write(out.join("report.md"), md)?;
    println!("Wrote {}", out.join("report.md").display());
    Ok(())
}

fn synth(args: SynthArgs) -> Result<()> {
    if args.voice.is_empty()
        || !args
            .voice
            .chars()
            .all(|c| c.is_alphanumeric() || " ()-_.".contains(c))
    {
        return Err("Unexpected voice name".into());
    }
    let dir = benchmark_path(&args.speakers_dir);
    let kit = load_kit(&dir.join(KIT_FILE))?;
    let name = args.name.unwrap_or_else(|| {
        format!(
            "tts-{}",
            args.voice
                .to_lowercase()
                .chars()
                .filter(char::is_ascii_alphanumeric)
                .collect::<String>()
        )
    });
    if !valid_name(&name) || name == BASELINE {
        return Err(format!("Invalid speaker name {name:?}").into());
    }
    let out = dir.join(&name);
    check_synth_target(&out, &args.voice)?;
    let mut written = vec!["consent.json".to_owned()];
    for row in &kit {
        let id = row["id"].as_str().ok_or("Kit row has no id")?;
        written.push(format!("{id}.aiff"));
        written.push(format!("{id}.part.aiff"));
    }
    ensure_private(&out, &written)?;
    std::fs::create_dir_all(&out)?;
    // The label first: an interrupted run leaves a directory that says which
    // voice it holds, so the next run resumes it instead of refusing it.
    write_json(
        &out.join("consent.json"),
        &json!({"synthetic": true, "voice": args.voice, "date": command_line("date", &["+%F"]),
            "mic": "none (macOS text-to-speech)", "room": "none"}),
    )?;
    let mut made = 0;
    for row in &kit {
        let id = row["id"].as_str().ok_or("Kit row has no id")?;
        let path = out.join(format!("{id}.aiff"));
        if path.is_file() {
            continue;
        }
        // Into a side file, renamed when `say` finishes: a run cut off mid-clip
        // leaves no truncated recording that a resumed run would skip.
        let partial = out.join(format!("{id}.part.aiff"));
        let mut child = Command::new("say")
            .args(["-v", &args.voice, "-f", "-", "-o"])
            .arg(&partial)
            .stdin(Stdio::piped())
            .spawn()?;
        child
            .stdin
            .take()
            .ok_or("say has no stdin")?
            .write_all(row["say"].as_str().unwrap_or("").as_bytes())?;
        if !child.wait()?.success() || !partial.is_file() {
            return Err(format!("say could not synthesize {id} with voice {}", args.voice).into());
        }
        std::fs::rename(&partial, &path)?;
        made += 1;
    }
    println!(
        "Synthesized {made} clips with {} into {}",
        args.voice,
        out.display()
    );
    Ok(())
}

pub(crate) struct Recording {
    pub sentence: String,
    pub file: String,
    pub reference: String,
    pub gender: String,
}

/// FLEURS spells sara am as nikhahit + sara aa and sara ae as two sara e; OLIV
/// (and every Thai keyboard) writes the composed letters.
pub(crate) fn fleurs_reference(text: &str) -> String {
    text.replace("\u{0E4D}\u{0E32}", "\u{0E33}")
        .replace("\u{0E40}\u{0E40}", "\u{0E41}")
        .trim()
        .to_owned()
}

pub(crate) fn parse_fleurs(tsv: &str) -> Result<Vec<Recording>> {
    tsv.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|line| {
            let cols: Vec<&str> = line.split('\t').collect();
            if cols.len() < 7 || cols[1].contains('/') || !cols[1].ends_with(".wav") {
                return Err("Unexpected FLEURS test.tsv row".into());
            }
            Ok(Recording {
                sentence: cols[0].to_owned(),
                file: cols[1].to_owned(),
                reference: fleurs_reference(cols[2]),
                gender: cols[6].trim().to_owned(),
            })
        })
        .collect()
}

/// Sentences with two or more readers, first `n` in sha256(seed:sentence)
/// order (0 = all); returns them with every recording, and the pool size.
pub(crate) fn sample_fleurs<'a>(
    recordings: &'a [Recording],
    n: usize,
    seed: &str,
) -> (Vec<&'a Recording>, usize) {
    let mut by_sentence: BTreeMap<&str, Vec<&Recording>> = BTreeMap::new();
    for r in recordings {
        by_sentence.entry(r.sentence.as_str()).or_default().push(r);
    }
    let mut pool: Vec<(String, &str)> = by_sentence
        .iter()
        .filter(|(_, v)| v.len() >= 2)
        .map(|(s, _)| (sha256_hex(format!("{seed}:{s}").as_bytes()), *s))
        .collect();
    pool.sort();
    let total = pool.len();
    let take = if n == 0 { total } else { n.min(total) };
    let chosen = pool[..take]
        .iter()
        .flat_map(|(_, s)| by_sentence[s].iter().copied())
        .collect();
    (chosen, total)
}

fn fleurs(args: FleursArgs) -> Result<()> {
    let data = match args
        .data_dir
        .clone()
        .or_else(|| std::env::var_os("OLIV_FLEURS_DIR").map(PathBuf::from))
    {
        Some(d) => d,
        None => Path::new(&std::env::var_os("HOME").ok_or("HOME is not set")?)
            .join(".cache/oliv-bench/fleurs-th"),
    };
    let tsv_path = data.join("test.tsv");
    let bytes = std::fs::read(&tsv_path).map_err(|_| {
        format!(
            "FLEURS Thai not found at {}; run scripts/fetch_fleurs_th.sh",
            tsv_path.display()
        )
    })?;
    let tsv_sha256 = sha256_hex(&bytes);
    if !args.allow_unpinned && tsv_sha256 != FLEURS_TSV_SHA256 {
        return Err("test.tsv does not match the pinned FLEURS revision".into());
    }
    let recordings = parse_fleurs(std::str::from_utf8(&bytes)?)?;
    let (chosen, with_readers) = sample_fleurs(&recordings, args.sentences, &args.seed);
    if chosen.is_empty() {
        return Err("No FLEURS sentence has two or more readers".into());
    }
    let rows: Vec<(Value, PathBuf)> = chosen
        .iter()
        .map(|r| {
            let stem = r.file.trim_end_matches(".wav");
            let audio = data.join("test").join(&r.file);
            (
                json!({"id":format!("fleurs-{stem}"),"bucket":"fleurs","group":"fleurs",
                    "sentence":r.sentence,"reference":r.reference}),
                audio,
            )
        })
        .collect();
    if let Some((_, audio)) = rows.iter().find(|(_, a)| !a.is_file()) {
        return Err(format!("Missing FLEURS audio {}", audio.display()).into());
    }
    if let Some(path) = &args.manifest_out {
        return write_manifest(path, &rows);
    }
    let model_dir = args.model_dir.as_ref().ok_or("--model-dir is required")?;
    ensure_private(&args.out, &["results.json".to_owned()])?;
    let jobs: Vec<(String, &Value, PathBuf)> = rows
        .iter()
        .map(|(row, audio)| {
            (
                row["id"].as_str().unwrap_or("").to_owned(),
                row,
                audio.clone(),
            )
        })
        .collect();
    let sentences = chosen
        .iter()
        .map(|r| r.sentence.as_str())
        .collect::<BTreeSet<_>>()
        .len();
    println!(
        "FLEURS Thai: {sentences} sentences, {} recordings",
        jobs.len()
    );
    let pipeline = Pipeline {
        engine: args.engine.clone(),
        cleanup: true,
        no_vocab: false,
        no_llm: false,
        screen: Vec::new(),
        screen_keywords: false,
    };
    let clips = run_clips(
        &pipeline,
        &args.runtime_dir,
        &args.tools_dir,
        model_dir,
        &jobs,
    )?;
    let mut genders: BTreeMap<&str, usize> = BTreeMap::new();
    for r in &chosen {
        *genders.entry(r.gender.as_str()).or_default() += 1;
    }
    let mut meta = environment(&args.engine, &args.runtime_dir);
    meta["dataset"] = "google/fleurs th_th test (CC-BY-4.0)".into();
    meta["revision"] = FLEURS_REVISION.into();
    meta["tsv_sha256"] = tsv_sha256.into();
    meta["seed"] = args.seed.clone().into();
    meta["sentences_sampled"] = sentences.into();
    meta["sentences_with_readers"] = with_readers.into();
    meta["recordings"] = jobs.len().into();
    meta["gender_labels"] = json!(genders);
    let results = json!({"kind":"fleurs","meta":meta,"clips":clips});
    write_json(&args.out.join("results.json"), &results)?;
    render(&results, &args.out)
}

/// Manifest rows (`id`, absolute `path`, `reference`, ...) in an ignored file.
pub(crate) fn write_manifest(path: &Path, rows: &[(Value, PathBuf)]) -> Result<()> {
    let dir = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    };
    let name = path
        .file_name()
        .ok_or("--manifest-out needs a file name")?
        .to_string_lossy()
        .into_owned();
    ensure_private(dir, &[name])?;
    std::fs::create_dir_all(dir)?;
    let mut text = String::new();
    for (row, audio) in rows {
        let mut row = row.clone();
        row["path"] = audio.to_string_lossy().as_ref().into();
        text.push_str(&serde_json::to_string(&row)?);
        text.push('\n');
    }
    std::fs::write(path, text)?;
    println!("Wrote {} manifest rows to {}", rows.len(), path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, reference: &str, audio: bool) -> Value {
        json!({"id":id,"path":format!("clips/{id}.wav"),"reference":reference,"_audio":audio,"_source":"m.jsonl"})
    }
    fn corpus() -> Vec<Value> {
        let mut rows = Vec::new();
        for (_, _, plan) in KIT_PLAN {
            for (bucket, count) in *plan {
                for i in 0..count + 2 {
                    rows.push(row(
                        &format!("{bucket}{i:02}"),
                        &format!("{bucket} sentence {i}"),
                        true,
                    ));
                }
            }
        }
        rows
    }

    #[test]
    fn kit_follows_the_plan_and_is_deterministic() {
        let rows = corpus();
        let kit = select_kit(&rows, "2026").unwrap();
        let planned: usize = KIT_PLAN
            .iter()
            .flat_map(|(_, _, p)| p.iter().map(|(_, n)| n))
            .sum();
        assert_eq!(kit.len(), planned);
        assert_eq!(planned, 30);
        assert_eq!(kit, select_kit(&rows, "2026").unwrap());
        assert_ne!(
            kit,
            select_kit(&rows, "other").unwrap(),
            "the seed picks sentences"
        );
        assert_eq!(kit[0]["n"], 1);
        assert_eq!(kit[29]["n"], 30);
        let nm: Vec<_> = kit.iter().filter(|r| r["bucket"] == "nm").collect();
        assert_eq!(nm.len(), 3);
        assert!(nm.iter().all(|r| r["group"] == "numbers"));
    }

    #[test]
    fn kit_skips_unrecorded_and_unspeakable_rows_and_reports_shortfalls() {
        let mut rows = corpus();
        // fm: two rows lose their audio, one has a multi-line reference without `say`.
        for r in rows
            .iter_mut()
            .filter(|r| r["id"].as_str().unwrap().starts_with("fm"))
            .take(2)
        {
            r["_audio"] = false.into();
        }
        rows.iter_mut().find(|r| r["id"] == "fm02").unwrap()["reference"] = "a\nb".into();
        let err = select_kit(&rows, "2026").unwrap_err().to_string();
        assert!(err.contains("Bucket fm has 1 usable"), "{err}");
        rows.iter_mut().find(|r| r["id"] == "fm02").unwrap()["say"] = "a new line b".into();
        let kit = select_kit(&rows, "2026").unwrap();
        let fm: Vec<_> = kit.iter().filter(|r| r["bucket"] == "fm").collect();
        assert!(
            fm.iter()
                .any(|r| r["id"] == "fm02" && r["say"] == "a new line b")
        );
        assert!(fm.iter().all(|r| r["id"] != "fm00" && r["id"] != "fm01"));
        rows.push(row("th00", "dup", true));
        assert!(
            select_kit(&rows, "2026")
                .unwrap_err()
                .to_string()
                .contains("Duplicate")
        );
    }

    #[test]
    fn speakable_text_prefers_say() {
        assert_eq!(
            speakable(&json!({"reference":"x\ny","say":"x new line y"})).as_deref(),
            Some("x new line y")
        );
        assert_eq!(speakable(&json!({"reference":"x\ny"})), None);
        assert_eq!(speakable(&json!({"reference":"  "})), None);
        assert_eq!(
            speakable(&json!({"reference":" hello "})).as_deref(),
            Some("hello")
        );
    }

    #[test]
    fn fleurs_rows_parse_compose_thai_and_sample_multi_reader_sentences() {
        let tsv = "1\ta.wav\tน้ํา เเข็ง\tx\tc\t1\tFEMALE\n1\tb.wav\tน้ํา เเข็ง\tx\tc\t1\tFEMALE\n2\tc.wav\tกา\tx\tc\t1\tMALE\n3\td.wav\tขา\tx\tc\t1\tFEMALE\n3\te.wav\tขา\tx\tc\t1\tFEMALE\n3\tf.wav\tขา\tx\tc\t1\tFEMALE\n";
        let recs = parse_fleurs(tsv).unwrap();
        assert_eq!(recs[0].reference, "น้ำ แข็ง");
        let (all, pool) = sample_fleurs(&recs, 0, "2026");
        assert_eq!(pool, 2, "sentence 2 has one reader");
        assert_eq!(all.len(), 5);
        let (one, _) = sample_fleurs(&recs, 1, "2026");
        assert!(one.len() == 2 || one.len() == 3);
        assert!(one.iter().all(|r| r.sentence == one[0].sentence));
        assert!(parse_fleurs("1\t../x.wav\tก\tx\tc\t1\tF\n").is_err());
    }

    #[test]
    fn a_cleanup_replay_keeps_the_first_transcript_and_timings() {
        let mut clip = json!({"raw":"r1","final":"r1","t_stt":4.0,"latency_s":9.0,
            "cleanup_error":"Inference request timed out","cer":0.4,"wer":0.5});
        let replay = json!({"raw":"r1","final":"clean","t_stt":0.0,"latency_s":1.0,
            "cleanup_error":null,"cer":0.1,"wer":0.2,"llm_ran":true});
        merge_cleanup(&mut clip, &replay);
        assert_eq!(clip["final"], "clean");
        assert!(clip["cleanup_error"].is_null());
        assert_eq!(
            (clip["cer"].as_f64(), clip["llm_ran"].as_bool()),
            (Some(0.1), Some(true))
        );
        assert_eq!(
            (clip["t_stt"].as_f64(), clip["latency_s"].as_f64()),
            (Some(4.0), Some(9.0))
        );
    }

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("oliv-speakers-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn every_private_file_must_be_ignored() {
        let repo = scratch("ignore");
        let ok = Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(["init", "-q"])
            .status()
            .unwrap();
        assert!(ok.success());
        // A checkout that ignores *.json but not the kit's other files.
        std::fs::write(repo.join(".gitignore"), "*.json\n").unwrap();
        let out = repo.join("kit");
        assert!(ensure_private(&out, &["results.json".to_owned()]).is_ok());
        let kit = [KIT_FILE, "script.md", "consent.example.json"].map(String::from);
        assert!(
            ensure_private(&out, &kit).is_err(),
            "script.md would be committed"
        );
        std::fs::write(repo.join(".gitignore"), "kit/\n").unwrap();
        assert!(ensure_private(&out, &kit).is_ok());
        // Outside any checkout there is nothing to protect.
        let loose = scratch("loose");
        assert!(ensure_private(&loose.join("out"), &kit).is_ok());
        let _ = std::fs::remove_dir_all(repo);
        let _ = std::fs::remove_dir_all(loose);
    }

    #[test]
    fn synth_never_writes_over_a_person_or_another_voice() {
        let dir = scratch("synth");
        let out = dir.join("s1");
        assert!(check_synth_target(&out, "Kanya").is_ok(), "a new directory");
        std::fs::create_dir_all(&out).unwrap();
        assert!(
            check_synth_target(&out, "Kanya").is_ok(),
            "an empty directory"
        );
        std::fs::write(out.join("a01.m4a"), b"x").unwrap();
        assert!(
            check_synth_target(&out, "Kanya").is_err(),
            "recordings without metadata"
        );
        std::fs::write(
            out.join("consent.json"),
            br#"{"consent":true,"mic":"MacBook"}"#,
        )
        .unwrap();
        assert!(
            check_synth_target(&out, "Kanya").is_err(),
            "a person's recordings"
        );
        std::fs::write(
            out.join("consent.json"),
            br#"{"synthetic":true,"voice":"Kanya"}"#,
        )
        .unwrap();
        assert!(
            check_synth_target(&out, "Kanya").is_ok(),
            "the same synthetic voice"
        );
        assert!(
            check_synth_target(&out, "Narisa").is_err(),
            "a different synthetic voice"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn speaker_names_are_short_pseudonyms() {
        assert!(valid_name("s1"));
        assert!(valid_name("tts-kanya"));
        assert!(!valid_name("Somchai"));
        assert!(!valid_name("-x"));
        assert!(!valid_name(&"a".repeat(33)));
    }
}
