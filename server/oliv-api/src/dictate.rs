//! The sidecar dictate text path after STT (`/v1/clean`, and `/v1/dictate` once
//! STT has run): foreign-script romanization (qwen3asr) -> CJK strip -> hallucination gate
//! -> fillers -> spelled-letter join -> `clean_ex` -> user replacements -> Thai
//! format. Audio-only gates and spoken formatting commands are not part of OLIV
//! Linux v1.

use std::str::FromStr;

use serde::Serialize;
use serde_json::{Map, Value};

use crate::asrfix::join_spelled;
use crate::fillers::remove_fillers;
use crate::foreign::romanize_embedded;
use crate::hallucination::{strip_cjk, text_hallucination, trim_repetition_loops};
use crate::llm::{Llm, Prompt};
use crate::pipeline::clean_ex;
use crate::pyu::is_blank;
use crate::thai_format::apply_thai_format;
use crate::user_dictionary::UserDictionary;

/// The STT model behind the text (`[api] asr_profile`, or per request). It
/// picks the decode in `/v1/dictate` and lets cleanup adapt to the model.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum AsrProfile {
    /// typhoon-whisper-turbo: auto decode, forced-English re-decode when unconfident.
    #[default]
    Turbo,
    /// Qwen3-ASR: one auto decode with the vocabulary as context.
    Qwen3Asr,
    /// typhoon-whisper-large-v3 with context: decoded like Turbo.
    TyphoonCtx,
}

impl AsrProfile {
    pub fn name(self) -> &'static str {
        match self {
            AsrProfile::Turbo => "turbo",
            AsrProfile::Qwen3Asr => "qwen3asr",
            AsrProfile::TyphoonCtx => "typhoon-ctx",
        }
    }
}

const BAD_PROFILE: &str = "asr_profile must be turbo, qwen3asr or typhoon-ctx";

impl FromStr for AsrProfile {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "turbo" => Ok(AsrProfile::Turbo),
            "qwen3asr" => Ok(AsrProfile::Qwen3Asr),
            "typhoon-ctx" => Ok(AsrProfile::TyphoonCtx),
            _ => Err(BAD_PROFILE.into()),
        }
    }
}

/// Per-request options (the JSON body fields besides the text/audio).
/// Every pass is on unless the request turns it off.
#[derive(Clone, Debug)]
pub struct Options {
    pub cleanup: bool,
    pub remove_fillers: bool,
    pub thai_format: bool,
    pub vocabulary: Vec<String>,
    /// `{spoken: replacement}` in the request's key order.
    pub replacements: Vec<(String, String)>,
    /// The caller's stored personal dictionary (never read from the request
    /// body; the API loads it for the authenticated key).
    pub dictionary: UserDictionary,
    pub prompt: Prompt,
    pub asr_profile: AsrProfile,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            cleanup: true,
            remove_fillers: true,
            thai_format: true,
            vocabulary: Vec::new(),
            replacements: Vec::new(),
            dictionary: UserDictionary::default(),
            prompt: Prompt::default(),
            asr_profile: AsrProfile::default(),
        }
    }
}

impl Options {
    /// Read the option fields of a request body; other fields are ignored.
    /// `prompt` and `asr_profile` fall back to the server's defaults. Wrong types
    /// are an error.
    pub fn from_json(
        body: &Map<String, Value>,
        default_prompt: Prompt,
        default_profile: AsrProfile,
    ) -> Result<Self, String> {
        let mut o = Options {
            prompt: default_prompt,
            asr_profile: default_profile,
            ..Options::default()
        };
        let flag = |key: &str, dflt: bool| match body.get(key) {
            None | Some(Value::Null) => Ok(dflt),
            Some(Value::Bool(b)) => Ok(*b),
            Some(_) => Err(format!("{key} must be true or false")),
        };
        o.cleanup = flag("cleanup", true)?;
        o.remove_fillers = flag("remove_fillers", true)?;
        o.thai_format = flag("thai_format", true)?;
        match body.get("vocabulary") {
            None | Some(Value::Null) => {}
            Some(Value::Array(a)) => {
                o.vocabulary = a
                    .iter()
                    .map(|t| t.as_str().map(str::to_string))
                    .collect::<Option<_>>()
                    .ok_or("vocabulary must be a list of strings")?;
            }
            Some(_) => return Err("vocabulary must be a list of strings".into()),
        }
        match body.get("replacements") {
            None | Some(Value::Null) => {}
            Some(Value::Object(m)) => {
                o.replacements = m
                    .iter()
                    .map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string())))
                    .collect::<Option<_>>()
                    .ok_or("replacements must map strings to strings")?;
            }
            Some(_) => return Err("replacements must map strings to strings".into()),
        }
        match body.get("prompt") {
            None | Some(Value::Null) => {}
            Some(Value::String(p)) => o.prompt = p.parse()?,
            Some(_) => return Err("prompt must be a string".into()),
        }
        match body.get("asr_profile") {
            None | Some(Value::Null) => {}
            Some(Value::String(p)) => o.asr_profile = p.parse()?,
            Some(_) => return Err(BAD_PROFILE.into()),
        }
        Ok(o)
    }

    /// STT bias and fuzzy vocabulary: dictionary words (starred first), then
    /// request `vocabulary` terms not already present.
    pub fn effective_vocabulary(&self) -> Vec<String> {
        self.dictionary.merged_vocabulary(&self.vocabulary)
    }
}

