//! Goldens for prompts/LLM, clean_ex and the /v1/clean path with the sidecar
//! hallucination gates. The LLM is mocked by replaying the synthetic LLM
//! replies in `tests/reference/gens.jsonl`; no network.
mod common;

use std::cell::Cell;
use std::collections::HashMap;
use std::path::PathBuf;

use common::{check, check_patched, fillers_diff, golden_dir, known_diffs, load, s, strs};
use oliv_pipeline::dictate::{AsrProfile, Options, clean_text};
use oliv_pipeline::hallucination;
use oliv_pipeline::llm::{Llm, LlmError, Prompt, Request, hint_line};
use oliv_pipeline::pipeline::clean_ex;
use serde_json::{Value, json};

/// Replays recorded generations keyed by (prompt, text, hints); fails loudly on a miss.
/// A `gens.jsonl` inside `OLIV_GOLDEN_DIR` (an optional extra fixture set outside git) is loaded on top.
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

/// Turbo, the default ASR profile, is the one the fixtures describe; the other
/// profiles' gate (KNOWN_DIFFS.md §14) is covered by unit tests.
#[test]
fn clean_ex_golden() {
    let llm = Replay::load();
    check("clean_ex.jsonl", |c| {
        let vocab = match &c["kwargs"]["vocab"] {
            Value::Null => vec![],
            v => strs(v),
        };
        let r = clean_ex(
            s(&c["args"][0]),
            &vocab,
            &Default::default(),
            prompt_of(&c["prompt"]),
            AsrProfile::Turbo,
            None,
            &llm,
        );
        assert!(r.llm_error.is_none(), "{:?}", r.llm_error);
        Ok(serde_json::to_value(&r).unwrap())
    });
}

#[test]
fn dictate_golden() {
    let llm = Replay::load();
    let options = |c: &Value| {
        Options::from_json(
            c["kwargs"].as_object().unwrap(),
            Prompt::V2,
            AsrProfile::Turbo,
        )
        .unwrap()
    };
    let run = |text: &str, opts: &Options| {
        let llm: &dyn Llm = if opts.cleanup { &llm } else { &NoLlm };
        clean_text(text, opts, llm)
    };
    let fillers = known_diffs("fillers.jsonl");
    let fillers_diverged = Cell::new(0);
    check_patched(
        "dictate.jsonl",
        |c, out| {
            let mut opts = options(c);
            if let Some((rs, n)) =
                fillers_diff(&fillers, s(&c["args"][0])).filter(|_| opts.remove_fillers)
            {
                // §7: the rest of the pipeline on the server's fillers output
                opts.remove_fillers = false;
                let mut want = run(&rs, &opts);
                assert!(want.cleanup_error.is_none(), "{:?}", want.cleanup_error);
                want.fillers_removed = n;
                *out = serde_json::to_value(want).unwrap();
                fillers_diverged.set(fillers_diverged.get() + 1);
            }
        },
        |c| Ok(serde_json::to_value(run(s(&c["args"][0]), &options(c))).unwrap()),
    );
    if golden_dir().is_none() {
        assert_eq!(fillers_diverged.get(), 30, "KNOWN_DIFFS.md §7 cases");
    }
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

/// Loop trimming (KNOWN_DIFFS.md §8) only touches text Oliv's gate drops.
#[test]
fn trim_repetition_loops_only_fires_on_loops() {
    let mut fired = 0;
    for c in load("repetition_loop.jsonl") {
        let text = s(&c["args"][0]);
        if hallucination::trim_repetition_loops(text).is_some() {
            assert_eq!(c["out"], json!(true), "{text}");
            fired += 1;
        }
    }
    assert!(fired > 0 || golden_dir().is_some());
}
