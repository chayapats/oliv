"""Token targets that match the decode path OLIV actually takes.

THE TRAP THIS FILE EXISTS TO AVOID
----------------------------------
Every standard Whisper finetuning recipe trains on <|notimestamps|> + plain text. OLIV does
not decode that way. mlx_whisper's DecodingOptions defaults `without_timestamps=False`
(decoding.py:112) and app/stt/mlx_whisper.py never overrides it, so production ASKS THE MODEL
FOR TIMESTAMPS. Training on <|notimestamps|> would fine-tune a path the app never takes while
degrading the one it does — the classic "trained great, garbage in the app" outcome.

Confirmed empirically against the shipped weights, not inferred: the stock model's first
emitted token on a real clip is 50365 = <|0.00|>, and the decoder prompt is
(50258, 50289, 50360) = <|startoftranscript|><|th|><|transcribe|> — no <|notimestamps|>.

    <|sot|> <|th|> <|transcribe|> <|0.00|>  ...text...  <|dur|> <|eot|>

LANGUAGE IS <|th|> FOR EVERY CLIP, including the pure-English ones. Also measured, not
assumed: typhoon auto-detects `th` on every sampled clip — an English-only sentence included
(which is exactly why OLIV carries a forced-en re-decode). Production decodes with
language=None, so <|th|> is the path that actually runs. Train the path that runs.

The strongest available check that this layout is right is not a unit test but a number: the
STOCK model's loss on its own production format is ~0.85. A wrong layout does not crash — it
shows up as a loss around 10. test_finetune.py asserts < 2.0.
"""
import mlx.core as mx
import mlx.nn as nn
from mlx_whisper import audio as A

N_FRAMES = 3000          # 30s at hop 160 / 16kHz. Whisper pads EVERY clip to this, so cost
                         # is driven by clip COUNT, not audio minutes.
N_MELS = 128             # large-v3-turbo: 128 mels, not the 80 of small/medium.
TS_RESOLUTION = 0.02     # seconds per timestamp token
MAX_CTX = 448            # n_text_ctx


def build_target(tok, text: str, dur: float) -> list[int]:
    end = tok.timestamp_begin + int(round(min(dur, 30.0) / TS_RESOLUTION))
    seq = (list(tok.sot_sequence)          # sot, th, transcribe — NOT sot_sequence_including_notimestamps
           + [tok.timestamp_begin]         # <|0.00|>
           + tok.encoding.encode(text)
           + [end, tok.eot])
    # Teacher forcing feeds s[:-1] as the decoder input, so the n_text_ctx=448 limit is on
    # len(seq)-1, not len(seq). A 449-token target yields 448 decoder positions and fits.
    if len(seq) - 1 > MAX_CTX:
        raise ValueError(f"target exceeds n_text_ctx={MAX_CTX}: "
                         f"{len(seq)-1} decoder positions for {text!r}")
    return seq


def make_batch_from_targets(seqs):
    """Teacher forcing. inp predicts tgt; mask says which positions carry a learning signal."""
    L = max(len(s) for s in seqs)
    pad = seqs[0][-1]                      # eot; padded positions are masked out anyway
    inp = mx.array([s[:-1] + [pad] * (L - len(s)) for s in seqs])
    tgt = mx.array([s[1:] + [pad] * (L - len(s)) for s in seqs])
    # inp[0]=<|sot|> predicts <|th|>; inp[1]=<|th|> predicts <|transcribe|>. Both are fixed
    # constants of the prompt — supervising them teaches nothing. The signal starts where
    # inp[2]=<|transcribe|> predicts <|0.00|>, and runs through the text to <|eot|>.
    mask = mx.array([[0.0] * 2 + [1.0] * (len(s) - 3) + [0.0] * (L - len(s)) for s in seqs])
    return inp, tgt, mask


def make_batch(tok, rows):
    """rows are {"audio": path, "text": label} — the schema export.py writes."""
    mels, seqs = [], []
    for r in rows:
        a = A.load_audio(r["audio"])
        mels.append(A.log_mel_spectrogram(a, n_mels=N_MELS, padding=A.N_SAMPLES)[:N_FRAMES])
        seqs.append(build_target(tok, r["text"], len(a) / A.SAMPLE_RATE))
    inp, tgt, mask = make_batch_from_targets(seqs)
    return mx.stack(mels), inp, tgt, mask


def loss_fn(model, mel, inp, tgt, mask):
    logits = model(mel, inp).astype(mx.float32)
    ce = nn.losses.cross_entropy(logits, tgt)          # (B, T)
    return (ce * mask).sum() / mask.sum()