/// The text part of a dictate/clean reply.
#[derive(Clone, Debug, Default, Serialize, PartialEq)]
pub struct Outcome {
    #[serde(rename = "final")]
    pub final_text: String,
    pub no_speech: bool,
    pub llm_ran: bool,
    pub gate_reason: String,
    pub guardrail_flag: String,
    pub dict_hits: usize,
    pub vocab_fired: usize,
    pub fillers_removed: usize,
    pub replacements_fired: usize,
    pub thai_format_fired: usize,
    pub cleanup_error: Option<String>,
}

/// Non-space chars a transcript needs outside its decoder loops to be kept.
const LOOP_MIN_OUTSIDE_CHARS: usize = 8;

pub fn clean_text(text: &str, opts: &Options, llm: &dyn Llm) -> Outcome {
    let mut out = Outcome {
        final_text: text.to_string(),
        ..Default::default()
    };
    let no_speech = |reason: &str| Outcome {
        final_text: String::new(),
        no_speech: true,
        gate_reason: reason.to_string(),
        ..Default::default()
    };

    // Qwen3-ASR writes syllables in other scripts: `рейтลิมิต` -> `reyt ลิมิต`,
    // and the LLM then restores the word by sound. Whisper models write kana
    // and Hangul only as caption hallucinations, which strip_cjk removes.
    let (romanized, foreign) = if opts.asr_profile == AsrProfile::Qwen3Asr {
        romanize_embedded(text)
    } else {
        (text.to_string(), false)
    };
    let mut t = strip_cjk(&romanized);
    if !is_blank(text) && is_blank(&t) {
        return no_speech("no_speech");
    }
    // Keep the speech in front of a decoder loop; a loop with (almost) nothing
    // around it is still a hallucination.
    if let Some((trimmed, outside)) = trim_repetition_loops(&t) {
        if outside < LOOP_MIN_OUTSIDE_CHARS {
            return no_speech("hallucination");
        }
        t = trimmed;
    }
    if !is_blank(&t) && text_hallucination(&t) {
        return no_speech("hallucination");
    }
    if opts.remove_fillers && !is_blank(&t) {
        (t, out.fillers_removed) = remove_fillers(&t);
    }
    // Qwen3-ASR spells letters out: `G P U` -> `GPU` before the gate and
    // guardrail count its tokens. Other models write acronyms whole.
    if opts.asr_profile == AsrProfile::Qwen3Asr {
        t = join_spelled(&t).0;
    }

    // _clean_and_replace_segments with a single segment
    let mut seg = t;
    let mut corrected = Vec::new();
    if opts.cleanup && !is_blank(&seg) {
        let r = clean_ex(
            &seg,
            &opts.effective_vocabulary(),
            &opts.dictionary,
            opts.prompt,
            opts.asr_profile,
            foreign.then_some("foreign-script"),
            llm,
        );
        seg = r.text;
        out.llm_ran = r.llm_ran;
        out.dict_hits = r.dict_hits;
        out.vocab_fired = r.vocab_fired;
        out.gate_reason = r.gate_reason;
        out.guardrail_flag = r.guardrail_flag;
        out.cleanup_error = r.llm_error;
        corrected = r.corrected;
    }
    // Runs with cleanup off too: the user's words are always theirs.
    if (!opts.replacements.is_empty() || !opts.dictionary.is_empty()) && !is_blank(&seg) {
        let (s, n) = crate::pipeline::apply_replacements(
            &seg,
            &opts.dictionary,
            &opts.replacements,
            &corrected,
        );
        seg = s;
        out.replacements_fired = n;
    }

    if opts.thai_format && !is_blank(&seg) {
        (seg, out.thai_format_fired) = apply_thai_format(&seg);
    }
    out.final_text = seg;
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{LlmError, Request};
    use serde_json::json;

    /// Returns the text unchanged.
    struct Echo;

    impl Llm for Echo {
        fn generate(&self, req: &Request) -> Result<String, LlmError> {
            Ok(req.text.to_string())
        }
    }

    fn parse(body: Value, default_profile: AsrProfile) -> Result<Options, String> {
        Options::from_json(body.as_object().unwrap(), Prompt::V5, default_profile)
    }

    #[test]
    fn profile_names_round_trip() {
        for p in [
            AsrProfile::Turbo,
            AsrProfile::Qwen3Asr,
            AsrProfile::TyphoonCtx,
        ] {
            assert_eq!(p.name().parse::<AsrProfile>(), Ok(p));
        }
        assert_eq!(AsrProfile::default(), AsrProfile::Turbo);
        assert_eq!(Options::default().asr_profile, AsrProfile::Turbo);
    }

    #[test]
    fn profile_defaults_to_the_server_setting() {
        for d in [AsrProfile::Turbo, AsrProfile::Qwen3Asr] {
            assert_eq!(parse(json!({}), d).unwrap().asr_profile, d);
            assert_eq!(
                parse(json!({"asr_profile": null}), d).unwrap().asr_profile,
                d
            );
        }
    }

    #[test]
    fn request_overrides_profile() {
        let o = parse(json!({"asr_profile": "typhoon-ctx"}), AsrProfile::Qwen3Asr).unwrap();
        assert_eq!(o.asr_profile, AsrProfile::TyphoonCtx);
        assert_eq!(o.prompt, Prompt::V5);
        let o = parse(json!({"asr_profile": "turbo"}), AsrProfile::Qwen3Asr).unwrap();
        assert_eq!(o.asr_profile, AsrProfile::Turbo);
    }

    #[test]
    fn bad_profile_is_an_error() {
        for bad in [
            json!("Turbo"),
            json!("qwen"),
            json!(""),
            json!(1),
            json!(["turbo"]),
        ] {
            let e = parse(json!({"asr_profile": bad}), AsrProfile::Turbo).unwrap_err();
            assert_eq!(e, "asr_profile must be turbo, qwen3asr or typhoon-ctx");
        }
    }

    #[test]
    fn speech_before_a_decoder_loop_is_kept() {
        let opts = Options {
            cleanup: false,
            ..Options::default()
        };
        let text = format!("the latency is a bit high {} ต", ["ต้อง"; 30].join(" "));
        let out = clean_text(&text, &opts, &Echo);
        assert!(!out.no_speech);
        assert_eq!(out.final_text, "the latency is a bit high ต้อง");
    }

    #[test]
    fn spelled_letters_are_joined_before_cleanup() {
        let qwen = Options {
            asr_profile: AsrProfile::Qwen3Asr,
            ..Options::default()
        };
        let out = clean_text("ร้านนี้ขาย G P U มือสอง", &qwen, &Echo);
        assert_eq!(out.final_text, "ร้านนี้ขาย GPU มือสอง");
        assert!(
            !out.gate_reason.contains("latin-crumb"),
            "{}",
            out.gate_reason
        );
    }

    #[test]
    fn spelled_letters_are_joined_only_for_qwen3asr() {
        let off = |asr_profile| Options {
            cleanup: false,
            asr_profile,
            ..Options::default()
        };
        for p in [AsrProfile::Turbo, AsrProfile::TyphoonCtx] {
            for text in ["Vitamin C I think", "OK one more thing", "ใช้ S three"] {
                assert_eq!(clean_text(text, &off(p), &Echo).final_text, text, "{p:?}");
            }
        }
        let out = clean_text("ใช้ S three", &off(AsrProfile::Qwen3Asr), &Echo);
        assert_eq!(out.final_text, "ใช้ S3");
    }

    #[test]
    fn embedded_foreign_script_is_romanized_for_the_llm() {
        let qwen = Options {
            asr_profile: AsrProfile::Qwen3Asr,
            ..Options::default()
        };
        let out = clean_text("ตั้ง рейтลิมิตก่อน", &qwen, &Echo);
        assert!(out.llm_ran);
        assert!(
            out.gate_reason.contains("foreign-script"),
            "{}",
            out.gate_reason
        );
        assert!(out.final_text.contains("reyt"), "{}", out.final_text);
        assert!(!out.final_text.contains('р'), "{}", out.final_text);
    }

    #[test]
    fn foreign_script_is_romanized_only_for_qwen3asr() {
        for p in [AsrProfile::Turbo, AsrProfile::TyphoonCtx] {
            let opts = Options {
                asr_profile: p,
                ..Options::default()
            };
            let out = clean_text("เช็กไทม์ของレスポン ผม", &opts, &Echo);
            assert!(!out.final_text.contains("resupon"), "{p:?}");
            assert!(!out.gate_reason.contains("foreign-script"), "{p:?}");
        }
    }

    #[test]
    fn caption_tails_are_stripped_for_every_profile() {
        for p in [
            AsrProfile::Turbo,
            AsrProfile::Qwen3Asr,
            AsrProfile::TyphoonCtx,
        ] {
            let opts = Options {
                asr_profile: p,
                cleanup: false,
                ..Options::default()
            };
            for (text, want) in [
                ("ประชุมเสร็จแล้ว 감사합니다", "ประชุมเสร็จแล้ว"),
                ("ขอบคุณครับ 감사합니다", "ขอบคุณครับ"),
                ("โอเคครับ ありがとう", "โอเคครับ"),
                ("วันนี้พอแค่นี้ ありがとう", "วันนี้พอแค่นี้"),
                ("สวัสดี 안녕하세요", "สวัสดี"),
                ("ok 시청해 주셔서 감사합니다.", "ok ."),
                ("ok 감사합니다", "ok"),
            ] {
                let out = clean_text(text, &opts, &Echo);
                assert_eq!(out.final_text, want, "{p:?} {text}");
                assert!(!out.gate_reason.contains("foreign-script"), "{p:?} {text}");
            }
        }
        let opts = Options {
            asr_profile: AsrProfile::Qwen3Asr,
            ..Options::default()
        };
        let out = clean_text("ประชุมเสร็จแล้ว 감사합니다", &opts, &Echo);
        assert_eq!(out.final_text, "ประชุมเสร็จแล้ว");
        assert_eq!(out.guardrail_flag, "ok");
    }

    #[test]
    fn foreign_captions_are_still_stripped() {
        let out = clean_text("アイウエオカキクケコ", &Options::default(), &Echo);
        assert!(out.no_speech);
        assert_eq!(out.gate_reason, "no_speech");
        let out = clean_text("วันนี้ดี アイウエオカキクケコ", &Options::default(), &Echo);
        assert_eq!(out.final_text, "วันนี้ดี");
        assert!(!out.gate_reason.contains("foreign-script"));
    }

    #[test]
    fn repeated_digits_are_not_trimmed_into_a_wrong_number() {
        let opts = Options {
            cleanup: false,
            ..Options::default()
        };
        for text in ["เบอร์ 0 8 1 1 1 1 1 1 2 3", "รหัสผ่าน 1 1 1 1 1 1"]
        {
            let out = clean_text(text, &opts, &Echo);
            assert!(out.no_speech, "{text}: {:?}", out.final_text);
            assert_eq!(out.gate_reason, "hallucination");
        }
        let out = clean_text("ha ha ha ha ha ha that's funny", &opts, &Echo);
        assert_eq!(out.final_text, "ha that's funny");
    }

    #[test]
    fn bare_loops_are_still_hallucinations() {
        let short = format!("ok {}", ["ค่ะ"; 30].join(" "));
        for text in [["ค่ะ"; 30].join(" "), short, "คือ".repeat(20)] {
            let out = clean_text(&text, &Options::default(), &Echo);
            assert!(out.no_speech, "{text}");
            assert_eq!(out.gate_reason, "hallucination");
            assert_eq!(out.final_text, "");
        }
    }
}
