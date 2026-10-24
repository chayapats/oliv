//! Goldens for the simple text passes: fillers and spacing (casing and the
//! dictionary live in oliv-text-core).
mod common;

use common::{check, s};
use oliv_pipeline::{fillers, spacing};
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
