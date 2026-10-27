//! The personal dictionary wired through the local (sidecar) text path. The
//! matching rules themselves are tested in oliv-text-core.

use oliv_pipeline::commands::initial_prompt;
use oliv_pipeline::dictate::{Options, clean_text};
use oliv_pipeline::llm::{Llm, LlmError, Prompt, Request};
use oliv_pipeline::pipeline::DICTIONARY_FLAG;
use serde_json::{Value, json};

/// Replies with a fixed generation.
struct Fixed(&'static str);

impl Llm for Fixed {
    fn generate(&self, _: &Request) -> Result<String, LlmError> {
        Ok(self.0.to_string())
    }
}

/// Must never be called: the gate skips text without Thai.
struct NoLlm;

impl Llm for NoLlm {
    fn generate(&self, req: &Request) -> Result<String, LlmError> {
        panic!("unexpected LLM call for {:?}", req.text)
    }
}

fn opts(body: Value) -> Result<Options, String> {
    Options::from_json(body.as_object().unwrap(), Prompt::V2)
}

#[test]
fn request_dictionary_is_parsed_and_validated() {
    let o = opts(json!({
        "vocabulary": ["Legacy", "koolify"],
        "dictionary": [
            {"word": "Koolify", "correction": "koolify", "starred": true},
            {"word": "Legacy"},
            {"word": "Off", "enabled": false},
            {"word": "!!!"},
        ],
    }))
    .unwrap();
    assert_eq!(o.effective_vocabulary(), ["Koolify", "Legacy"]);

    for bad in [
        json!({"dictionary": "x"}),
        json!({"dictionary": [{"correction": "x"}]}),
        json!({"dictionary": [{"word": "x", "enabled": "yes"}]}),
        json!({"dictionary": [{"word": "x", "correction": 3}]}),
    ] {
        assert!(opts(bad.clone()).is_err(), "{bad}");
    }
    assert!(opts(json!({})).unwrap().dictionary.is_empty());
}

#[test]
fn clean_text_applies_corrections_numerals_and_legacy_replacements() {
    let o = opts(json!({
        "thai_format": false,
        "replacements": {"say": "Legacy"},
        "dictionary": [{"word": "Koolify", "correction": "koolify"}, {"word": "SHA256"}],
    }))
    .unwrap();
    let out = clean_text("say koolify now", &o, &NoLlm);
    assert_eq!(out.final_text, "Legacy Koolify now");
    assert_eq!((out.dict_hits, out.replacements_fired), (1, 1));

    let out = clean_text("ใช้ SHA สองห้าหก", &o, &Fixed("ใช้ SHA256"));
    assert_eq!(out.final_text, "ใช้ SHA256");
}

#[test]
fn corrections_apply_with_cleanup_off() {
    let o = opts(
        json!({"cleanup": false, "dictionary": [{"word": "Koolify", "correction": "koolify"}]}),
    )
    .unwrap();
    let out = clean_text("ask koolify", &o, &NoLlm);
    assert_eq!(
        (out.final_text.as_str(), out.replacements_fired),
        ("ask Koolify", 1)
    );
}

#[test]
fn an_llm_that_drops_a_dictionary_word_is_rejected() {
    let o = opts(
        json!({"thai_format": false, "dictionary": [{"word": "เจนจิรา", "correction": "เจนจิลา"}]}),
    )
    .unwrap();
    let out = clean_text("คุณเจนจิลามาไหม", &o, &Fixed("คุณ Janejira มาไหม"));
    assert_eq!(out.final_text, "คุณเจนจิรามาไหม");
    assert_eq!(out.guardrail_flag, DICTIONARY_FLAG);
}

#[test]
fn stt_prompt_lists_starred_dictionary_words_first() {
    let o = opts(json!({
        "vocabulary": ["Kafka"],
        "dictionary": [{"word": "Grafana"}, {"word": "Koolify", "starred": true}],
    }))
    .unwrap();
    assert_eq!(
        initial_prompt(None, &o.effective_vocabulary(), false),
        Some("Koolify, Grafana, Kafka".to_string())
    );
}

/// Both entry points: the API-style `clean_text` and the sidecar's `local::clean`.
fn both(text: &str, o: &Options, llm: &dyn Llm) -> [String; 2] {
    [
        clean_text(text, o, llm).final_text,
        oliv_pipeline::local::clean(text, None, o, false, llm)
            .outcome
            .final_text,
    ]
}

#[test]
fn each_correction_applies_once() {
    // A chain migrated from 0.2.0 replacements: one pass, like the legacy table.
    let o = opts(json!({
        "thai_format": false,
        "dictionary": [{"word": "bar", "correction": "foo"}, {"word": "baz", "correction": "bar"}],
    }))
    .unwrap();
    assert_eq!(both("say foo", &o, &NoLlm), ["say bar", "say bar"]);

    // A word that contains what was heard is not expanded twice.
    let o = opts(json!({
        "thai_format": false,
        "dictionary": [{"word": "ประเทศไทย", "correction": "ไทย"}],
    }))
    .unwrap();
    for out in both("ไปไทยไหม", &o, &Fixed("ไปประเทศไทยไหม"))
    {
        assert_eq!(out.matches("ประเทศ").count(), 1, "{out}");
    }
}

#[test]
fn vocabulary_only_leaves_verbatim_text_alone() {
    let o = opts(json!({
        "cleanup": false,
        "thai_format": false,
        "dictionary": [{"word": "SHA256"}, {"word": "Grafana"}],
    }))
    .unwrap();
    for text in ["ไทย ไทย", "ใช้ SHA สองห้าหก"] {
        assert_eq!(both(text, &o, &NoLlm), [text, text]);
    }
}

#[test]
fn a_phrase_the_cleanup_model_produced_is_still_corrected() {
    let o = opts(json!({
        "thai_format": false,
        "dictionary": [{"word": "Bar", "correction": "foo"}, {"word": "baz", "correction": "Bar"}],
    }))
    .unwrap();
    // The LLM fixed "fooo" into the configured phrase "foo": corrected once.
    assert_eq!(
        both("ใช้ fooo x", &o, &Fixed("ใช้ foo x")),
        ["ใช้ Bar x", "ใช้ Bar x"]
    );
}

#[test]
fn legacy_snippets_never_rewrite_a_dictionary_output() {
    let long = "x".repeat(101);
    let o = opts(json!({
        "thai_format": false,
        "replacements": {"bar": long},
        "dictionary": [{"word": "bar", "correction": "foo"}],
    }))
    .unwrap();
    assert_eq!(both("say foo", &o, &NoLlm), ["say bar", "say bar"]);
}

#[test]
fn the_post_pass_protects_only_what_the_pre_pass_wrote() {
    let o = |dict: Value, replacements: Value| {
        opts(json!({"thai_format": false, "dictionary": dict, "replacements": replacements}))
            .unwrap()
    };
    // Case-only correction the LLM undid: corrected again.
    let d = o(json!([{"word": "Foo", "correction": "foo"}]), json!({}));
    assert_eq!(
        both("ใช้ foo x", &d, &Fixed("ใช้ foo x")),
        ["ใช้ Foo x", "ใช้ Foo x"]
    );
    // An LLM-created source equal to another rule's output, none pre-written.
    let d = o(
        json!([{"word": "Bar", "correction": "foo"}, {"word": "baz", "correction": "Bar"}]),
        json!({}),
    );
    assert_eq!(
        both("ใช้ Barr x", &d, &Fixed("ใช้ Bar x")),
        ["ใช้ baz x", "ใช้ baz x"]
    );
    // An unused correction never shields an unrelated legacy phrase.
    let d = o(
        json!([{"word": "bar", "correction": "foo"}]),
        json!({"bar code": "BC"}),
    );
    assert_eq!(both("scan bar code", &d, &NoLlm), ["scan BC", "scan BC"]);
}

#[test]
fn a_longer_legacy_phrase_beats_a_shorter_dictionary_correction() {
    let long = "y".repeat(101);
    let want = format!("say {long}");
    for cleanup in [true, false] {
        let o = opts(json!({
            "cleanup": cleanup,
            "thai_format": false,
            "replacements": {"foo bar": long},
            "dictionary": [{"word": "Short", "correction": "foo"}],
        }))
        .unwrap();
        assert_eq!(
            both("say foo bar", &o, &NoLlm),
            [want.clone(), want.clone()],
            "cleanup={cleanup}"
        );
    }
}
