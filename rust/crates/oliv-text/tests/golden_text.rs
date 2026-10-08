//! Goldens for the simple text passes: fillers, spacing, casing, dictionary.
mod common;

use common::{check, s};
use oliv_pipeline::{dictionary, fillers, spacing};
use serde_json::json;

#[test]
fn fillers() {
    check("fillers.jsonl", |c| {
        Ok(json!(fillers::remove_fillers(s(&c["args"][0]))))
    });
}

#[test]
fn spacing() {
    check("spacing.jsonl", |c| {
        Ok(json!(spacing::normalize_thai_spacing(s(&c["args"][0]))))
    });
}

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
