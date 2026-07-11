"""OLIV configuration.

OLIVConfig holds every user-tunable knob for the Wave-1 prototype
pipeline. Defaults match the original Wave-1 design decisions. Loaded from `oliv.toml` at the project root via
stdlib `tomllib` (Python 3.11+); a missing file, or missing/unknown keys
within an existing file, silently fall back to these defaults -- there is
no required config for the app to run.

Import discipline: this module only touches stdlib (dataclasses, pathlib,
tomllib) -- no mlx/transformers/torch -- so `import app.config` stays fast,
matching the rest of the package.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import Any

logger = logging.getLogger("oliv.config")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG_PATH = PROJECT_ROOT / "oliv.toml"

# W1-T5: valid paste_mode values (see OLIVConfig.paste_mode). An unknown
# value in oliv.toml is normalized back to the default with a warning,
# matching this module's "never make config a hard error" philosophy.
PASTE_MODES = ("clipboard_restore", "clipboard_only")

# W2-T3: valid cleanup_apps mode values (see OLIVConfig.cleanup_apps).
# Unlike PASTE_MODES (whole-field fallback), an unknown mode here only drops
# that ONE bundle-id entry -- see __post_init__.
CLEANUP_APP_MODES = ("on", "off")


@dataclass
class OLIVConfig:
    # W1-T2: hotkey to hold-to-talk for capture. "right_option" per plan.
    hotkey: str = "right_option"

    # STT backend registry id -- see app/stt/__init__.py BACKENDS.
    # NOTE: "typhoon-turbo-mlx" (Typhoon Whisper Turbo, MIT) is the PRIMARY
    # backend and the shipped default as of the 2026-07 model switch: half
    # Pathumma's size and better on unseen jargon/English (holdout 90 vs 72),
    # ~1.1s/utterance. "pathumma-mlx" (the prior default) stays registered as a
    # legacy option; "mlx-large-v3" (vanilla Whisper large-v3 via MLX) is the
    # English-heavy fallback; "pathumma" (HF transformers) stays for A/B.
    stt_backend: str = "typhoon-turbo-mlx"

    # auto = never force a language token (default; correct for Thai+English
    # code-switching decode). "th" / "en" force that language's token.
    decode_policy: str = "auto"  # auto | th | en

    # W1-T5: how paste-at-cursor (app/inject.py) behaves. One of PASTE_MODES:
    #   "clipboard_restore" (default) -- save the clipboard, put the text on
    #       it, synthesize Cmd+V to paste at the focused app's cursor, then
    #       restore the original clipboard. Needs macOS Accessibility to post
    #       the keystroke; without it the text is left on the clipboard for a
    #       manual Cmd+V (and NOT restored, so it stays available).
    #   "clipboard_only" -- the degraded, consent-free mode: just put the text
    #       on the clipboard and stop (no synthesized keys, no restore). The
    #       user pastes manually.
    paste_mode: str = "clipboard_restore"

    # Whether the cleanup stage (benchmark/pipeline.py's Gemma-4 pass) runs
    # after STT.
    cleanup_enabled: bool = True

    # Cleanup's deps (mlx-lm 0.31.3 + transformers==5.0.0) conflict with the
    # STT stack's (transformers 5.13 in .venv-app), so cleanup CANNOT run
    # in-process. Resolved in W1-T6: cleanup runs as a subprocess "worker"
    # (benchmark/cleanup_worker.py under benchmark/.venv-gemma4), driven by
    # app/cleanup.py's CleanupClient over a JSON stdio protocol. This is the
    # only supported value; kept as a knob for documentation/future modes.
    cleanup_mode: str = "worker"

    # Per-backend model repo overrides, keyed by stt_backend registry id
    # (e.g. {"mlx-large-v3": "mlx-community/whisper-large-v3-mlx"}). Empty
    # (default) means "use each backend's own built-in default repo".
    model_repo: dict[str, str] = field(default_factory=dict)

    # W1-T3: whether app/audio.py's trim_silence() runs on captured audio
    # before handing it to STT. Off by default -- leading/trailing silence
    # trimming is a nicety, not required, and off-by-default avoids ever
    # clipping real speech via a miscalibrated threshold.
    trim_silence: bool = False

    # W2-T3: per-app cleanup override, keyed by bundle id (e.g.
    # "com.apple.Notes", found via `osascript -e 'id of app "Notes"'`) ->
    # mode string:
    #   "on"  -- run cleanup for this app (explicit; same as no entry)
    #   "off" -- verbatim/bypass: raw STT text passes through untouched,
    #            and the cleanup worker isn't even called for this app
    # Precedence: cleanup_enabled=false means cleanup is OFF EVERYWHERE (the
    # CleanupClient is never even built -- see DictationApp.build()); this
    # table only REFINES a globally-ON config, it can never turn cleanup on
    # when the global switch is off. Empty dict (default) means no per-app
    # overrides -- every app gets the global (on) behavior. An unknown mode
    # value for a given bundle id (including a non-string value, e.g. a TOML
    # boolean from a `"com.apple.Notes" = true` typo) is warned about and
    # just that one entry is dropped (see __post_init__) -- one bad line in
    # oliv.toml shouldn't take the whole table down, matching this
    # module's "never make config a hard error" philosophy. Bundle-id KEYS
    # are matched case-insensitively (macOS itself treats bundle ids
    # case-insensitively), so table keys are lowercased here too -- see
    # __post_init__.
    cleanup_apps: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        # Normalize/validate paste_mode: an unknown value falls back to the
        # default with a warning rather than raising, consistent with how a
        # missing oliv.toml or unknown key falls back to defaults.
        mode = (self.paste_mode or "").strip().lower()
        if mode not in PASTE_MODES:
            logger.warning(
                "unknown paste_mode %r -- falling back to %r (valid: %s)",
                self.paste_mode,
                "clipboard_restore",
                ", ".join(PASTE_MODES),
            )
            mode = "clipboard_restore"
        self.paste_mode = mode

        # Normalize cleanup_apps: an unknown mode value for a bundle id is
        # dropped with a warning rather than raising, or falling back the
        # whole table, one bad entry shouldn't disable every other app's
        # override. A oliv.toml typo like `cleanup_apps = "off"` (a bare
        # scalar instead of a `[cleanup_apps]` table) is valid TOML but not a
        # dict -- guard for that FIRST and fall back to {} with a warning,
        # same "never make config a hard error" philosophy as paste_mode
        # above, rather than let the per-entry loop below blow up on
        # `.items()`.
        if not isinstance(self.cleanup_apps, dict):
            logger.warning(
                "cleanup_apps must be a table, got %s %r -- falling back to {} (no per-app overrides)",
                type(self.cleanup_apps).__name__,
                self.cleanup_apps,
            )
            self.cleanup_apps = {}
        else:
            cleaned_apps: dict[str, str] = {}
            for bundle_id, mode_value in self.cleanup_apps.items():
                # A mode value must be a str to normalize; a TOML boolean
                # (e.g. the natural `"com.apple.Notes" = true` typo for an
                # on/off table) or any other non-str value is treated as an
                # unknown mode -- warn (with the offending value's repr) and
                # drop just that entry, same as an unknown string mode below.
                # (`(mode_value or "").strip()` would crash on a bool: bools
                # have no .strip().)
                if not isinstance(mode_value, str):
                    logger.warning(
                        "unknown cleanup_apps mode %r for %r -- ignoring entry (valid: %s)",
                        mode_value,
                        bundle_id,
                        ", ".join(CLEANUP_APP_MODES),
                    )
                    continue
                normalized = mode_value.strip().lower()
                if normalized not in CLEANUP_APP_MODES:
                    logger.warning(
                        "unknown cleanup_apps mode %r for %r -- ignoring entry (valid: %s)",
                        mode_value,
                        bundle_id,
                        ", ".join(CLEANUP_APP_MODES),
                    )
                    continue
                # Bundle-id keys are lowercased: macOS treats bundle ids
                # case-insensitively, but a plain dict lookup is exact-match,
                # so normalize here (the lookup side in app/dictation.py
                # lowercases too -- see DictationApp.process()).
                cleaned_apps[bundle_id.lower()] = normalized
            self.cleanup_apps = cleaned_apps

    def resolved_model_repo(self, backend_id: str | None = None) -> str | None:
        """Return the configured repo override for `backend_id` (defaults
        to this config's stt_backend), or None if no override is set."""
        return self.model_repo.get(backend_id or self.stt_backend)

    def pretty(self) -> str:
        """Human-readable rendering for selftest/debug output."""
        lines = ["OLIVConfig("]
        for f in fields(self):
            lines.append(f"  {f.name}={getattr(self, f.name)!r},")
        lines.append(")")
        return "\n".join(lines)


def load_config(path: Path | str | None = None) -> OLIVConfig:
    """Load OLIVConfig from a TOML file, falling back to defaults for a
    missing file or missing/unknown keys.

    path: explicit config path, or None to use oliv.toml at the project
          root (DEFAULT_CONFIG_PATH). A nonexistent path -- explicit or
          default -- is NOT an error: it just means "use all defaults".
    """
    config_path = Path(path) if path is not None else DEFAULT_CONFIG_PATH

    if not config_path.exists():
        return OLIVConfig()

    import tomllib  # stdlib, Python 3.11+

    with open(config_path, "rb") as fh:
        raw: dict[str, Any] = tomllib.load(fh)

    known_fields = {f.name for f in fields(OLIVConfig)}
    kwargs = {k: v for k, v in raw.items() if k in known_fields}
    return OLIVConfig(**kwargs)
