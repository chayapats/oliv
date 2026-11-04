# Reproducing the Core ML artifacts

Conversion is a separate research step. Python, PyTorch and these environments
stay under ignored `build/`; the app and Swift benchmark runners do not embed
them. Commands below run from the repository root. They use public model
weights, not recordings.

## Pinned inputs

- `typhoon-ai/typhoon-whisper-turbo` revision
  `3c03fa84c26f172944422ceb8a4e88a2dbc08b10`.
- [whisperkittools](https://github.com/argmaxinc/whisperkittools) revision
  `84f77a83c8f530022ae55fbb1a64b3351ef63c7a`.
- Python 3.11, PyTorch 2.5.0, Transformers 4.53.0, coremltools 9.0.
- Swift runtime pin is in [Package.swift](Package.swift).

```sh
uv venv --python 3.11 build/coreml-env
git clone https://github.com/argmaxinc/whisperkittools.git build/whisperkittools
git -C build/whisperkittools checkout 84f77a83c8f530022ae55fbb1a64b3351ef63c7a
uv pip install --python build/coreml-env/bin/python \
  -e build/whisperkittools coremltools==9.0
build/coreml-env/bin/hf download typhoon-ai/typhoon-whisper-turbo \
  --revision 3c03fa84c26f172944422ceb8a4e88a2dbc08b10 \
  --local-dir build/typhoon-source
```

## Reference cache setting

The checkpoint's training configuration has `use_cache: false`. The converter's
decoder parity test supplies past keys and values; its Hugging Face reference
must actually use them. Change **the downloaded build copy's config**, leaving
all weights unchanged:

```sh
jq '.use_cache = true' build/typhoon-source/config.json > build/typhoon-source/config.new.json
mv build/typhoon-source/config.new.json build/typhoon-source/config.json
```

Without this, the cached decoder parity test compares different computations
and fails, even when the converted cached decoder is correct. Do not discard
that failure or change the tolerance to hide it.

## Float16 export and numerical checks

Keep the `.mlpackage` sources for compression. This wrapper only sets converter
test options; the stock generation CLI still performs the export and tests.

```sh
HF_HUB_OFFLINE=1 WANDB_MODE=disabled TEST_DEV=cpu build/coreml-env/bin/python - <<'PY' > build/coreml-conversion.log 2>&1
import sys, torch, coremltools as ct
from argmaxtools import test_utils
torch.set_num_threads(6)
torch.manual_seed(2026)
test_utils.TEST_COMPILE_COREML = False  # keep .mlpackage files
test_utils.TEST_COMPUTE_UNIT = ct.ComputeUnit.CPU_ONLY
test_utils.TEST_SKIP_SPEED_TESTS = True
from scripts.generate_model import cli
sys.argv = ["whisperkit-generate-model", "--model-version", "build/typhoon-source",
            "--output-dir", "build/coreml-export"]
cli()
PY
if rg -n 'FAILED|^ERROR:' build/coreml-conversion.log; then exit 1; fi
```

Inspect every test result: the upstream test runner can return exit status zero
even when a test failed. Check original-to-restructured PyTorch parity as well
as PyTorch-to-Core ML parity. The benchmark's decoder check had 100% argmax
agreement and 134 dB PyTorch parity; Core ML decoder/encoder/mel PSNR was
46.9/51.1/67.9 dB. Random fixtures and compute units can change these values;
the tests' acceptance criteria, rather than these exact values, must pass.

The source folder from these commands is
`build/coreml-export/build_typhoon-source`. The measured source learned weights
matched all 586 tensors in OLIV's MLX conversion after mapping and FP16 casting.
This does not imply identical arithmetic or identical decoded tokens across
the two runtime implementations.

## Compression and compiled artifacts

The tested configurations are FP16, symmetric per-channel INT8 linear weight
quantization, and per-tensor 4-bit k-means palettization. These are different
compression methods, not just a changed file label. All leave the mel front
end uncompressed; tensors smaller than 2,048 elements are left alone.

```sh
build/coreml-env/bin/python - <<'PY' > build/coreml-compression.log 2>&1
from pathlib import Path
import shutil
import coremltools as ct
import coremltools.optimize.coreml as opt

source = Path("build/coreml-export/build_typhoon-source")
for precision in ["fp16", "int8", "pal4"]:
    output = Path("build/coreml-" + precision)
    output.mkdir(exist_ok=True)
    for name in ["AudioEncoder", "TextDecoder", "MelSpectrogram"]:
        package = output / (name + ".mlpackage")
        if precision == "fp16" or name == "MelSpectrogram":
            shutil.copytree(source / (name + ".mlpackage"), package)
        else:
            model = ct.models.MLModel(str(source / (name + ".mlpackage")), skip_model_load=True)
            if precision == "int8":
                config = opt.OptimizationConfig(global_config=opt.OpLinearQuantizerConfig(
                    mode="linear_symmetric", dtype="int8", granularity="per_channel", weight_threshold=2048))
                result = opt.linear_quantize_weights(model, config)
            else:
                config = opt.OptimizationConfig(global_config=opt.OpPalettizerConfig(
                    mode="kmeans", nbits=4, weight_threshold=2048))
                result = opt.palettize_weights(model, config)
            result.save(str(package))
        compiled = ct.models.utils.compile_model(str(package))
        shutil.move(compiled, output / (name + ".mlmodelc"))
PY
```

Use fresh output directories when changing these settings. Retain the packages,
conversion logs and compiled model hashes with the local experiment.

## Evaluation

Build the native tools and the two Swift benchmark packages. Point the script
at an eval-format manifest and its audio root:

```sh
MANIFEST=/absolute/path/to/manifest.jsonl AUDIO_ROOT=/absolute/path/to/audio \
TOKENIZER_DIR="$PWD/build/typhoon-source" \
COREML_FP16="$PWD/build/coreml-fp16" COREML_INT8="$PWD/build/coreml-int8" \
COREML_PAL4="$PWD/build/coreml-pal4" LABSE_DIR=/absolute/path/to/LaBSE/snapshot \
bash benchmark/run_ane_foundation.sh
```

The script uses the real Rust sidecar's STT guards, including confidence-based
forced-English retry. It compares Gemma with Apple's local model using the
original prompt and then preservation instructions. To test Apple's documented
content-transformation configuration, set `OLIV_APPLE_TRANSFORM_GUARDRAILS=1`
and choose a **different `OUT`**. It does not make Thai a supported language.

`LATENCY_MANIFEST=/absolute/path/to/same-subset.jsonl` additionally runs the
models together in the live pipeline. Replay timings alone exclude STT.
The script fingerprints its inputs and refuses changed configurations on
resume. Use a fresh `OUT` or `FORCE=1`; also use those after changing the cached
MLX/Gemma weights. It never deletes your data to force a run.

For memory, read the [accounting notes](README.md#memory-accounting), not just
RSS. First Core ML specialization can take minutes; prepare it outside the
production sidecar's timeout and measure steady inference separately.
