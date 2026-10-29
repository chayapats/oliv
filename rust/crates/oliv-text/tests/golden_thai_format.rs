//! Goldens for thai_format (M3.7) and pythainlp `words_to_num`.
mod common;

use common::{check, s};
use oliv_pipeline::thai_format::apply_thai_format;
use oliv_pipeline::wordtonum::words_to_num;
use serde_json::json;

#[test]
fn words_to_num_golden() {
    check("words_to_num.jsonl", |c| {
        match words_to_num(s(&c["args"][0])) {
            // via the JSON parser, so huge values round like the fixture's do
            Ok(i) => Ok(serde_json::from_str(&i.to_string()).unwrap()),
            Err(_) => Err("ValueError".into()),
        }
    });
}

#[test]
fn thai_format() {
    check("thai_format.jsonl", |c| {
        Ok(json!(apply_thai_format(s(&c["args"][0]))))
    });
}
