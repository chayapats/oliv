"""OLIV: local push-to-talk dictation for Apple Silicon (Thai+English).

This package is the Wave-1 prototype skeleton (W1-T1): app plumbing, config,
and a pluggable STT backend interface. Hotkey capture, audio capture, paste,
and cleanup are separate tasks (W1-T2..T5) and are NOT implemented here.

Import discipline: importing `app` (and any of its submodules other than a
backend you explicitly select) must be fast and must NOT import mlx,
transformers, torch, or load any model weights. Heavy dependencies are
imported lazily inside backend methods -- see app/stt/mlx_whisper.py.
"""

from __future__ import annotations

__all__ = ["__version__"]

__version__ = "0.1.0-w1t1"
