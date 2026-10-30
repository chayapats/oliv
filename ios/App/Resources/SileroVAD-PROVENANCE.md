# Silero VAD in OLIV

OLIV bundles a fixed-shape, 16 kHz Core ML conversion of the official Silero VAD
v6.2.3 model. The app loads the compiled model with
`MLModelConfiguration.computeUnits = .cpuOnly`. It makes no model download and
performs inference only during an explicitly started automatic recording.
The model detects speech activity; it does not transcribe or identify a speaker.

## Upstream and license

- Project: https://github.com/snakers4/silero-vad
- Release: v6.2.3
- Pinned revision: `5cd7945676eb32225748052e2e6a0580e4686a08`
- Source file: `src/silero_vad/data/silero_vad.jit`
- Source URL: https://raw.githubusercontent.com/snakers4/silero-vad/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/data/silero_vad.jit
- Source size: 2,272,526 bytes
- Source SHA-256: `e1122837f4154c511485fe0b9c64455f7b929c96fbb8d79fbdb336383ebd3720`
- Copyright: 2020-present Silero Team
- License: MIT; the unmodified notice is bundled as `SileroVAD-LICENSE.txt`.
- License SHA-256: `2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b`

## Conversion

`Scripts/convert_silero_vad.py` verifies the source hash before loading it. It
copies the original 16 kHz model's unmodified state dictionary into the same
fixed STFT convolution, encoder convolutions, and explicit LSTM equations.
Only the inference graph is made static for conversion; no retraining or
quantization is performed. The original 8 kHz branch is not bundled.

Reproduction environment: Python 3.11, PyTorch 2.5.1, coremltools 8.3.0, macOS.
The generated model uses ML Program, Float32 weights/inputs/outputs, and an
iOS 17 minimum model deployment target. Xcode compiles the checked-in
`SileroVAD.mlpackage` into `SileroVAD.mlmodelc` at build time. The app performs
no model compilation, Python execution, or dependency installation at runtime.

Example after downloading the pinned source and verifying its provenance:

```sh
python Scripts/convert_silero_vad.py --source /path/to/silero_vad.jit \
  --output /tmp/SileroVAD.mlpackage --fixtures /path/to/generated-fixtures \
  --validation-output /tmp/silero-validation.json
```

The checked-in weight file is 1,239,488 bytes and has SHA-256
`92335f8848b937c4cbbd7d741ae0ae30cb833c0ccb91657544727589aca348e2`.
The full source package is 1,256,378 bytes. Its model protobuf SHA-256 is
`449768fe3ae567ff7fcbbc0064e23cf567375f802362c32ed59057d98efe987f`;
its manifest SHA-256 is
`720f4d40c1ddc242203fdb7c0b249351545aeb3064087d252a692fe360055dd5`.
Package manifests contain generated identifiers; the conversion is numerically
reproducible and the weight bytes match, without requiring identical manifest
identifiers or intermediate operation names.

## Runtime contract

- Audio input: Float32 `[1, 576]`, containing 64 preceding samples followed by
  512 new samples at 16 kHz. PCM16 normalization is `sample / 32768`.
- Recurrent input: Float32 `[2, 1, 128]`, initialized to zero for each capture.
- Outputs: `probability` Float32 `[1, 1]` and `next_state` Float32 `[2, 1, 128]`.
- The next call carries the previous 64 audio samples and output state.
- Each scored frame covers 32 ms of actual input. The final incomplete frame
  is not padded into invented speech or silence.
- The selected speech probability threshold is 0.6. The separate endpoint
  policy requires sustained speech and classified trailing silence, and owns
  the initial-silence and maximum-duration limits.

## Conversion validation

On 2026-10-03, 32 randomized audio/state cases matched the original TorchScript
16 kHz graph at `rtol=1e-5`, `atol=1e-6`. Native CPU-only Core ML predictions
were also compared against the official stateful TorchScript forward method
on 2,348 consecutive frames across 11 generated fixtures. The maximum absolute
speech-probability difference was 0.000047147274; the maximum recurrent-state
difference was 0.000915527344. Every decision at threshold 0.6 matched.

The generated fixtures contain English and Thai sentences, short replies in
both languages, deterministic 12 dB signal-to-noise variants, and separate
silence, low-frequency noise, and harmonic-tone controls. The actual compiled
Swift `SpeechEndpointPolicy` was replayed against these scored frames at 100 ms
evaluation intervals: all eight speech fixtures finished after trailing
silence, and all three controls cancelled at eight seconds without detecting
speech. The existing endpoint policy and its thresholds were not weakened.

These offline fixtures validate conversion and basic endpoint behavior. They
do not establish accuracy in all cars, microphone routes, or background audio
conditions. CPU inference timing measured on the development Mac is not an
iPhone battery or latency measurement. A passenger or radio voice can count as
speech because this model does not identify the intended speaker.
