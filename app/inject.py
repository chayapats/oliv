"""Text injection -- paste at the focused app's text cursor (W1-T5).

Wave-1 pipeline: hold hotkey -> capture -> STT -> cleanup -> **paste at the
text cursor of whatever app has focus (this stage)**. Once the cleaned
transcript string exists, the job here is to get it into the frontmost app's
focused text field. macOS gives no public "type this Unicode string into the
focused control" API that works everywhere, so we use the classic, robust
pattern every macOS dictation/expander tool uses:

    1. Save the current general NSPasteboard (all types, + its changeCount).
    2. Write our text to the pasteboard as a UTF-8 NSString (Thai survives).
    3. Synthesize Cmd+V via Quartz CGEvent, posted to the HID event tap --
       the focused app reads the pasteboard and inserts the text at its
       cursor, exactly as if the user pressed Cmd+V.
    4. Wait a bounded moment for the app to read the pasteboard, then restore
       the user's original clipboard so we don't leave our text behind.

Why clipboard + Cmd+V (and not synthesizing the characters directly)? Posting
per-character CGEvents is unreliable for arbitrary Unicode (dead keys,
combining marks, emoji, IME state) and slow; the pasteboard round-trips any
string byte-for-byte, and one Cmd+V is atomic from the app's point of view.

The changeCount / paste-window trade-off
-----------------------------------------
There is NO public signal on macOS that a paste was *consumed*: the target
app reads the pasteboard on its own main thread when it handles Cmd+V, and a
*read* does not bump NSPasteboard.changeCount. So we cannot know the instant
the text landed. A naive `sleep(0.1)` then restore is fragile -- a slow app
(or a busy main thread) may not have read yet, and we'd restore the original
underneath it, so the paste inserts the OLD clipboard.

What we implement instead, using changeCount as the one thing we *can*
observe -- who currently owns the pasteboard:

  * After writing our text we remember `own_change_count = changeCount`.
  * We post Cmd+V, then poll changeCount up to `paste_timeout` (default 1.0s):
      - If changeCount stays == own_change_count for the whole window, WE
        still own the pasteboard, so it is safe to put the user's original
        contents back -- we restore and report clipboard_restored=True.
      - If changeCount *advances* during the window, some OTHER writer took
        over the clipboard (e.g. a clipboard manager, or the user copied
        something). We stop early and DON'T restore, to avoid clobbering that
        newer content; clipboard_restored=False with a note.

  Trade-off: because there is no consumption signal, the injected text sits on
  the clipboard for up to `paste_timeout` before we hand it back. Larger
  timeout = more reliable for slow apps but a longer window where the user's
  clipboard shows our text; smaller = snappier restore but risks a slow app
  reading the restored (wrong) contents. 1.0s is a safe default; the poll
  makes the common case restore promptly only insofar as an external writer
  appears -- otherwise it waits the full budget by design.

Permissions
-----------
Posting synthetic CGEvents needs macOS **Accessibility** granted to the host
process (this terminal) -- the same grant --hotkey-selftest needs to post
events, and the W1-T6 gate. `check_post_access()` preflights it via
`Quartz.CGPreflightPostEventAccess()` (never prompts), mirroring
app.hotkey.check_event_access(). When Accessibility is missing, inject_text
still writes the text to the pasteboard (so the user can paste manually with
Cmd+V) but does NOT synthesize keys and -- crucially -- does NOT restore the
clipboard, because the text must stay available for that manual paste. It
reports posted=False, used_fallback=True.

paste_mode
----------
Config `paste_mode` (app.config.OLIVConfig) selects behaviour:
  * "clipboard_restore" (default): the full save -> set -> Cmd+V -> restore
    flow above (subject to the Accessibility gate).
  * "clipboard_only": the degraded, consent-free mode -- write the text to
    the clipboard and STOP. Never synthesize keys, never restore. The user
    pastes manually. Useful when you don't want to grant Accessibility, or as
    a safe default in a headless/unattended context.

Import discipline: only stdlib at module load. AppKit (pyobjc-framework-Cocoa)
and Quartz are imported lazily inside the functions that touch them, mirroring
app/hotkey.py and app/audio.py, so `import app` and `import app.inject` stay
fast and pull in no pasteboard / event machinery until you actually inject.

What the clipboard save/restore does and does NOT preserve
----------------------------------------------------------
save_clipboard() snapshots, for every NSPasteboardItem currently on the
general pasteboard, the concrete NSData of every declared type. restore
rewrites brand-new items with that exact data, so plain text, RTF, HTML,
images (TIFF/PNG), file URLs and arbitrary custom binary flavors round-trip
byte-for-byte (verified incl. Thai combining marks + emoji). NOT preserved:
lazily-*promised* data whose owning app supplies it on demand (e.g. drag/file
promises) -- if `dataForType_` returns nil at snapshot time there is nothing
to save, so that flavor is dropped; and the pasteboard "owner" association
itself (restored data is all eagerly materialized bytes with no lazy owner).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

logger = logging.getLogger("oliv.inject")

# Virtual keycode for the "V" key (kVK_ANSI_V) -- layout-independent hardware
# keycode, so Cmd+<this> is Cmd+V regardless of the active keyboard layout.
_KEYCODE_V = 9

# Default demo string for --inject-test: Thai + English + emoji, to prove
# UTF-8 fidelity end-to-end through the pasteboard.
DEFAULT_INJECT_TEXT = "OLIV ทดสอบ paste ภาษาไทย + English mixed ✓"


# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------
@dataclass
class InjectResult:
    """Outcome of an inject_text() call.

    posted:
        True iff we successfully synthesized Cmd+V (Accessibility granted and
        the CGEvent post succeeded). False in clipboard_only mode, when
        Accessibility is missing, or if posting failed unexpectedly.
    clipboard_restored:
        True iff we put the user's original clipboard back afterwards. Only
        possible when we posted AND restore_clipboard was requested AND no
        other app grabbed the pasteboard during the paste window.
    used_fallback:
        True iff we *wanted* to paste but couldn't synthesize keys (missing
        Accessibility, posting error, or AppKit unavailable) and instead left
        the text on the clipboard for a manual Cmd+V. False for the normal
        posted path and for the intentional clipboard_only mode.
    mode:
        The effective paste_mode ("clipboard_restore" | "clipboard_only").
    text_len:
        Number of characters written to the pasteboard.
    notes:
        Human-readable explanation of what happened / what to do next.
    """

    posted: bool
    clipboard_restored: bool
    used_fallback: bool
    mode: str
    text_len: int
    notes: str

    def pretty(self) -> str:
        return (
            f"InjectResult(posted={self.posted}, "
            f"clipboard_restored={self.clipboard_restored}, "
            f"used_fallback={self.used_fallback}, mode={self.mode!r}, "
            f"text_len={self.text_len})\n"
            f"  notes: {self.notes}"
        )


# ---------------------------------------------------------------------------
# Permission probing (mirrors app.hotkey.check_event_access shape)
# ---------------------------------------------------------------------------
def check_post_access() -> bool:
    """Preflight macOS Accessibility (post-event) access via Quartz
    CGPreflightPostEventAccess. Never prompts. Returns False if Quartz is
    unavailable. Posting the synthetic Cmd+V needs this granted."""
    try:
        import Quartz  # pyobjc-framework-quartz
    except Exception:  # pragma: no cover - Quartz missing on this platform
        return False
    return bool(Quartz.CGPreflightPostEventAccess())


def request_post_access() -> None:
    """Best-effort: ask macOS to prompt for Accessibility and register this
    process in the Settings list so the user can toggle it on. No-op if
    already granted or the API is unavailable. Safe to call from CLI test
    modes; harmless otherwise."""
    try:
        import Quartz

        if hasattr(Quartz, "CGRequestPostEventAccess"):
            Quartz.CGRequestPostEventAccess()
    except Exception:
        pass


def post_access_hint() -> str:
    """The exact, human-facing hint to show when Accessibility is missing.
    This overlaps with the hotkey selftest's Accessibility grant (W1-T6)."""
    return (
        "Grant Accessibility to your terminal so OLIV can paste for you: "
        "System Settings -> Privacy & Security -> Accessibility -> enable your "
        "terminal app (then fully quit and relaunch it). Until then the text is "
        "placed on the clipboard -- paste it yourself with Cmd+V."
    )


