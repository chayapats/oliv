//! Goldens for prompts/LLM (M3.9), clean_ex (M3.10) and the /v1/clean path with
//! the sidecar hallucination gates (M3.11). The LLM is mocked by replaying the
//! Synthetic LLM replies in `tests/reference/gens.jsonl`; no network.
mod common;

use std::collections::HashMap;
use std::path::PathBuf;

use common::{check, s, strs};
use oliv_pipeline::dictate::{Options, clean_text};
use oliv_pipeline::hallucination;
use oliv_pipeline::llm::{Llm, LlmError, Prompt, Request, hint_line};
use oliv_pipeline::pipeline::clean_ex;
use serde_json::{Value, json};

/// Replays recorded generations keyed by (prompt, text, hints); fails loudly on a miss.
/// A `gens.jsonl` inside `OLIV_GOLDEN_DIR` (eval/port_check.py) is loaded on top.
struct Replay(HashMap<(String, String, Vec<String>), String>);

impl Replay {
    fn load() -> Self {
        let mut text = std::fs::read_to_string(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/reference/gens.jsonl"),
        )
        .unwrap();
        if let Some(dir) = std::env::var_os("OLIV_GOLDEN_DIR") {
            text +=
                &std::fs::read_to_string(PathBuf::from(dir).join("gens.jsonl")).unwrap_or_default();
        }
        let map = text
            .lines()
            .map(|l| {
                let v: Value = serde_json::from_str(l).unwrap();
                let key = (
                    s(&v["prompt"]).into(),
                    s(&v["text"]).into(),
                    strs(&v["hints"]),
                );
                (key, s(&v["gen"]).to_string())
            })
            .collect();
        Replay(map)
    }
}

impl Llm for Replay {
    fn generate(&self, req: &Request) -> Result<String, LlmError> {
        let key = (
            req.prompt.name().to_string(),
            req.text.to_string(),
            req.hints.to_vec(),
        );
        self.0
            .get(&key)
            .cloned()
            .ok_or_else(|| LlmError(format!("no recorded gen for {key:?}")))
    }
}

/// An LLM that must never be called.
struct NoLlm;

impl Llm for NoLlm {
    fn generate(&self, req: &Request) -> Result<String, LlmError> {
        panic!("unexpected LLM call for {:?}", req.text)
    }
}

fn prompt_of(v: &Value) -> Prompt {
    s(v).parse().unwrap()
}

#[test]
fn hint_line_golden() {
    check("hint_line.jsonl", |c| {
        let hints = if c["args"][0].is_null() {
            vec![]
        } else {
            strs(&c["args"][0])
        };
        Ok(json!(hint_line(&hints)))
    });
}

#[test]
fn prompt_body() {
    check("prompt.jsonl", |c| {
        let hints = strs(&c["args"][2]);
        let req = Request {
            prompt: prompt_of(&c["args"][0]),
            text: s(&c["args"][1]),
            hints: &hints,
        };
        Ok(req.body())
    });
}

#[test]
fn clean_ex_golden() {
    let llm = Replay::load();
    check("clean_ex.jsonl", |c| {
        let vocab = match &c["kwargs"]["vocab"] {
            Value::Null => vec![],
            v => strs(v),
        };
        let r = clean_ex(s(&c["args"][0]), &vocab, prompt_of(&c["prompt"]), &llm);
        assert!(r.llm_error.is_none(), "{:?}", r.llm_error);
        Ok(serde_json::to_value(&r).unwrap())
    });
}

#[test]
fn dictate_golden() {
    let llm = Replay::load();
    check("dictate.jsonl", |c| {
        let opts = Options::from_json(c["kwargs"].as_object().unwrap(), Prompt::V2).unwrap();
        let llm: &dyn Llm = if opts.cleanup { &llm } else { &NoLlm };
        Ok(serde_json::to_value(clean_text(s(&c["args"][0]), &opts, llm)).unwrap())
    });
}

#[test]
fn strip_cjk() {
    check("strip_cjk.jsonl", |c| {
        Ok(json!(hallucination::strip_cjk(s(&c["args"][0]))))
    });
}

#[test]
fn text_hallucination() {
    check("text_hallucination.jsonl", |c| {
        Ok(json!(hallucination::text_hallucination(s(&c["args"][0]))))
    });
}

#[test]
fn hallucination_phrase() {
    check("hallucination_phrase.jsonl", |c| {
        Ok(json!(hallucination::hallucination_phrase(s(&c["args"][0]))))
    });
}

#[test]
fn repetition_loop() {
    check("repetition_loop.jsonl", |c| {
        Ok(json!(hallucination::repetition_loop(s(&c["args"][0]))))
    });
}
