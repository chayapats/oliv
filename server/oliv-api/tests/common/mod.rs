//! Golden-fixture harness: each line is `{"args", "kwargs", "out" | "raises", ...}`.
#![allow(dead_code)]

use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};

use serde_json::Value;

/// `OLIV_GOLDEN_DIR` points the suite at another fixture directory (e.g. an
/// untracked private set); files missing there are skipped.
pub fn golden_dir() -> Option<PathBuf> {
    std::env::var_os("OLIV_GOLDEN_DIR").map(PathBuf::from)
}

/// `name` is the plain `.jsonl` name; a gzipped `<name>.gz` is used when the
/// plain file is absent (the tracked fixtures are all gzipped).
pub fn golden_path(name: &str) -> PathBuf {
    let path = golden_dir()
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden"))
        .join(name);
    if path.exists() {
        path
    } else {
        path.with_extension("jsonl.gz")
    }
}

fn read_jsonl(path: &Path) -> Vec<Value> {
    let f = std::fs::File::open(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let reader: Box<dyn Read> = if path.extension().is_some_and(|ext| ext == "gz") {
        Box::new(flate2::read::GzDecoder::new(f))
    } else {
        Box::new(f)
    };
    BufReader::new(reader)
        .lines()
        .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
        .collect()
}

pub fn load(name: &str) -> Vec<Value> {
    read_jsonl(&golden_path(name))
}

/// Cases where the server intentionally diverges from the reference output in
/// `tests/golden/<name>` (KNOWN_DIFFS.md), from `tests/known_diffs/<name>`:
/// `{"args", "kwargs", "oliv", "out", "why"}` with the fixture's expected
/// value (`oliv`) and the server's (`out`). Empty if the file is absent.
pub fn known_diffs(name: &str) -> Vec<Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/known_diffs")
        .join(name);
    if path.exists() {
        read_jsonl(&path)
    } else {
        vec![]
    }
}

fn kwargs(c: &Value) -> Value {
    match &c["kwargs"] {
        Value::Null => Value::Object(Default::default()),
        v => v.clone(),
    }
}

/// Run `f` on every case; `Err(name)` stands for a raised exception.
/// Expected values listed in `known_diffs(name)` are replaced by the server's
/// first; every listed diff must match exactly one case and still be stale
/// against the fixture (`oliv` == the fixture's `out`).
/// Panics with the first few mismatches unless every case matches.
pub fn check(name: &str, f: impl Fn(&Value) -> Result<Value, String>) {
    check_patched(name, |_, _| {}, f);
}

/// `check`, with `patch(case, out)` then rewriting each expected `out` where
/// the divergence follows from another fixture's known diff (KNOWN_DIFFS.md).
pub fn check_patched(
    name: &str,
    patch: impl Fn(&Value, &mut Value),
    f: impl Fn(&Value) -> Result<Value, String>,
) {
    if golden_dir().is_some() && !golden_path(name).exists() {
        eprintln!("{name}: not in OLIV_GOLDEN_DIR, skipped");
        return;
    }
    let diffs = known_diffs(name);
    let mut used = vec![0usize; diffs.len()];
    let cases = load(name);
    let mut bad = Vec::new();
    for c in &cases {
        let got = f(c);
        let mut want = c.get("out").cloned();
        let (args, kw) = (&c["args"], kwargs(c));
        if let Some(i) = diffs
            .iter()
            .position(|d| d["args"] == *args && kwargs(d) == kw)
        {
            assert_eq!(
                Some(&diffs[i]["oliv"]),
                want.as_ref(),
                "{name}: stale known diff {args} {kw}"
            );
            want = Some(diffs[i]["out"].clone());
            used[i] += 1;
        }
        if let Some(w) = want.as_mut() {
            patch(c, w);
        }
        let ok = match (&got, c.get("raises")) {
            (Err(e), Some(r)) => r.as_str() == Some(e.as_str()),
            (Ok(v), None) => Some(v) == want.as_ref(),
            _ => false,
        };
        if !ok {
            bad.push((c, want, got));
        }
    }
    if !bad.is_empty() {
        let mut msg = format!("{name}: {} of {} cases differ\n", bad.len(), cases.len());
        for (c, want, got) in bad.iter().take(8) {
            msg += &format!(
                "  args={} kwargs={}\n    want={}\n    got ={:?}\n",
                c["args"],
                c["kwargs"],
                want.as_ref().or(c.get("raises")).unwrap(),
                got
            );
        }
        panic!("{msg}");
    }
    if golden_dir().is_none() {
        for (d, n) in diffs.iter().zip(&used) {
            assert_eq!(*n, 1, "{name}: known diff {} matched {n} cases", d["args"]);
        }
    }
    eprintln!(
        "{name}: {} cases ok ({} known diffs)",
        cases.len(),
        used.iter().filter(|&&n| n > 0).count()
    );
}

/// The server's `remove_fillers` result for an input where it diverges from
/// Oliv (KNOWN_DIFFS.md §7), from `diffs = known_diffs("fillers.jsonl")`.
pub fn fillers_diff(diffs: &[Value], input: &str) -> Option<(String, usize)> {
    diffs.iter().find(|d| d["args"][0] == input).map(|d| {
        (
            s(&d["out"][0]).to_string(),
            d["out"][1].as_u64().unwrap() as usize,
        )
    })
}

pub fn s(v: &Value) -> &str {
    v.as_str().expect("string arg")
}

pub fn strs(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| s(x).to_string())
        .collect()
}