# ---------------------------------------------------------------------------
# Pasteboard snapshot / restore
# ---------------------------------------------------------------------------
class InjectUnavailable(RuntimeError):
    """Raised (internally) when AppKit / NSPasteboard cannot be reached --
    e.g. AppKit not installed or not on macOS. inject_text() catches this and
    returns a degraded InjectResult rather than raising at the caller."""


@dataclass
class ClipboardSnapshot:
    """A faithful, restorable capture of the general pasteboard.

    items:
        One dict per NSPasteboardItem, mapping each declared UTI type string
        to its concrete NSData at snapshot time (bytes-backed; retained by
        this object so it survives a later clearContents()).
    change_count:
        NSPasteboard.changeCount at the moment of the snapshot -- an opaque,
        monotonically increasing token; any external write bumps it.
    """

    items: list  # list[dict[str, NSData]]
    change_count: int

    @property
    def is_empty(self) -> bool:
        return not any(self.items)

    def summary(self) -> str:
        """Concise one-liner for CLI output: item/type counts + a short string
        preview, WITHOUT dumping full binary blobs."""
        if self.is_empty:
            return "empty (no items)"
        parts: list[str] = []
        for idx, item in enumerate(self.items):
            type_bits: list[str] = []
            for t, data in item.items():
                n = int(data.length()) if data is not None else 0
                preview = _preview_string(t, data)
                if preview is not None:
                    type_bits.append(f"{t} ({preview!r})")
                else:
                    type_bits.append(f"{t} [{n} bytes]")
            parts.append(f"item{idx}: " + ", ".join(type_bits))
        return f"{len(self.items)} item(s): " + " | ".join(parts)


