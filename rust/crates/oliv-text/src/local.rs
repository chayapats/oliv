//! Local sidecar ordering. Formatting commands split before cleanup, with
//! Thai formatting after the segments are rejoined, matching the Mac app.
use crate::dictate::{Options, Outcome};
use crate::llm::Llm;
use crate::pyu::{is_blank, strip};
use serde::Serialize;

#[derive(Debug, Default, Serialize)]
pub struct LocalOutcome {
    #[serde(flatten)]
    pub outcome: Outcome,
    pub format_commands_fired: usize,
}

pub fn clean(
    text: &str,
    duration: Option<f64>,
    opts: &Options,
    format: bool,
    llm: &dyn Llm,
) -> LocalOutcome {
    let mut t = crate::hallucination::strip_cjk(text);
    let reason = if !is_blank(text) && is_blank(&t) {
        Some("no_speech")
    } else if !is_blank(&t) && crate::hallucination::text_hallucination(&t) {
        Some("hallucination")
    } else if crate::audio::implausible_length(&t, duration) {
        Some("too_long")
    } else {
        None
    };
    if let Some(reason) = reason {
        return LocalOutcome {
            outcome: Outcome {
                no_speech: true,
                gate_reason: reason.to_string(),
                ..Default::default()
            },
            ..Default::default()
        };
    }
    let mut out = LocalOutcome::default();
    if opts.remove_fillers && !is_blank(&t) {
        (t, out.outcome.fillers_removed) = crate::fillers::remove_fillers(&t);
    }
    let (segments, separators) = if format && !is_blank(&t) {
        crate::commands::split(&t)
    } else {
        (vec![t], vec![])
    };
    out.format_commands_fired = separators.len();
    let mut cleaned = Vec::new();
    for mut segment in segments {
        if opts.cleanup && !is_blank(&segment) {
            let r = crate::pipeline::clean_ex(&segment, &opts.vocabulary, opts.prompt, llm);
            segment = r.text;
            out.outcome.llm_ran |= r.llm_ran;
            out.outcome.dict_hits += r.dict_hits;
            out.outcome.vocab_fired += r.vocab_fired;
            if out.outcome.gate_reason.is_empty() {
                out.outcome.gate_reason = r.gate_reason;
            }
            if out.outcome.guardrail_flag.is_empty() {
                out.outcome.guardrail_flag = r.guardrail_flag;
            }
            if r.llm_error.is_some() {
                out.outcome.cleanup_error = r.llm_error;
            }
        }
        if !opts.replacements.is_empty() && !is_blank(&segment) {
            let table: Vec<(&str, &str)> = opts
                .replacements
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str()))
                .collect();
            let (s, n) = crate::pipeline::apply_replacements(&segment, &table);
            segment = s;
            out.outcome.replacements_fired += n;
        }
        cleaned.push(if separators.is_empty() {
            segment
        } else {
            strip(&segment).to_string()
        });
    }
    let mut final_text = if separators.is_empty() {
        cleaned.pop().unwrap_or_default()
    } else {
        crate::commands::join(&cleaned, &separators)
    };
    if opts.thai_format && !is_blank(&final_text) {
        (final_text, out.outcome.thai_format_fired) =
            crate::thai_format::apply_thai_format(&final_text);
    }
    out.outcome.final_text = final_text;
    out
}
