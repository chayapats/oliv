//! Portable OLIV text pipeline, extracted from the OLIV server (`server/`).
//!
//! The deterministic text core (segmentation, dictionary, numbers, phonetic
//! matching, metrics, the script and Thai-speech cleanup guards) lives in
//! `oliv-text-core`, shared with the OLIV server; it is re-exported here so
//! `crate::pyu` etc. keep working.
pub use oliv_text_core::{
    cleanup_guard, data, dictionary, metrics, phonetic, pyu, royin, script, tokenize, trie,
    user_dictionary, wordtonum,
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
mod prompts_transform;
pub mod screen;
pub mod spacing;
pub mod stt;
pub mod thai_format;
pub mod transform;