def _preview_string(uti: str, data) -> str | None:
    """If `uti` is a plain/utf8 text flavor, decode a short preview of its
    NSData for display; else None. Best-effort, never raises."""
    if data is None:
        return None
    if uti not in ("public.utf8-plain-text", "public.plain-text", "NSStringPboardType"):
        return None
    try:
        raw = bytes(data)
        text = raw.decode("utf-8", errors="replace")
    except Exception:
        return None
    text = text.replace("\n", "\\n")
    return text if len(text) <= 40 else text[:37] + "..."


def _general_pasteboard():
    """Return the general NSPasteboard, or raise InjectUnavailable if AppKit
    is not importable (non-macOS / missing pyobjc-framework-Cocoa)."""
    try:
        import AppKit  # pyobjc-framework-Cocoa
    except Exception as exc:  # pragma: no cover - AppKit present in this env
        raise InjectUnavailable(f"AppKit/NSPasteboard unavailable: {exc}") from exc
    return AppKit.NSPasteboard.generalPasteboard()


def save_clipboard(pb=None) -> ClipboardSnapshot:
    """Snapshot the general pasteboard for later faithful restore.

    Captures, per item, the concrete NSData of every declared type (see the
    module docstring for exactly what is / isn't preserved). Read-only -- does
    NOT modify the pasteboard. Per-type reads are individually guarded so one
    unreadable/promised flavor can't abort the whole snapshot."""
    if pb is None:
        pb = _general_pasteboard()
    items: list = []
    for item in pb.pasteboardItems() or []:
        data_by_type: dict = {}
        for t in list(item.types() or []):
            try:
                data = item.dataForType_(t)
            except Exception:
                data = None
            if data is not None:
                data_by_type[t] = data
        items.append(data_by_type)
    return ClipboardSnapshot(items=items, change_count=int(pb.changeCount()))


