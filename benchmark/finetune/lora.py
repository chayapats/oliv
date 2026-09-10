"""LoRA for mlx-whisper. Hand-rolled, on purpose.

mlx_lm ships LoRA, but it is text-LLM-only (it does not know encoder-decoder speech models),
and `import mlx_lm` is BROKEN in benchmark/.venv anyway: mlx_lm 0.31.3 calls
AutoTokenizer.register() with a string where transformers 5.13 requires a class, giving
`AttributeError: 'str' object has no attribute '__module__'`. It is ~40 lines. Owning them is
cheaper than owning that dependency.

Two invariants, both tested, both load-bearing:

  * B is zero-init, so a freshly wrapped model is NUMERICALLY IDENTICAL to the base. If that
    is not true, every "improvement" is partly just the adapter perturbing the model, and the
    baseline you compare against is not the model you think it is.
  * merge_lora() must not change behaviour. A merge that quietly differs from the trained model
    is the most expensive bug available here: you would ship a model you never evaluated.
"""
import math

import mlx.core as mx
import mlx.nn as nn
from mlx.utils import tree_flatten


class LoRALinear(nn.Module):
    """y = base(x) + (alpha/r) * dropout(x) @ A^T @ B^T"""

    @staticmethod
    def from_base(base: nn.Linear, r: int = 16, alpha: float = 32.0, dropout: float = 0.05):
        out_dim, in_dim = base.weight.shape
        layer = LoRALinear(in_dim, out_dim, r, alpha, dropout)
        layer.base = base
        return layer

    def __init__(self, in_dim: int, out_dim: int, r: int, alpha: float, dropout: float):
        super().__init__()
        self.r = r
        self.scale = alpha / r
        self.dropout = nn.Dropout(dropout) if dropout > 0 else None
        s = 1.0 / math.sqrt(in_dim)
        self.lora_a = mx.random.uniform(low=-s, high=s, shape=(r, in_dim))
        self.lora_b = mx.zeros((out_dim, r))          # zero -> identity at step 0

    def __call__(self, x):
        y = self.base(x)
        z = self.dropout(x) if self.dropout is not None else x
        z = (z @ self.lora_a.T) @ self.lora_b.T
        return y + (self.scale * z).astype(y.dtype)


def merge_one(w: LoRALinear) -> nn.Linear:
    """Fold the adapter into the base weight; return a plain nn.Linear."""
    delta = (w.lora_b @ w.lora_a) * w.scale
    base = w.base
    base.weight = (base.weight + delta.astype(base.weight.dtype)).astype(base.weight.dtype)
    return base


def _attn_modules(model):
    """Every attention block in the model: 32 encoder (self) + 4 decoder (self + cross)."""
    for blk in list(model.encoder.blocks) + list(model.decoder.blocks):
        yield blk.attn
        if getattr(blk, "cross_attn", None) is not None:
            yield blk.cross_attn


def apply_lora(model, r: int = 16, alpha: float = 32.0, dropout: float = 0.05,
               targets: tuple[str, ...] = ("query", "value")) -> int:
    """Wrap attention projections in place. Returns the number wrapped.

    query/value follows the reference PEFT-Whisper recipe. Encoder AND decoder: decoder LoRA
    buys terminology, encoder LoRA buys the speaker's voice. Both are the point.
    NOTE the MLX/OpenAI naming — query/key/value/out, not HF's q_proj/v_proj.
    """
    n = 0
    for attn in _attn_modules(model):
        for name in targets:
            base = getattr(attn, name, None)
            if isinstance(base, nn.Linear):
                setattr(attn, name, LoRALinear.from_base(base, r, alpha, dropout))
                n += 1
    return n


def merge_lora(model) -> int:
    """Fold every adapter back into its base weight. Returns the number merged."""
    n = 0
    for attn in _attn_modules(model):
        for name in ("query", "key", "value", "out"):
            w = getattr(attn, name, None)
            if isinstance(w, LoRALinear):
                setattr(attn, name, merge_one(w))
                n += 1
    return n


def mark_trainable(model) -> None:
    """Freeze everything, then unfreeze only the adapters."""
    model.freeze()
    for _, m in model.named_modules():
        if isinstance(m, LoRALinear):
            m.unfreeze(keys=["lora_a", "lora_b"])


def trainable_params(model) -> int:
    return sum(v.size for _, v in tree_flatten(model.trainable_parameters()))


def total_params(model) -> int:
    return sum(v.size for _, v in tree_flatten(model.parameters()))
