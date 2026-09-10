"""MLX-native LoRA finetune of typhoon-whisper-turbo, in place on the shipped weights.

There is no HuggingFace round-trip and no format conversion: what this saves is byte-for-byte
what app/stt/mlx_whisper.py loads. That is the whole reason it is written by hand.

The alternative (HF Seq2SeqTrainer + PEFT -> mlx-examples/whisper/convert.py) was rejected on
evidence, not taste: PyTorch/MPS cannot train Whisper on this Mac (unresolved NNPack error on
the encoder convs), so it means renting a GPU; convert.py is not on PyPI, assumes a single
unsharded model.safetensors, pops proj_out assuming tied embeddings, and drops alignment_heads;
PEFT's merge_and_unload() has a history of quiet bugs; and MLX and HF do not produce identical
output from the same weights. Every one of those is a trust boundary, and this project's entire
bug history is trust boundaries where something plausible was silently wrong.

Run from benchmark/.venv. (mlx_whisper imports there; mlx_lm is broken there and is not needed.)
EVAL, however, must run from sidecar/.venv — the Gemma cleanup imports mlx_lm. See the plan.
"""
import argparse
import json
import math
import random
import shutil
import sys
import time
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
from mlx.utils import tree_flatten, tree_map, tree_unflatten
from mlx_whisper.load_models import load_model
from mlx_whisper.tokenizer import get_tokenizer

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lora
import targets

FT = Path(__file__).resolve().parent
DS = FT / "dataset"
SEED = 42


def tokenizer():
    return get_tokenizer(multilingual=True, num_languages=100, language="th", task="transcribe")


def load_rows(p) -> list[dict]:
    return [json.loads(l) for l in Path(p).read_text().splitlines() if l.strip()]


def _lr_at(step: int, total: int, peak: float, warmup: int) -> float:
    if step < warmup:
        return peak * (step + 1) / max(1, warmup)
    prog = (step - warmup) / max(1, total - warmup)
    return peak * 0.5 * (1.0 + math.cos(math.pi * min(1.0, prog)))      # cosine decay


def evaluate(model, tok, rows, batch: int) -> float:
    """Mean val loss, token-weighted. export.py holds val out BY SENTENCE, so this is not a
    memorisation score.

    model.eval() is REQUIRED: LoRA dropout is active by default (MLX modules start
    training=True), so without it the val loss is stochastic and best_w gets selected on a
    dropout-perturbed number that deterministic inference would never see. Restore train()
    in a finally so a raising batch cannot leave the model frozen mid-run."""
    if not rows:
        return float("nan")
    model.eval()
    try:
        total = toks = 0.0
        for i in range(0, len(rows), batch):
            mel, inp, tgt, mask = targets.make_batch(tok, rows[i:i + batch])
            n = float(mask.sum())
            loss = targets.loss_fn(model, mel, inp, tgt, mask)
            mx.eval(loss)
            total += float(loss) * n
            toks += n
    finally:
        model.train()
    return total / toks


def _windows(rows, batch: int, accum: int, rng, shuffle: bool):
    """One epoch's accumulation windows. Each window is up to `accum` micro-batches of up to
    `batch` rows. FINITE and exactly one pass over `rows` — no wrap. An endless stream would
    pull the next epoch's shuffle to fill the last window, duplicating rows before validation
    and overtraining silently (a second-eye finding: 30 rows / eff 8 gave 32 presentations)."""
    order = rng.sample(rows, len(rows)) if shuffle else rows[:]
    micro = [order[i:i + batch] for i in range(0, len(order), batch)]
    return [micro[i:i + accum] for i in range(0, len(micro), accum)]


def weighted_mean(values, weights):
    """Token-weighted mean. Used for the epoch train loss so it matches evaluate()'s
    token-weighted val loss (an equal average of window means, whose windows have different
    token totals, is not the per-token loss and would make Gate 3's train-vs-val comparison
    apples-to-oranges)."""
    return sum(v * w for v, w in zip(values, weights)) / sum(weights)


def combine_token_weighted(pairs):
    """Token-weighted gradient accumulation. `pairs` is [(grads_tree, loss_float, n_tokens)].
    Returns (combined_grads, mean_per_token_loss). Weighting each micro-batch by its supervised
    token count and dividing by the total makes N accumulated micro-batches EXACTLY equal one
    combined batch of the same tokens — loss_fn returns a per-token mean, whose gradient scales
    by n, so equal-weighting would overweight short micro-batches. Shared with the test, which
    checks it against a real combined-batch gradient (not a re-derivation of this formula)."""
    acc_grads, acc_loss, acc_tok = None, 0.0, 0.0
    for grads, loss, n in pairs:
        acc_loss += loss * n
        acc_tok += n
        scaled = tree_map(lambda g: g * n, grads)
        acc_grads = scaled if acc_grads is None else tree_map(lambda a, b: a + b, acc_grads, scaled)
    return tree_map(lambda g: g / acc_tok, acc_grads), acc_loss / acc_tok