def restore_saved_clipboard(snapshot: ClipboardSnapshot, pb=None) -> bool:
    """Rewrite the general pasteboard from a ClipboardSnapshot. Returns True if
    a restore write occurred. An empty snapshot is restored as an emptied
    pasteboard (clearContents) so a previously-empty clipboard is faithfully
    returned to empty. Never raises for a single bad type."""
    if pb is None:
        pb = _general_pasteboard()
    import AppKit

    pb.clearContents()
    new_items: list = []
    for data_by_type in snapshot.items:
        ns_item = AppKit.NSPasteboardItem.alloc().init()
        wrote_any = False
        for t, data in data_by_type.items():
            try:
                if ns_item.setData_forType_(data, t):
                    wrote_any = True
            except Exception:
                logger.debug("could not restore pasteboard type %s", t, exc_info=True)
        if wrote_any:
            new_items.append(ns_item)
    if new_items:
        pb.writeObjects_(new_items)
    return True


def _set_pasteboard_string(pb, text: str) -> int:
    """Write `text` to the pasteboard as a UTF-8 NSString and return the
    resulting changeCount. setString_forType_ handles the Python-str ->
    NSString bridging; Thai / combining marks / emoji survive intact."""
    import AppKit

    pb.clearContents()
    pb.setString_forType_(text, AppKit.NSPasteboardTypeString)
    return int(pb.changeCount())


