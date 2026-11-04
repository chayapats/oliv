//! Deterministic Thai/English text core shared by the OLIV Mac app
//! (`oliv-text`) and the OLIV server (`server/oliv-api`): Thai word
//! segmentation (newmm + TCC over the pythainlp 5.3.4 word list), the built-in
//! dictionary and canonical casing, Thai number words, RTGS romanization,
//! phonetic vocabulary matching, the user dictionary, evaluation metrics, and
//! the cleanup guards both pipelines apply (other scripts, Thai speech the
//! cleanup model rewrote, listed terms).
//!
//! Everything here is pure and model-free. Change behavior here once; both
//! consumers pick it up by version.
pub mod cleanup_guard;
pub mod data;
pub mod dictionary;
mod dictionary_tables;
pub mod metrics;
pub mod phonetic;
pub mod pyu;
pub mod royin;
pub mod script;
mod thai;
pub mod tokenize;
pub mod trie;
pub mod user_dictionary;
pub mod wordtonum;