def fit(rows, val, *, base, epochs: int = 3, steps: int | None = None, lr: float = 1e-4,
        batch: int = 2, accum: int = 4, rank: int = 16, alpha: float = 32.0,
        dropout: float = 0.05, quiet: bool = False):
    """Returns (step_losses, model). `steps` overrides `epochs` — used by the smoke test.

    BATCH SIZE IS MEMORY-BOUND, NOT COMPUTE-BOUND — measured on the M4 Pro / 48GB:

        batch  s/step  s/sample  peak
            1    1.38      1.38  16.2 GB
            2    2.73      1.37  27.4 GB     <- ceiling
            4   37.04      9.26  49.6 GB     <- exceeds RAM, swaps, 6.7x per-sample

    Whisper's encoder attends over 1500 audio positions, so the retained attention activations
    scale hard with batch. Above 2 the machine swaps and throughput collapses. Do NOT raise
    `batch` to get a bigger effective batch — raise `accum`, which costs no memory at all.
    """
    # Fail loud on an empty set — export.py ships an empty train.jsonl when only one unique
    # sentence exists (it goes to val), and _cycle_batches would then spin forever at next().
    if not rows:
        raise ValueError("fit() got an empty training set. export.py produces an empty "
                         "train.jsonl when only one unique sentence ships — record more first.")
    if batch < 1 or accum < 1:
        raise ValueError(f"batch and accum must be >= 1 (got batch={batch}, accum={accum})")

    tok = tokenizer()
    model = load_model(str(base), dtype=mx.float16)
    wrapped = lora.apply_lora(model, r=rank, alpha=alpha, dropout=dropout)
    lora.mark_trainable(model)
    if not quiet:
        print(f"LoRA: {wrapped} projections | "
              f"{lora.trainable_params(model)/1e6:.2f}M trainable / "
              f"{lora.total_params(model)/1e6:.0f}M "
              f"({100*lora.trainable_params(model)/lora.total_params(model):.2f}%)")

    per_epoch = max(1, math.ceil(math.ceil(len(rows) / batch) / accum))   # optimiser updates/epoch
    total_updates = steps if steps else epochs * per_epoch
    warmup = max(1, int(0.1 * total_updates))
    opt = optim.AdamW(learning_rate=lr)
    step_fn = nn.value_and_grad(model, targets.loss_fn)
    rng = random.Random(SEED)
    if not quiet:
        print(f"batch {batch} x accum {accum} = effective {batch*accum} | "
              f"{per_epoch} updates/epoch, {total_updates} total")

    losses: list[float] = []
    best_val, best_w = float("inf"), None
    t0 = time.time()

    window_tokens: list[float] = []

    def do_update(window, step):
        """One optimiser step over an accumulation window; only `batch` rows resident at once.
        Records the window's supervised-token count so the epoch train loss can be token-weighted
        to match the token-weighted val loss (Gate 3 compares the two)."""
        opt.learning_rate = _lr_at(step, total_updates, lr, warmup)
        pairs = []
        for chunk in window:
            mel, inp, tgt, mask = targets.make_batch(tok, chunk)
            loss, grads = step_fn(model, mel, inp, tgt, mask)
            mx.eval(loss, grads)            # force compute + free this micro-batch's activations
            pairs.append((grads, float(loss), float(mask.sum())))
        grads, mean_loss = combine_token_weighted(pairs)
        opt.update(model, grads)
        mx.eval(model.parameters(), opt.state)
        window_tokens.append(sum(n for _, _, n in pairs))
        return mean_loss

    if steps is not None:
        # Step-limited mode (the overfit smoke test): `steps` updates on the first window,
        # accum honoured. Deterministic, no shuffle, no validation.
        window = _windows(rows, batch, accum, rng, shuffle=False)[0]
        for step in range(steps):
            losses.append(do_update(window, step))
        return losses, model

    # Epoch training: each epoch is exactly ONE shuffled pass; validation at the true boundary.
    step = 0
    for ep in range(epochs):
        for window in _windows(rows, batch, accum, rng, shuffle=True):
            losses.append(do_update(window, step))
            step += 1
            if not quiet and step % 10 == 0:
                print(f"  update {step}/{total_updates}  loss {losses[-1]:.4f}  {time.time()-t0:.0f}s")
        vl = evaluate(model, tok, val, batch)
        recent = weighted_mean(losses[-per_epoch:], window_tokens[-per_epoch:])
        print(f"epoch {ep+1}/{epochs}: train {recent:.4f}  val {vl:.4f}")
        # Turbo is reported to DEGRADE with extended training. Keep the best-val adapters, not
        # the last ones — otherwise a late epoch silently overwrites a better model.
        if vl < best_val:
            best_val = vl
            best_w = {k: mx.array(v) for k, v in tree_flatten(model.trainable_parameters())}
            print("  ^ best so far")

    if best_w is not None:
        model.update(tree_unflatten(list(best_w.items())))
        print(f"restored best-val adapters (val {best_val:.4f})")
    return losses, model