# ---------------------------------------------------------------------------
# CGEvent Cmd+V posting
# ---------------------------------------------------------------------------
def _post_cmd_v() -> bool:
    """Synthesize a Cmd+V key down/up via Quartz CGEvent, posted to the HID
    event tap so the frontmost app sees it as a real paste shortcut. Returns
    True on a successful post, False on any error. Assumes the caller already
    verified Accessibility via check_post_access()."""
    try:
        import Quartz

        source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
        key_down = Quartz.CGEventCreateKeyboardEvent(source, _KEYCODE_V, True)
        key_up = Quartz.CGEventCreateKeyboardEvent(source, _KEYCODE_V, False)
        if key_down is None or key_up is None:
            logger.error("CGEventCreateKeyboardEvent returned None")
            return False
        # Carry the Command modifier on both edges so the shortcut fires even
        # if no physical modifier is down.
        Quartz.CGEventSetFlags(key_down, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventSetFlags(key_up, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, key_down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, key_up)
        return True
    except Exception:
        logger.exception("failed to post synthetic Cmd+V")
        return False


def _wait_for_paste_window(pb, own_change_count: int, paste_timeout: float) -> bool:
    """Bounded wait after posting Cmd+V, before restoring the clipboard.

    Polls changeCount up to `paste_timeout`. Returns True if an EXTERNAL writer
    changed the pasteboard during the window (changeCount advanced past our own
    write) -- in which case the caller must NOT restore, to avoid clobbering
    that newer content. Returns False if we still own the pasteboard for the
    whole window (safe to restore). See the module docstring for why there is
    no true 'paste consumed' signal to wait on instead."""
    import time

    deadline = time.monotonic() + max(0.0, float(paste_timeout))
    while time.monotonic() < deadline:
        if int(pb.changeCount()) != own_change_count:
            return True
        time.sleep(0.02)
    return int(pb.changeCount()) != own_change_count


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------
def inject_text(
    text: str,
    *,
    restore_clipboard: bool = True,
    paste_timeout: float = 1.0,
    mode: str = "clipboard_restore",
) -> InjectResult:
    """Paste `text` at the focused app's text cursor via clipboard + Cmd+V.

    Parameters
    ----------
    text:
        The string to insert. Written to the pasteboard as UTF-8 (Thai OK).
    restore_clipboard:
        In "clipboard_restore" mode, whether to put the user's original
        clipboard back after the paste. Ignored in "clipboard_only" mode and
        when Accessibility is missing (we always keep the text available for a
        manual paste in the gated case).
    paste_timeout:
        Max seconds to wait for the target app to read the pasteboard before
        restoring (see the changeCount/paste-window design in the module
        docstring). Default 1.0s.
    mode:
        "clipboard_restore" (default) for the full save->set->Cmd+V->restore
        flow, or "clipboard_only" for the degraded set-and-stop behaviour.

    Returns an InjectResult; never raises for the expected failure modes
    (missing Accessibility, AppKit unavailable) -- those come back as a
    degraded result with used_fallback=True and an explanatory note.
    """
    mode = (mode or "clipboard_restore").strip().lower()
    if mode not in ("clipboard_restore", "clipboard_only"):
        logger.warning("unknown paste mode %r; using 'clipboard_restore'", mode)
        mode = "clipboard_restore"
    text_len = len(text)

    # Reach the pasteboard (degrade gracefully if AppKit is somehow missing).
    try:
        pb = _general_pasteboard()
    except InjectUnavailable as exc:
        return InjectResult(
            posted=False,
            clipboard_restored=False,
            used_fallback=True,
            mode=mode,
            text_len=text_len,
            notes=f"{exc}. Could not place text on the clipboard.",
        )

    # Snapshot the current clipboard first (read-only) -- for the summary and
    # for a possible restore.
    snapshot = save_clipboard(pb)

    # Write our text; remember the changeCount we produced so the paste-window
    # poll can tell "we still own it" from "someone else wrote".
    own_change_count = _set_pasteboard_string(pb, text)

    # -- clipboard_only: set and stop. Never post, never restore. -----------
    if mode == "clipboard_only":
        return InjectResult(
            posted=False,
            clipboard_restored=False,
            used_fallback=False,
            mode=mode,
            text_len=text_len,
            notes=(
                "clipboard_only mode: text placed on the clipboard; no keys "
                "synthesized and clipboard not restored. Paste manually with Cmd+V."
            ),
        )

    # -- clipboard_restore: gate on Accessibility. --------------------------
    if not check_post_access():
        return InjectResult(
            posted=False,
            clipboard_restored=False,
            used_fallback=True,
            mode=mode,
            text_len=text_len,
            notes=(
                "Accessibility not granted: could not synthesize Cmd+V. Text left "
                "on the clipboard for manual paste; original clipboard intentionally "
                "NOT restored so the text stays available. " + post_access_hint()
            ),
        )

    # Post the synthetic Cmd+V.
    posted = _post_cmd_v()
    if not posted:
        return InjectResult(
            posted=False,
            clipboard_restored=False,
            used_fallback=True,
            mode=mode,
            text_len=text_len,
            notes=(
                "Cmd+V synthesis failed unexpectedly despite Accessibility being "
                "granted; text left on the clipboard for manual paste, original not "
                "restored."
            ),
        )

    # Posted OK. Optionally restore the original clipboard after the app has
    # had its bounded chance to read our text.
    if not restore_clipboard:
        return InjectResult(
            posted=True,
            clipboard_restored=False,
            used_fallback=False,
            mode=mode,
            text_len=text_len,
            notes="posted Cmd+V; restore_clipboard=False, so injected text left on the clipboard.",
        )

    externally_changed = _wait_for_paste_window(pb, own_change_count, paste_timeout)
    if externally_changed:
        return InjectResult(
            posted=True,
            clipboard_restored=False,
            used_fallback=False,
            mode=mode,
            text_len=text_len,
            notes=(
                "posted Cmd+V; another writer changed the clipboard during the paste "
                "window, so the original was NOT restored (avoided clobbering newer "
                "content)."
            ),
        )

    restore_saved_clipboard(snapshot, pb)
    return InjectResult(
        posted=True,
        clipboard_restored=True,
        used_fallback=False,
        mode=mode,
        text_len=text_len,
        notes=(
            f"posted Cmd+V; waited up to {paste_timeout:g}s for the paste, then "
            f"restored the original clipboard ({snapshot.summary()})."
        ),
    )


__all__ = [
    "InjectResult",
    "ClipboardSnapshot",
    "inject_text",
    "save_clipboard",
    "restore_saved_clipboard",
    "check_post_access",
    "request_post_access",
    "post_access_hint",
    "DEFAULT_INJECT_TEXT",
]
