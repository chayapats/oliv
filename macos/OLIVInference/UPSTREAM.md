# Native inference provenance

The helper runs only on Apple Silicon, uses existing Hugging Face cache files,
and loads models only after an explicit local inference / warm request.
It contains no Python interpreter or Python imports.

Whisper config, attention, weight mapping, tokenizer, and mel feature code are
adapted from [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), commit
`dbe5eaac964e8257785f9d015c81f819a38016a8` (MIT; see LICENSE-mlx-audio-swift).
OLIV adds language detection, initial hints, log probability scoring, temperature
fallback, bounded IPC, offline model loading and native file resampling.
Legacy Whisper NPZ weights load through macOS's unzip and MLX's native NPY
reader, validating flat entry names and sizes before temporary extraction.
The extracted arrays are evaluated before removing the temporary directory.
The timestamp decode/seek policy, precise attention and frozen mel filterbank
coefficients follow Apple's mlx-whisper 0.4.3 (MIT; LICENSE-mlx-whisper).
The two binary filterbanks are little-endian Float32, shaped 80/128 × 201.

Gemma 4 text inference uses Apple's [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
commit `3615fe461c7c8c5ff90c40c70ca30e8b46399727`, and MLX Swift 0.32.3 (MIT).
Thinking is disabled and generation is greedy, capped at 200 tokens.
Tokenization and decoding use Hugging Face tokenizers 0.22.2 (Apache-2.0),
linked statically from Rust through a narrow private C ABI. swift-transformers
1.1.6 renders the chat template only; its token output is decoded/re-encoded
with the Rust tokenizer because its Gemma byte fallback/pretokenization differs
from the checkpoint's reference implementation. Downloads use
swift-huggingface 0.8.1 (Apache-2.0), preserving the standard HF cache layout.

Bundled Whisper tokenizer JSON files come from openai/whisper-large-v3 at
`06f233fe06e710322aca913c1bc4249a0d71fce1` (Apache-2.0). No model weights or
private recordings are embedded. The tokenizer eliminates first-inference
network access for the three supported multilingual Whisper checkpoints.
