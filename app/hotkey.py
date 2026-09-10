"""Global push-to-talk hotkey listener (W1-T2).

Wave-1 pipeline: hold hotkey -> capture audio -> STT -> cleanup -> paste.
This module owns the very first stage: turning a physical key hold into a
clean pair of `on_press` / `on_release` callbacks that the W1-T3 audio-capture
stage hooks into. It fires `on_press` exactly once when the configured key
goes down and `on_release` exactly once when it comes up, debouncing OS
auto-repeat and never leaving a "stuck recording" state behind.

Implementation: `pynput.keyboard.Listener`, which on macOS installs a Quartz
CGEvent tap. Right Option arrives as a `flagsChanged` modifier event; pynput
maps it (by virtual keycode 0x3D) to `Key.alt_r`. Note `Key.alt_r is
Key.alt_gr` -- they are the *same* enum member on macOS, so matching
`Key.alt_r` catches Right Option regardless of which alias you reason about.

Threading / callback contract
-----------------------------
`on_press` / `on_release` are invoked on pynput's **listener thread** (a
background CFRunLoop), or -- in `toggle_double_tap` mode only -- on a short
`threading.Timer` thread. Do NOT block in them: the CLI test callbacks just
print + timestamp. Downstream (audio capture) should hand off to its own
worker rather than doing heavy work inline.

Permissions
-----------
A global CGEvent tap needs macOS **Input Monitoring** granted to the host
process (this terminal); posting *synthetic* events (used by the automated
selftest) additionally needs **Accessibility**. Use `check_event_access()` to
preflight both before starting -- see `permission_hint()` for the exact
Settings path to show the user.

Import discipline: this module imports only stdlib at module load. `pynput`
(and the pyobjc Quartz framework it drags in) is imported lazily inside the
functions/methods that actually need it, mirroring app/stt/*. So `import app`
and even `import app.hotkey` stay fast and pull in no event-tap machinery
until you resolve a key or start a listener.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Callable

logger = logging.getLogger("oliv.hotkey")

# ---------------------------------------------------------------------------
# Key-name mapping
# ---------------------------------------------------------------------------
# Config strings (oliv.toml `hotkey = "..."`) -> the attribute name of the
# corresponding `pynput.keyboard.Key` member. Kept as *strings* (not Key
# objects) so this module needs no pynput import at load time; resolve_key()
# does the getattr lazily. Multiple aliases may map to one physical key.
#
# macOS note: `alt_l`/`cmd_l`/`ctrl_l`/`shift_l` resolve to the generic
# `Key.alt`/`cmd`/`ctrl`/`shift` members (the left key has no distinct vk on
# darwin), while the right-hand keys have their own `*_r` members. Right
# Option ("right_option") is the Wave-1 default.
_KEY_ATTR_MAP: dict[str, str] = {
    # Option / Alt
    "right_option": "alt_r",
    "right_alt": "alt_r",
    "left_option": "alt_l",
    "left_alt": "alt_l",
    "option": "alt_l",
    "alt": "alt_l",
    # Command
    "right_command": "cmd_r",
    "right_cmd": "cmd_r",
    "left_command": "cmd_l",
    "left_cmd": "cmd_l",
    "command": "cmd_l",
    "cmd": "cmd_l",
    # Shift
    "right_shift": "shift_r",
    "left_shift": "shift_l",
    "shift": "shift_l",
    # Control
    "right_control": "ctrl_r",
    "right_ctrl": "ctrl_r",
    "left_control": "ctrl_l",
    "left_ctrl": "ctrl_l",
    "control": "ctrl_l",
    "ctrl": "ctrl_l",
}
# Function keys F1..F20 map to themselves; F13..F20 in particular make great
# push-to-talk keys (no default macOS side effects).
for _n in range(1, 21):
    _KEY_ATTR_MAP[f"f{_n}"] = f"f{_n}"


def _known_key_names() -> list[str]:
    """Config names that actually resolve on this pynput build, sorted for
    stable error messages. Filters the static map by what `Key` really has."""
    from pynput import keyboard  # lazy

    return sorted(
        name for name, attr in _KEY_ATTR_MAP.items() if hasattr(keyboard.Key, attr)
    )


def resolve_key(name: str):
    """Resolve a config hotkey string to a `pynput.keyboard.Key`.

    Raises ValueError -- listing the known names -- for an unknown string, so
    a typo in oliv.toml surfaces as a clear config error rather than a
    listener that silently never fires.
    """
    from pynput import keyboard  # lazy

    key = (name or "").strip().lower()
    attr = _KEY_ATTR_MAP.get(key)
    if attr is None or not hasattr(keyboard.Key, attr):
        known = ", ".join(_known_key_names())
        raise ValueError(
            f"unknown hotkey name {name!r} -- known names: {known}"
        )
    return getattr(keyboard.Key, attr)


def describe_key(key) -> str:
    """Human-readable one-liner for a resolved pynput Key, e.g.
    'Key.alt_r (vk 0x3D)'. Best-effort; falls back to repr."""
    try:
        vk = key.value.vk
        return f"{key} (vk 0x{vk:02X})"
    except Exception:
        return repr(key)


# ---------------------------------------------------------------------------
# Permission probing
# ---------------------------------------------------------------------------
def check_event_access() -> tuple[bool, bool]:
    """Preflight macOS event-tap permissions.

    Returns (can_listen, can_post):
      can_listen -- Input Monitoring granted; a global CGEvent tap will
                    actually receive events.
      can_post   -- Accessibility granted; we may post *synthetic* events
                    (needed only by --hotkey-selftest).

    Uses Quartz CGPreflight*EventAccess, which never prompts. Returns
    (False, False) if Quartz is somehow unavailable.
    """
    try:
        import Quartz  # pyobjc-framework-quartz (pulled in by pynput)
    except Exception:  # pragma: no cover - Quartz missing on this platform
        return False, False
    can_listen = bool(Quartz.CGPreflightListenEventAccess())
    can_post = bool(Quartz.CGPreflightPostEventAccess())
    return can_listen, can_post


def request_listen_access() -> None:
    """Best-effort: ask macOS to prompt for Input Monitoring and register
    this process in the Settings list so the user can toggle it on. No-op if
    already granted or if the API is unavailable. Safe to call from the CLI
    test modes; harmless otherwise."""
    try:
        import Quartz

        if hasattr(Quartz, "CGRequestListenEventAccess"):
            Quartz.CGRequestListenEventAccess()
    except Exception:
        pass


def permission_hint() -> str:
    """The exact, human-facing hint to show when access is missing."""
    return (
        "Grant Input Monitoring to your terminal: System Settings -> Privacy & "
        "Security -> Input Monitoring -> enable your terminal app (then fully "
        "quit and relaunch it). The automated selftest additionally needs "
        "System Settings -> Privacy & Security -> Accessibility."
    )


# ---------------------------------------------------------------------------
# Push-to-talk listener
# ---------------------------------------------------------------------------
class PushToTalkListener:
    """Turn a held global hotkey into clean on_press/on_release callbacks.

    Parameters
    ----------
    key:
        Config key name (see `_KEY_ATTR_MAP`); default "right_option".
    on_press / on_release:
        Zero-arg callables (required, keyword-only). Fired exactly once per
        physical down / up, on the listener thread -- keep them non-blocking.
    toggle_double_tap:
        If True, a quick tap-tap (two taps within `double_tap_window`) latches
        recording ON hands-free until the next tap toggles it OFF. Default
        False -- pure push-to-talk (hold to record).
    double_tap_window:
        Seconds for the tap-tap gesture (default 0.40).

    State machine
    -------------
    A single `_recording` flag tracks whether on_press has fired without a
    matching on_release. Repeated presses without an intervening release
    (OS auto-repeat, or a resync glitch) are debounced -- on_press fires once.
    A release with no active press is ignored with a warning. `.stop()` (or a
    listener that dies mid-hold) resynchronizes: if a recording was active it
    fires on_release once so downstream never gets stuck "recording forever".
    """

    def __init__(
        self,
        key: str = "right_option",
        *,
        on_press: Callable[[], None],
        on_release: Callable[[], None],
        toggle_double_tap: bool = False,
        double_tap_window: float = 0.40,
    ) -> None:
        if on_press is None or on_release is None:
            raise ValueError("on_press and on_release are required callbacks")
        self.key_name = key
        self._on_press = on_press
        self._on_release = on_release
        self._toggle_double_tap = bool(toggle_double_tap)
        self._double_tap_window = float(double_tap_window)

        # Resolve eagerly so a bad key name fails fast at construction, not at
        # some later start() deep inside a thread.
        self._target_key = resolve_key(key)

        # State (guarded by _lock).
        self._lock = threading.RLock()
        self._recording = False
        self._locked = False  # toggle-latched (toggle mode only)
        self._press_monotonic: float | None = None
        self._ignore_next_release = False  # toggle: swallow the unlock tap's release
        self._pending_tap_timer: threading.Timer | None = None
        self._tap_gen = 0  # invalidates in-flight deferred-release timers

        # Lifecycle (guarded by _lifecycle_lock).
        self._lifecycle_lock = threading.RLock()
        self._listener = None  # pynput.keyboard.Listener | None

    # -- public API --------------------------------------------------------
    @property
    def target_key(self):
        """The resolved pynput Key this listener matches."""
        return self._target_key

    @property
    def running(self) -> bool:
        return self._listener is not None

    def start(self) -> "PushToTalkListener":
        """Install the global event tap and begin listening. Idempotent-safe
        to call again only after stop(); each start() builds a fresh pynput
        Listener (pynput Listeners are one-shot threads)."""
        from pynput import keyboard  # lazy

        with self._lifecycle_lock:
            if self._listener is not None:
                raise RuntimeError("PushToTalkListener already started")
            self._reset_state()
            listener = keyboard.Listener(
                on_press=self._handle_press,
                on_release=self._handle_release,
            )
            self._listener = listener
            listener.start()
            # Block until the tap is actually live (or has errored), so the
            # caller knows events will flow after start() returns.
            try:
                listener.wait()
            except Exception:  # pragma: no cover - defensive
                pass
        return self

    def stop(self) -> None:
        """Stop the tap, join the listener thread, and resynchronize state.

        If a recording was active (on_press fired, no on_release yet) we fire
        on_release once -- with a warning -- so the mid-hold case never leaves
        downstream stuck. Repeated start()/stop() cycles are supported."""
        with self._lifecycle_lock:
            listener = self._listener
            self._listener = None

        # Resync + cancel any pending deferred-release timer.
        with self._lock:
            self._cancel_tap_timer()
            was_recording = self._recording
            self._recording = False
            self._locked = False
            self._ignore_next_release = False
            self._press_monotonic = None

        if was_recording:
            logger.warning(
                "listener stopping while recording active -- firing on_release "
                "to avoid a stuck recording state"
            )
            self._safe_call(self._on_release, "on_release")

        if listener is not None:
            listener.stop()
            # Never join our own thread (e.g. if stop() were called from a
            # callback), which would deadlock.
            if listener is not threading.current_thread():
                try:
                    listener.join()
                except RuntimeError:  # pragma: no cover - not started/joinable
                    pass

    def __enter__(self) -> "PushToTalkListener":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()

    # -- internals ---------------------------------------------------------
    def _reset_state(self) -> None:
        with self._lock:
            self._cancel_tap_timer()
            self._recording = False
            self._locked = False
            self._ignore_next_release = False
            self._press_monotonic = None

    def _matches(self, key) -> bool:
        return key == self._target_key

    def _safe_call(self, cb: Callable[[], None], label: str) -> None:
        """Invoke a user callback outside our lock, swallowing+logging any
        exception so a buggy callback can never kill the event tap."""
        try:
            cb()
        except Exception:
            logger.exception("hotkey %s callback raised", label)

    # pynput invokes these on its listener thread with the event's key.
    def _handle_press(self, key) -> None:
        if not self._matches(key):
            return
        if self._toggle_double_tap:
            self._press_toggle()
        else:
            self._press_hold()

    def _handle_release(self, key) -> None:
        if not self._matches(key):
            return
        if self._toggle_double_tap:
            self._release_toggle()
        else:
            self._release_hold()

    # -- pure push-to-talk (default) --------------------------------------
    def _press_hold(self) -> None:
        fire = False
        with self._lock:
            if self._recording:
                logger.warning(
                    "hotkey press while already recording -- debouncing repeat "
                    "(OS auto-repeat or a missed release)"
                )
            else:
                self._recording = True
                self._press_monotonic = time.monotonic()
                fire = True
        if fire:
            self._safe_call(self._on_press, "on_press")

    def _release_hold(self) -> None:
        fire = False
        with self._lock:
            if not self._recording:
                logger.warning(
                    "hotkey release with no active press -- ignoring (resync)"
                )
            else:
                self._recording = False
                self._press_monotonic = None
                fire = True
        if fire:
            self._safe_call(self._on_release, "on_release")

    # -- double-tap-to-toggle mode ----------------------------------------
    # Gesture model (opt-in): a *short* tap defers its on_release by
    # `double_tap_window`; if a second press lands inside the window we cancel
    # that deferred release and latch (locked) recording ON with no spurious
    # first-tap clip. A press while locked toggles recording OFF. A *long*
    # hold (held longer than the window) is treated as ordinary
    # press-and-hold: on_release fires immediately on release.
    def _press_toggle(self) -> None:
        fire_press = False
        fire_release = False
        with self._lock:
            if self._locked:
                # Press while latched -> stop/unlock. Balance the earlier
                # on_press with an on_release and swallow this tap's release.
                self._locked = False
                self._recording = False
                self._press_monotonic = None
                self._ignore_next_release = True
                self._cancel_tap_timer()
                fire_release = True
            else:
                was_pending = self._cancel_tap_timer()
                if was_pending:
                    # Second tap inside the window -> latch. Recording is still
                    # active from the first tap's (deferred) press.
                    self._locked = True
                    self._press_monotonic = None
                elif self._recording:
                    logger.warning(
                        "hotkey press while already recording -- debouncing repeat"
                    )
                else:
                    self._recording = True
                    self._press_monotonic = time.monotonic()
                    fire_press = True
        if fire_press:
            self._safe_call(self._on_press, "on_press")
        if fire_release:
            self._safe_call(self._on_release, "on_release")

    def _release_toggle(self) -> None:
        fire_release = False
        with self._lock:
            if self._ignore_next_release:
                self._ignore_next_release = False
                return
            if self._locked:
                # Physical key came up after we latched -- stay recording.
                return
            if not self._recording:
                logger.warning(
                    "hotkey release with no active press -- ignoring (resync)"
                )
                return
            held = time.monotonic() - (self._press_monotonic or time.monotonic())
            if held <= self._double_tap_window:
                # Short tap: defer the release, awaiting a possible second tap.
                self._start_tap_timer()
            else:
                # Long hold: stop now.
                self._recording = False
                self._press_monotonic = None
                fire_release = True
        if fire_release:
            self._safe_call(self._on_release, "on_release")

    def _tap_timeout(self, gen: int) -> None:
        """Deferred on_release for a short tap that was NOT followed by a
        second tap within the window. Runs on a Timer thread."""
        fire = False
        with self._lock:
            if gen != self._tap_gen:
                return  # superseded/cancelled
            self._pending_tap_timer = None
            if self._locked or not self._recording:
                return
            self._recording = False
            self._press_monotonic = None
            fire = True
        if fire:
            self._safe_call(self._on_release, "on_release")

    def _start_tap_timer(self) -> None:
        """(under _lock) Arm the deferred-release timer for a short tap."""
        self._cancel_tap_timer()
        self._tap_gen += 1
        gen = self._tap_gen
        timer = threading.Timer(self._double_tap_window, self._tap_timeout, args=(gen,))
        timer.daemon = True
        self._pending_tap_timer = timer
        timer.start()

    def _cancel_tap_timer(self) -> bool:
        """(under _lock) Cancel any pending deferred-release timer, and
        invalidate any timeout already in flight. Returns True if a timer was
        pending (i.e. we were inside a short-tap window)."""
        self._tap_gen += 1  # any in-flight _tap_timeout sees a stale gen
        timer = self._pending_tap_timer
        self._pending_tap_timer = None
        if timer is not None:
            timer.cancel()
            return True
        return False


__all__ = [
    "PushToTalkListener",
    "resolve_key",
    "describe_key",
    "check_event_access",
    "request_listen_access",
    "permission_hint",
]
