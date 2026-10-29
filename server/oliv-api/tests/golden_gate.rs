//! Goldens for the gate and guardrail passes.
mod common;

use common::{check, s};
use oliv_pipeline::{gate, guardrail, metrics};
use serde_json::json;

#[test]
fn suspicious_tokens() {
    check("suspicious_tokens.jsonl", |c| {
        Ok(json!(gate::suspicious_tokens(s(&c["args"][0]))))
    });
}

#[test]
fn loan_compound_runs() {
    check("loan_compound_runs.jsonl", |c| {
        Ok(json!(gate::loan_compound_runs(s(&c["args"][0]))))
    });
}

#[test]
fn latin_crumbs() {
    check("latin_crumbs.jsonl", |c| {
        Ok(json!(gate::latin_crumbs(s(&c["args"][0]))))
    });
}

#[test]
fn gate() {
    check("gate.jsonl", |c| {
        let hits = c["args"][1].as_u64().unwrap() as usize;
        Ok(json!(gate::gate(s(&c["args"][0]), hits)))
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

#[test]
fn strip_out() {
    check("strip_out.jsonl", |c| {
        Ok(json!(guardrail::strip_out(s(&c["args"][0]))))
    });
}

/// KNOWN_DIFFS.md §11 cases are in `tests/known_diffs/lost_spans.jsonl`.
#[test]
fn lost_spans() {
    check("lost_spans.jsonl", |c| {
        let allow = c["kwargs"]["allow_asr_repair"].as_bool().unwrap_or(false);
        Ok(json!(guardrail::lost_spans(
            s(&c["args"][0]),
            s(&c["args"][1]),
            allow
        )))
    });
}

/// KNOWN_DIFFS.md §12 cases are in `tests/known_diffs/thai_divergence.jsonl`.
#[test]
fn thai_divergence() {
    check("thai_divergence.jsonl", |c| {
        Ok(json!(guardrail::thai_divergence(
            s(&c["args"][0]),
            s(&c["args"][1])
        )))
    });
}

#[test]
fn latin_gain() {
    check("latin_gain.jsonl", |c| {
        Ok(json!(guardrail::latin_gain(
            s(&c["args"][0]),
            s(&c["args"][1])
        )))
    });
}

#[test]
fn translation_gloss() {
    check("translation_gloss.jsonl", |c| {
        Ok(json!(guardrail::invented_translation_gloss(
            s(&c["args"][0]),
            s(&c["args"][1])
        )))
    });
}

/// KNOWN_DIFFS.md §13 (`ok+script`) cases are in `tests/known_diffs/guardrail.jsonl`.
#[test]
fn guardrail() {
    check("guardrail.jsonl", |c| {
        Ok(json!(guardrail::guardrail(
            s(&c["args"][0]),
            s(&c["args"][1])
        )))
    });
}
