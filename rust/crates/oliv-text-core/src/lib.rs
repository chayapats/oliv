//! Deterministic Thai/English text core shared by the OLIV Mac app
//! (`oliv-text`) and the OLIV server (`chayapats/oliv-server`): Thai word
//! segmentation (newmm + TCC over the pythainlp 5.3.4 word list), the built-in
//! dictionary and canonical casing, Thai number words, RTGS romanization,
//! phonetic vocabulary matching, and evaluation metrics.
//!
//! Everything here is pure and model-free. Change behavior here once; both
//! consumers pick it up by version.
pub mod data;
pub mod dictionary;
mod dictionary_tables;
pub mod metrics;
pub mod phonetic;
pub mod pyu;
pub mod royin;
pub mod tokenize;
pub mod trie;
pub mod wordtonum;
