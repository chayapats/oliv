"""Frontmost-app detection (W2-T3) -- who the user was dictating into.

Wave-1 pipeline: hold hotkey -> capture -> STT -> cleanup -> paste. This new
module answers one small question for the W2-T3 per-app cleanup toggle:
*which app currently has focus?* `app/dictation.py`'s `DictationApp.process()`
calls `frontmost_app()` once per utterance and looks the result up in
`config.cleanup_apps` (app/config.py) to decide whether cleanup runs or is
bypassed for that app.

Implementation: `AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()`
returns an `NSRunningApplication` for whatever app currently owns the menu
bar / key window. Unlike the hotkey (Input Monitoring) and inject
(Accessibility) stages, this API needs NO macOS privacy permission -- any
process can ask "what's frontmost" without a grant or a system prompt.

Failure philosophy: `frontmost_app()` NEVER raises. Any failure (AppKit
unavailable, a nil/half-populated NSRunningApplication, a non-macOS host)
returns None, and every caller must treat None as "unknown app" -- i.e. fall
back to whatever the config's global behavior is, exactly like a missing
config key. Detecting the frontmost app is a nicety on top of the pipeline,
never a requirement for it to run.

Import discipline: only stdlib (dataclasses, typing) at module load. AppKit
is imported lazily inside frontmost_app() itself, mirroring app/inject.py's
lazy AppKit import, so `import app.frontmost` stays instant and pulls in no
Cocoa machinery until you actually call it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class FrontmostApp:
    """The frontmost app at the moment `frontmost_app()` was called.

    bundle_id: reverse-DNS bundle identifier (e.g. "com.apple.Notes") -- the
               stable key used in config.cleanup_apps.
    name:      localized display name (e.g. "Notes") -- informational only,
               never used for matching (bundle ids are stable across
               localizations/renames; display names aren't).
    """

    bundle_id: str
    name: str


def frontmost_app() -> Optional[FrontmostApp]:
    """Return the frontmost app's bundle id + localized name, or None if
    anything goes wrong (never raises -- see the module docstring's failure
    philosophy). No macOS permission is required for this probe."""
    try:
        import AppKit  # pyobjc-framework-Cocoa

        running_app = AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
        if running_app is None:
            return None
        bundle_id = running_app.bundleIdentifier()
        if not bundle_id:
            # No stable id to key config.cleanup_apps on -- treat as unknown
            # rather than surfacing a useless empty-string bundle id.
            return None
        name = running_app.localizedName() or ""
        return FrontmostApp(bundle_id=str(bundle_id), name=str(name))
    except Exception:
        return None


__all__ = ["FrontmostApp", "frontmost_app"]
