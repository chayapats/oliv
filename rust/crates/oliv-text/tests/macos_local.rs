mod common;
use oliv_pipeline::{
    audio, commands,
    dictate::Options,
    llm::{Llm, LlmError, Request},
    local,
};
use serde_json::json;
struct MustNotRun;
impl Llm for MustNotRun {
    fn generate(&self, _: &Request) -> Result<String, LlmError> {
        panic!("Gate must not call inference")
    }
}
#[test]
fn commands_match_mac_reference() {
    common::check("macos_commands.jsonl", |v| {
        let (text, n) = commands::apply(common::s(&v["args"][0]));
        Ok(json!([text, n]))
    });
}
#[test]
fn silence_uses_frame_counts_and_ignores_tail() {
    assert!(audio::is_silent(&vec![0.; 16000]));
    assert!(audio::is_silent(&vec![0.02; 2399]));
    assert!(!audio::is_silent(&vec![0.02; 2400]));
    let mut samples = vec![0.; 16000];
    samples[..2400].fill(0.02);
    assert!(!audio::is_silent(&samples));
    samples[..480].fill(0.);
    assert!(audio::is_silent(&samples));
}
#[test]
fn prompt_is_capped_without_losing_commands() {
    assert_eq!(commands::initial_prompt(None, &[], false), None);
    let prompt = commands::initial_prompt(Some(&"ก".repeat(3000)), &[], true).unwrap();
    assert_eq!(prompt.chars().count(), 960);
    assert!(prompt.ends_with("bullet point"));
    assert!(!prompt.contains("นิวไลน์"));
}
#[test]
fn gates_and_segment_replacements_do_not_call_model() {
    let mut opts = Options {
        cleanup: false,
        remove_fillers: false,
        thai_format: false,
        ..Options::default()
    };
    let pure = local::clean("日本語", Some(2.), &opts, false, &MustNotRun);
    assert!(pure.outcome.no_speech);
    assert_eq!(local::clean("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop",Some(1.),&opts,false,&MustNotRun).outcome.gate_reason,"too_long");
    opts.replacements = vec![("hello".into(), "world".into())];
    let result = local::clean("hello new line hello", None, &opts, true, &MustNotRun);
    assert_eq!(result.outcome.final_text, "world\nworld");
    assert_eq!(result.outcome.replacements_fired, 2);
    assert_eq!(result.format_commands_fired, 1);
}

#[test]
fn llm_failure_keeps_dictionary_corrections() {
    struct Failing;
    impl Llm for Failing {
        fn generate(&self, _: &Request) -> Result<String, LlmError> {
            Err(LlmError("synthetic timeout".into()))
        }
    }
    let opts = Options {
        remove_fillers: false,
        thai_format: false,
        ..Options::default()
    };
    let result = local::clean(
        "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา",
        None,
        &opts,
        false,
        &Failing,
    );
    assert_eq!(
        result.outcome.final_text,
        "restart server แล้วเช็คล็อกใน Grafana"
    );
    assert_eq!(result.outcome.guardrail_flag, "llmError->dict");
    assert!(result.outcome.cleanup_error.is_some());
}

struct Fixed(&'static str);
impl Llm for Fixed {
    fn generate(&self, _: &Request) -> Result<String, LlmError> {
        Ok(self.0.into())
    }
}

#[test]
fn other_scripts_in_a_transcript_are_dropped() {
    let opts = Options {
        cleanup: false,
        remove_fillers: false,
        thai_format: false,
        ..Options::default()
    };
    // FLEURS Thai: a hallucinated tail ended in Cyrillic and an undecodable byte.
    let result = local::clean("ที่ควิเ\u{fffd} Ал", Some(5.), &opts, false, &MustNotRun);
    assert_eq!(result.outcome.final_text, "ที่ควิเ");
    // Nothing else left: no speech, like a CJK-only caption.
    assert!(
        local::clean("Ал", Some(2.), &opts, false, &MustNotRun)
            .outcome
            .no_speech
    );
}

#[test]
fn cleanup_that_writes_another_script_is_rejected() {
    let opts = Options {
        remove_fillers: false,
        thai_format: false,
        ..Options::default()
    };
    // FLEURS Thai: the cleanup model wrote a Hangul syllable for ทูป, and Lao
    // letters into ซึนดาบันส์.
    let cases = [
        (
            "ส่งผลให้ ทูปปัว ธามาซิส รีรอฟฟิ ผู้เป็นหัวหน้าใหญ่",
            Fixed("ส่งผลให้ 투ปัวธามาซิสรีรอฟฟิผู้เป็นหัวหน้าใหญ่"),
            "ส่งผลให้ทูปปัวธามาซิสรีรอฟฟิผู้เป็นหัวหน้าใหญ่",
        ),
        (
            "องค์กร UNESCO ประกาศให้ซึนดาบันส์ เป็นมรดกโลก",
            Fixed("องค์กร UNESCO ประกาศให้\u{e8a}ึน\u{e94}\u{eb2}\u{e9a}\u{eb1}\u{e99}ส์เป็นมรดกโลก"),
            "องค์กร UNESCO ประกาศให้ซึนดาบันส์เป็นมรดกโลก",
        ),
    ];
    for (text, llm, expected) in cases {
        let result = local::clean(text, None, &opts, false, &llm);
        assert!(result.outcome.llm_ran);
        assert_eq!(result.outcome.guardrail_flag, "script->dict");
        assert_eq!(result.outcome.final_text, expected);
    }
}
