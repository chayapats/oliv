//! Portable OLIV text pipeline, extracted from OLIV Linux 0000a4d.
//!
//! The deterministic text core (segmentation, dictionary, numbers, phonetic
//! matching, metrics) lives in `oliv-text-core`, shared with oliv-server; it is
//! re-exported here so `crate::pyu` etc. keep working.
pub use oliv_text_core::{
    data, dictionary, metrics, phonetic, pyu, royin, tokenize, trie, user_dictionary, wordtonum,
};

pub mod audio;
pub mod commands;
pub mod dictate;
pub mod fillers;
pub mod gate;
pub mod guardrail;
pub mod hallucination;
pub mod llm;
pub mod local;
pub mod pipeline;
mod prompts_text;
pub mod spacing;
pub mod stt;
pub mod thai_format;
