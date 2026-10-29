//! oliv-pipeline: Rust port of Oliv's text pipeline and the pythainlp 5.3.4
//! pieces it depends on.
//!
//! The deterministic text core (segmentation, built-in dictionary, numbers,
//! romanization, phonetic matching, metrics, user dictionary) comes from the
//! `oliv-text-core` crate shared with the Mac app; it is re-exported so
//! `crate::pyu` etc. keep working.
pub use oliv_text_core::{
    data, dictionary, metrics, phonetic, pyu, royin, tokenize, trie, user_dictionary, wordtonum,
};

pub mod admission;
pub mod api;
pub mod asrfix;
pub mod audio;
pub mod audit;
pub mod auth;
pub mod config;
pub mod dictate;
pub mod dictionary_store;
pub mod fillers;
pub mod foreign;
pub mod gate;
pub mod guardrail;
pub mod hallucination;
mod http;
pub mod llm;
pub mod pipeline;
mod prompts_text;
pub mod spacing;
pub mod stt;
pub mod thai_format;

mod transport;

pub mod stage_gate;
