#!/usr/bin/env python3
"""Rebuild OLIV's bundled, CPU-only Silero VAD model. Never used by the app.

Python 3.11, torch==2.5.1, coremltools==8.3.0. Supply the official .jit file
from the pinned URL below. Its SHA-256 is checked before deserialization.
Optional --fixtures validates the 11 generated offline fixtures on native
Core ML against the original streaming TorchScript model, including state.
"""

import argparse
import hashlib
import json
from pathlib import Path
import time
import wave

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as functional


REVISION = "5cd7945676eb32225748052e2e6a0580e4686a08"
SOURCE_URL = (
    "https://raw.githubusercontent.com/snakers4/silero-vad/"
    + REVISION + "/src/silero_vad/data/silero_vad.jit"
)
SOURCE_SHA256 = "e1122837f4154c511485fe0b9c64455f7b929c96fbb8d79fbdb336383ebd3720"
FIXTURE_NAMES = [
    "english-padded", "thai-padded", "english-short-padded", "thai-short-padded",
    "english-noise12", "thai-noise12", "english-short-noise12", "thai-short-noise12",
    "silence-control", "noise-control", "tone-control",
]


class FixedFrameModel(torch.nn.Module):
    """The original 16 kHz graph with fixed shapes and explicit LSTM gates.

    All tensors come from the unmodified official state_dict. This makes the
    TorchScript integer attributes/static branches unambiguous to Core ML's
    converter; it does not retrain, quantize, or replace the learned model.
    """

    def __init__(self, original):
        super().__init__()
        for name, tensor in original._model.state_dict().items():
            self.register_buffer(name.replace(".", "_"), tensor.detach().clone())

    def forward(self, audio, state):
        x = functional.conv1d(
            functional.pad(audio, (0, 64), mode="reflect").unsqueeze(1),
            self.stft_forward_basis_buffer, stride=128,
        )
        x = torch.sqrt(x[:, :129, :].square() + x[:, 129:, :].square())
        for index, stride in enumerate([1, 2, 2, 1]):
            x = functional.relu(functional.conv1d(
                x, getattr(self, f"encoder_{index}_reparam_conv_weight"),
                getattr(self, f"encoder_{index}_reparam_conv_bias"),
                stride=stride, padding=1,
            ))
        gates = (
            functional.linear(x.squeeze(-1), self.decoder_rnn_weight_ih,
                              self.decoder_rnn_bias_ih)
            + functional.linear(state[0], self.decoder_rnn_weight_hh,
                                self.decoder_rnn_bias_hh)
        )
        input_gate, forget_gate, candidate, output_gate = gates.chunk(4, dim=1)
        cell = (torch.sigmoid(forget_gate) * state[1]
                + torch.sigmoid(input_gate) * torch.tanh(candidate))
        hidden = torch.sigmoid(output_gate) * torch.tanh(cell)
        out = torch.sigmoid(functional.conv1d(
            functional.relu(hidden).unsqueeze(-1),
            self.decoder_decoder_2_weight, self.decoder_decoder_2_bias,
        )).squeeze(1).mean(dim=1).unsqueeze(1)
        return out, torch.stack([hidden, cell])


def validate_fixtures(model, original, directory):
    reports = []
    for name in FIXTURE_NAMES:
        with wave.open(str(directory / (name + ".wav")), "rb") as audio:
            assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2)
            pcm = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768
        original.reset_states()
        context = np.zeros((1, 64), np.float32)
        state = np.zeros((2, 1, 128), np.float32)
        errors, state_errors, timings, scores = [], [], [], []
        # Ignore the final incomplete frame: do not invent silent audio.
        for position in range(0, len(pcm) - 511, 512):
            new_audio = pcm[position:position + 512].reshape(1, 512)
            with torch.inference_mode():
                reference = original(torch.from_numpy(new_audio), 16000).item()
            start = time.perf_counter()
            result = model.predict({
                "audio": np.concatenate([context, new_audio], axis=1),
                "recurrent_state": state,
            })
            timings.append(time.perf_counter() - start)
            probability = float(result["probability"][0, 0])
            state = result["next_state"]
            context = new_audio[:, -64:].copy()
            errors.append(abs(probability - reference))
            state_errors.append(float(np.max(np.abs(state - original._state.numpy()))))
            assert np.isfinite(probability) and 0 <= probability <= 1
            assert (probability >= 0.6) == (reference >= 0.6)
            scores.append({"start": position / 16000, "end": (position + 512) / 16000,
                           "confidence": probability, "reference": reference})
        # Float32 recurrence accumulates small differences. Probability parity
        # is checked more tightly than the recurrent cell's unbounded values.
        assert max(errors) < 0.00005, (name, max(errors))
        assert max(state_errors) < 0.005, (name, max(state_errors))
        assert any(score["confidence"] >= 0.6 for score in scores) == (not name.endswith("control"))
        report = {
            "fixture": name, "duration": len(pcm) / 16000,
            "maxProbabilityError": max(errors), "maxStateError": max(state_errors),
            "meanPredictionMilliseconds": float(np.mean(timings) * 1000),
            "p95PredictionMilliseconds": float(np.quantile(timings, .95) * 1000),
            "scores": scores,
        }
        reports.append(report)
        print(json.dumps({key: value for key, value in report.items() if key != "scores"}))
    return reports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help=SOURCE_URL)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--validation-output", type=Path)
    args = parser.parse_args()
    if hashlib.sha256(args.source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise ValueError("The source does not match the pinned official model SHA-256.")
    torch.set_num_threads(1)
    original = torch.jit.load(str(args.source), map_location="cpu").eval()
    model = FixedFrameModel(original).eval()
    for seed in range(32):
        torch.manual_seed(seed)
        audio, state = torch.randn(1, 576) * .1, torch.randn(2, 1, 128) * .2
        with torch.inference_mode():
            torch.testing.assert_close(model(audio, state), original._model(audio, state),
                                       rtol=1e-5, atol=1e-6)
    traced = torch.jit.trace(model, (torch.zeros(1, 576), torch.zeros(2, 1, 128)))
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, 576), dtype=np.float32),
                ct.TensorType(name="recurrent_state", shape=(2, 1, 128), dtype=np.float32)],
        outputs=[ct.TensorType(name="probability", dtype=np.float32),
                 ct.TensorType(name="next_state", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    converted.author = "Silero Team; Core ML conversion for OLIV"
    converted.license = "MIT; see bundled SileroVAD-LICENSE.txt"
    converted.short_description = "Silero VAD v6.2.3, fixed 16 kHz streaming frame; explicitly CPU-only."
    converted.user_defined_metadata["silero_revision"] = REVISION
    converted.user_defined_metadata["source_sha256"] = SOURCE_SHA256
    converted.save(str(args.output))
    if args.fixtures:
        reports = validate_fixtures(converted, original, args.fixtures)
        if args.validation_output:
            args.validation_output.write_text(json.dumps(reports, indent=2) + "\n")
    print("Saved model; runtime must also set MLModelConfiguration.computeUnits = .cpuOnly.")


if __name__ == "__main__":
    main()
