//! Golden-fixture harness: each line is `{"args", "kwargs", "out" | "raises", ...}`.
#![allow(dead_code)]

use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;

use serde_json::Value;

/// `OLIV_GOLDEN_DIR` points the suite at another fixture directory (e.g. a
/// differential fuzz run against the Python reference); missing fixtures fail the suite.
fn golden_dir() -> Option<PathBuf> {
    std::env::var_os("OLIV_GOLDEN_DIR").map(PathBuf::from)
}

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

pub fn load(name: &str) -> Vec<Value> {
    let path = golden_path(name);
    let f = std::fs::File::open(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
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

/// Run `f` on every case; `Err(name)` stands for a raised exception.
/// Panics with the first few mismatches unless every case matches.
pub fn check(name: &str, f: impl Fn(&Value) -> Result<Value, String>) {
    let cases = load(name);
    let mut bad = Vec::new();
    for c in &cases {
        let got = f(c);
        let ok = match (&got, c.get("raises")) {
            (Err(e), Some(r)) => r.as_str() == Some(e.as_str()),
            (Ok(v), None) => Some(v) == c.get("out"),
            _ => false,
        };
        if !ok {
            bad.push((c, got));
        }
    }
    if !bad.is_empty() {
        let mut msg = format!("{name}: {} of {} cases differ\n", bad.len(), cases.len());
        for (c, got) in bad.iter().take(8) {
            msg += &format!(
                "  args={} kwargs={}\n    want={}\n    got ={:?}\n",
                c["args"],
                c["kwargs"],
                c.get("out").or(c.get("raises")).unwrap(),
                got
            );
        }
        panic!("{msg}");
    }
    eprintln!("{name}: {} cases ok", cases.len());
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
