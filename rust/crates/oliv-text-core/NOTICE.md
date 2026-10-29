# Licensing of oliv-text-core

This crate is `MIT AND Apache-2.0`.

- **Apache-2.0** ([LICENSE-APACHE](LICENSE-APACHE)): line-by-line Rust ports of
  [PyThaiNLP](https://github.com/PyThaiNLP/pythainlp) 5.3.4, Copyright the
  PyThaiNLP Project. These are `src/tokenize.rs` (newmm + TCC),
  `src/royin.rs` (royin romanization), `src/wordtonum.rs` (`words_to_num`) and
  `src/trie.rs` (`Trie`). The word lists in `data/` keep their own
  [LICENSE-pythainlp](data/LICENSE-pythainlp).
- **MIT** ([LICENSE](../../../LICENSE)): everything else in this crate.
