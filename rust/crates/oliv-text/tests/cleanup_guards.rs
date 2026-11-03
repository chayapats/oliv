//! The cleanup guards end to end (`dictate::clean_text`, the `/v1/clean` path):
//! other scripts stripped from transcripts and rejected in cleanup output, and
//! Thai speech the cleanup model rewrote put back. The vectors in
//! `oliv-text-core/tests/vectors/cleanup_guards.jsonl` are shared with the
//! OLIV server (`server/oliv-api/tests/cleanup_guards.rs`), which must give
//! the same results.

use std::path::PathBuf;

use oliv_pipeline::dictate::{Options, clean_text};
use oliv_pipeline::llm::{Llm, LlmError, Prompt, Request};
use serde_json::Value;

/// The generation a vector gives, or a test failure if it gives none.
struct Fixed(Option<String>);

impl Llm for Fixed {
    fn generate(&self, _: &Request) -> Result<String, LlmError> {
        Ok(self
            .0
            .clone()
            .expect("the LLM ran on a vector without a generation"))
    }
}

#[test]
fn cleanup_guard_vectors() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../oliv-text-core/tests/vectors/cleanup_guards.jsonl");
    let text = std::fs::read_to_string(&path).unwrap();
    let mut n = 0;
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let v: Value = serde_json::from_str(line).unwrap();
        let case = v["case"].as_str().unwrap();
        let opts =
            Options::from_json(v["options"].as_object().unwrap(), Prompt::default()).unwrap();
        let llm = Fixed(v["gen"].as_str().map(str::to_string));
        let out = clean_text(v["text"].as_str().unwrap(), &opts, &llm);
        assert_eq!(out.final_text, v["final"].as_str().unwrap(), "{case}");
        assert_eq!(out.guardrail_flag, v["flag"].as_str().unwrap(), "{case}");
        assert_eq!(out.no_speech, v["no_speech"].as_bool().unwrap(), "{case}");
        assert_eq!(out.llm_ran, !v["gen"].is_null(), "{case}");
        n += 1;
    }
    assert_eq!(n, 8);
}
