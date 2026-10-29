mod common;

use common::{check, s};
use oliv_pipeline::tokenize::word_tokenize;
use serde_json::{Value, json};

fn run(c: &Value) -> Result<Value, String> {
    assert_eq!(c["kwargs"]["engine"], "newmm");
    let kw = c["kwargs"]["keep_whitespace"].as_bool().unwrap();
    Ok(json!(word_tokenize(s(&c["args"][0]), kw)))
}

#[test]
fn tokenize() {
    check("tokenize.jsonl", run);
}

#[test]
fn tokenize_fuzz() {
    check("tokenize_fuzz.jsonl.gz", run);
}
