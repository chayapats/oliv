//! The sidecar dictate text path after STT (`/v1/clean`, and `/v1/dictate` once
//! STT has run): CJK strip -> hallucination gate -> fillers -> `clean_ex` ->
//! user replacements -> Thai format. Audio-only gates and spoken formatting
//! commands are not part of OLIV Linux v1.

use serde::Serialize;
use serde_json::{Map, Value};

use crate::fillers::remove_fillers;
use crate::hallucination::{strip_cjk, text_hallucination};
use crate::llm::{Llm, Prompt};
use crate::pipeline::clean_ex;
use crate::pyu::is_blank;
use crate::thai_format::apply_thai_format;

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
    pub prompt: Prompt,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            cleanup: true,
            remove_fillers: true,
            thai_format: true,
            vocabulary: Vec::new(),
            replacements: Vec::new(),
            prompt: Prompt::default(),
        }
    }
}

impl Options {
    /// Read the option fields of a request body; other fields are ignored.
    /// `prompt` falls back to `default_prompt`. Wrong types are an error.
    pub fn from_json(body: &Map<String, Value>, default_prompt: Prompt) -> Result<Self, String> {
        let mut o = Options {
            prompt: default_prompt,
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
        Ok(o)
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

    let mut t = strip_cjk(text);
    if !is_blank(text) && is_blank(&t) {
        return no_speech("no_speech");
    }
    if !is_blank(&t) && text_hallucination(&t) {
        return no_speech("hallucination");
    }
    if opts.remove_fillers && !is_blank(&t) {
        (t, out.fillers_removed) = remove_fillers(&t);
    }

    // _clean_and_replace_segments with a single segment
    let mut seg = t;
    if opts.cleanup && !is_blank(&seg) {
        let r = clean_ex(&seg, &opts.vocabulary, opts.prompt, llm);
        seg = r.text;
        out.llm_ran = r.llm_ran;
        out.dict_hits = r.dict_hits;
        out.vocab_fired = r.vocab_fired;
        out.gate_reason = r.gate_reason;
        out.guardrail_flag = r.guardrail_flag;
        out.cleanup_error = r.llm_error;
    }
    if !opts.replacements.is_empty() && !is_blank(&seg) {
        let table: Vec<(&str, &str)> = opts
            .replacements
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        let (s, n) = crate::pipeline::apply_replacements(&seg, &table);
        seg = s;
        out.replacements_fired = n;
    }

    if opts.thai_format && !is_blank(&seg) {
        (seg, out.thai_format_fired) = apply_thai_format(&seg);
    }
    out.final_text = seg;
    out
}