def save_mlx_model(model, src_dir, out_dir) -> None:
    """Write exactly what mlx_whisper.load_model() reads: config.json + weights.safetensors.

    LoRA is merged first, so the artifact is a plain Whisper with no adapter at load time —
    which is what makes it a drop-in for OLIV_TYPHOON_MLX_REPO.

    Staged into a unique tmp dir and swapped in only once BOTH files are on disk. Guarantee: a
    crash never DESTROYS data. A POSIX directory swap is two renames (out->bak, tmp->out), so a
    crash between them can leave `out` momentarily absent — but `.bak` still holds the previous
    known-good model, and the next call RECOVERS it (below). So the worst a crash does is leave
    the model under `<out>.bak` until the next save; it is never lost. (The model is also
    regenerable in ~35 min, so this is belt-and-braces.)
    """
    import tempfile
    merged = lora.merge_lora(model)
    out = Path(out_dir)
    out.parent.mkdir(parents=True, exist_ok=True)
    bak0 = out.with_name(out.name + ".bak")
    if not out.exists() and bak0.exists():       # recover from a crash during a prior swap
        bak0.rename(out)
    # Stage into a UNIQUE tmp dir (concurrent runs to the same out must not share it), fully
    # write both files, THEN swap. The old model is moved aside to .bak first and only removed
    # once the new one is in place — a crash or failed rename never leaves NO model directory.
    tmp = Path(tempfile.mkdtemp(prefix=out.name + ".", dir=out.parent))
    try:
        shutil.copy(Path(src_dir) / "config.json", tmp / "config.json")     # dims are unchanged
        mx.save_safetensors(str(tmp / "weights.safetensors"),
                            dict(tree_flatten(model.parameters())))
        bak = out.with_name(out.name + ".bak")
        if out.exists():
            if bak.exists():
                shutil.rmtree(bak)
            out.rename(bak)                 # known-good safely aside
        try:
            tmp.rename(out)                 # publish
        except OSError:
            if bak.exists():
                bak.rename(out)             # restore the known-good model on failure
            raise
        if bak.exists():
            shutil.rmtree(bak)
    finally:
        if tmp.exists():
            shutil.rmtree(tmp)
    print(f"merged {merged} LoRA layers -> {out}")


def main() -> None:
    ap = argparse.ArgumentParser(description="MLX-native LoRA finetune of typhoon-whisper-turbo")
    ap.add_argument("--base", required=True, help="MLX model dir (the shipped snapshot)")
    ap.add_argument("--out", default=str(DS / "model_ft"))
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--batch", type=int, default=2,
                    help="MEASURED CEILING on 48GB: 2. batch 4 peaks at 49.6GB and swaps.")
    ap.add_argument("--accum", type=int, default=4,
                    help="gradient accumulation; effective batch = batch*accum, no memory cost")
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--alpha", type=float, default=32.0)
    ap.add_argument("--dropout", type=float, default=0.05)
    a = ap.parse_args()

    train_rows, val_rows = load_rows(DS / "train.jsonl"), load_rows(DS / "val.jsonl")
    print(f"train {len(train_rows)} / val {len(val_rows)}")
    if len(train_rows) < 100:
        print("WARNING: the pilot is specified at ~500 clips. Fewer will not tell you much.")

    _, model = fit(train_rows, val_rows, base=a.base, epochs=a.epochs, lr=a.lr,
                   batch=a.batch, accum=a.accum, rank=a.rank, alpha=a.alpha,
                   dropout=a.dropout)
    save_mlx_model(model, a.base, a.out)
    print("\nNext: score it. NOTE — eval runs from sidecar/.venv, not benchmark/.venv:")
    print(f"  export OLIV_TYPHOON_MLX_REPO={Path(a.out).resolve()}")
    print("  sidecar/.venv/bin/python benchmark/eval_cleanup.py --manifest data/manifest_ft_probe.jsonl \\")
    print("      --engine typhoon-turbo-mlx --no-cleanup --out benchmark/eval_results/ft_tuned_pure_probe.json")


if __name__ == "__main__":
    main()
