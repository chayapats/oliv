//! Goldens for the core text passes: canonical casing, the built-in
//! dictionary and user tables, and the evaluation metrics.
mod common;

use common::{check, s};
use oliv_text_core::{dictionary, metrics};
use serde_json::json;

#[test]
fn casing() {
    check("casing.jsonl", |c| {
        Ok(json!(dictionary::apply_canonical_casing(s(&c["args"][0]))))
    });
}

#[test]
fn dictionary() {
    check("dictionary.jsonl", |c| {
        let text = s(&c["args"][0]);
        let table = c["args"].get(1).or(c["kwargs"].get("table"));
        Ok(match table {
            None | Some(serde_json::Value::Null) => json!(dictionary::apply_dictionary(text)),
            Some(t) => {
                let pairs: Vec<(&str, &str)> = t
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(k, v)| (k.as_str(), s(v)))
                    .collect();
                json!(dictionary::apply_table(text, &pairs))
            }
        })
    });
}

#[test]
fn normalize() {
    check("normalize.jsonl", |c| {
        Ok(json!(metrics::normalize(s(&c["args"][0]))))
    });
}

#[test]
fn metrics_tokenize() {
    check("metrics_tokenize.jsonl", |c| {
        assert_eq!(c["args"][1], "newmm");
        Ok(json!(metrics::tokenize(s(&c["args"][0]))))
    });
}
