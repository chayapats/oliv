//! Goldens for phonetic: fold, royin, thai_fold, vocab_correct, vocab_hint.
mod common;

use common::{check, s, strs};
use oliv_pipeline::{phonetic, royin};
use serde_json::json;

#[test]
fn fold() {
    check("fold.jsonl", |c| {
        Ok(json!(phonetic::fold(s(&c["args"][0]))))
    });
}

#[test]
fn royin() {
    check("royin.jsonl", |c| {
        assert_eq!(c["kwargs"]["engine"], "royin");
        royin::romanize(s(&c["args"][0]))
            .map(|r| json!(r))
            .map_err(str::to_string)
    });
}

#[test]
fn thai_fold() {
    check("thai_fold.jsonl", |c| {
        Ok(json!(phonetic::thai_fold(s(&c["args"][0]))))
    });
}

#[test]
fn vocab_correct() {
    check("vocab_correct.jsonl", |c| {
        Ok(json!(phonetic::correct_with_vocab(
            s(&c["args"][0]),
            &strs(&c["args"][1])
        )))
    });
}

#[test]
fn vocab_hint() {
    check("vocab_hint.jsonl", |c| {
        Ok(json!(phonetic::vocab_hint(
            s(&c["args"][0]),
            &strs(&c["args"][1])
        )))
    });
}
