"""OLIV CLI entrypoint.

    python -m app --selftest [--config PATH]
    python -m app --hotkey-test [--duration 15] [--config PATH]
    python -m app --hotkey-selftest [--config PATH]
    python -m app --hotkey-unittest
    python -m app --audio-test [--seconds 12]
    python -m app --audio-e2e [--seconds 8]
    python -m app --audio-unittest
    python -m app --ptt-test [--duration 20] [--config PATH]
    python -m app --stt-test [--backend ID] [--config PATH]
    python -m app --inject-test [--text "..."] [--config PATH]
    python -m app --clipboard-unittest
    python -m app --frontmost-test
    python -m app --cleanup-toggle-unittest

--selftest (W1-T1) proves the config-loading and STT-backend plumbing work
end-to-end on a real sample clip. --stt-test (W1-T4) transcribes one clip
from each of the thai_only/english_only/mixed buckets through the
CONFIGURED STT backend (config's stt_backend default is now "pathumma-mlx",
the PRIMARY backend -- the Pathumma fine-tune on mlx-whisper, ~1.5s/clip;
pass --backend mlx-large-v3 to spot-check the FALLBACK, or --backend
pathumma for the original slow HF-transformers path), printing each
transcript next to its manifest reference plus load/decode timings. The --hotkey-* modes (W1-T2) exercise the global
push-to-talk listener:

  --hotkey-test      interactive: hold the configured key and watch PRESS /
                     RELEASE lines print for `duration` seconds.
  --hotkey-selftest  automated, no human: posts synthetic key events and
                     asserts the listener fires cleanly. Exits 2 (not a
                     failure) if macOS Input Monitoring / Accessibility access
                     is not yet granted -- that grant is the W1-T6 gate.
  --hotkey-unittest  drives the listener state machine directly (fake key
                     events); needs no OS permissions at all.

The --audio-* / --ptt-test modes (W1-T3) exercise app/audio.py's Recorder
and DictationSession:

  --audio-test    probes mic permission (AVFoundation preflight + a short
                  probe capture), records `seconds`, prints capture stats
                  (duration/samples/rate/peak/RMS/overflows), saves
                  /tmp/oliv_audio_test.wav. Exits 2 if the mic is
                  permission-gated.
  --audio-e2e     records `seconds` and hands the array straight to the
                  mlx-large-v3 STT backend -- proves the array contract
                  end-to-end. Empty transcript on ambient/silent audio is a
                  plumbing PASS.
  --audio-unittest  Recorder repeated-cycle + misuse checks (no human, no
                  extra OS permission dialog).
  --ptt-test      the real integration: wires PushToTalkListener to Recorder
                  (+ STT) via DictationSession. Needs a human holding the
                  hotkey; 0 utterances in a headless run is a valid pass.

The --inject-test / --clipboard-unittest modes (W1-T5) exercise
app/inject.py's paste-at-cursor (clipboard + synthetic Cmd+V):

  --inject-test        set the clipboard to a Thai+English+emoji demo string
                       (or --text) and synthesize Cmd+V so it lands at the
                       focused app's cursor. Prints the saved clipboard, each
                       step, and the InjectResult. Exits 2 (not a failure) if
                       macOS Accessibility isn't granted -- same grant as
                       --hotkey-selftest (the W1-T6 gate); the text is still
                       placed on the clipboard for a manual Cmd+V. When access
                       IS granted the paste hits WHATEVER app has focus, so a
                       3s countdown prints first -- focus a scratch field.
  --clipboard-unittest fully automated (no permissions): asserts UTF-8/Thai
                       clipboard fidelity, the save/restore round-trip over
                       multiple pasteboard types, and the InjectResult restore
                       semantics with posting mocked. Leaves the clipboard
                       exactly as found.

The --frontmost-test / --cleanup-toggle-unittest modes (W2-T3) exercise
app/frontmost.py's frontmost-app detection and the per-app cleanup toggle
wired into app/dictation.py's DictationApp.process():

  --frontmost-test           print the detected frontmost app (bundle id +
                             name) once per second for ~5s -- Cmd-Tab around
                             and watch it change. No macOS permission is
                             needed for this probe (unlike the hotkey/inject
                             gates).
  --cleanup-toggle-unittest  hermetic (stub STT backend + stub CleanupClient
                             + a fake frontmost_fn -- no model, no subprocess,
                             no OS permissions): asserts per-app "off"
                             bypasses cleanup entirely (worker never called,
                             final==raw byte-identical incl. Thai text),
                             per-app "on"/absent runs cleanup, global
                             cleanup_enabled=false wins over the table
                             regardless, an unknown mode value is dropped
                             with a warning, frontmost=None (or a raising
                             frontmost_fn) falls back to global behavior,
                             records carry app_bundle_id + cleanup_applied,
                             the debug word-diff line appears iff final !=
                             raw, and a non-dict cleanup_apps (oliv.toml
                             scalar typo) degrades to {} without raising.

The cleanup CLI surface arrives in a later Wave-1 task.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from app.config import load_config
from app.stt import build_backend

SAMPLE_CLIPS_DIR = Path(__file__).resolve().parent.parent / "benchmark" / "data" / "clips"
MANIFEST_PATH = Path(__file__).resolve().parent.parent / "benchmark" / "data" / "manifest.jsonl"


def _pick_sample_wav() -> Path:
    """Pick a sample WAV clip for the selftest: prefer the mixed-bucket
    mx03*.wav called out in the task brief, then any mx*.wav (mixed
    bucket), then any .wav at all."""
    if not SAMPLE_CLIPS_DIR.is_dir():
        raise FileNotFoundError(f"sample clips dir not found: {SAMPLE_CLIPS_DIR}")

    wavs = sorted(SAMPLE_CLIPS_DIR.glob("*.wav"))
    if not wavs:
        raise FileNotFoundError(f"no .wav files found in {SAMPLE_CLIPS_DIR}")

    for wav in wavs:
        if wav.stem == "mx03":
            return wav
    for wav in wavs:
        if wav.stem.startswith("mx"):
            return wav
    return wavs[0]


def _stt_test_clips() -> list[tuple[str, Path]]:
    """Pick the three benchmark clips --stt-test transcribes: one
    thai_only, one english_only, one mixed -- per the task brief's
    th01*/en02*/mx03* picks. Prefers those exact stems (they exist in
    benchmark/data/clips/ as of W1-T4), falling back to the first clip
    whose stem starts with that bucket's prefix (th/en/mx) if a preferred
    stem is ever renamed/missing."""
    buckets = [
        ("thai_only", "th01", "th"),
        ("english_only", "en02", "en"),
        ("mixed", "mx03", "mx"),
    ]
    clips: list[tuple[str, Path]] = []
    if not SAMPLE_CLIPS_DIR.is_dir():
        return clips
    for label, preferred_stem, prefix in buckets:
        preferred = SAMPLE_CLIPS_DIR / f"{preferred_stem}.wav"
        if preferred.is_file():
            clips.append((label, preferred))
            continue
        candidates = sorted(SAMPLE_CLIPS_DIR.glob(f"{prefix}*.wav"))
        if candidates:
            clips.append((label, candidates[0]))
    return clips


def _manifest_reference(clip_id: str) -> str | None:
    """Best-effort lookup of the reference transcript for `clip_id` in
    benchmark/data/manifest.jsonl, for the selftest to print alongside the
    model output. Returns None if the manifest or the id isn't found --
    this is just an informational nicety, not required for selftest to
    pass."""
    if not MANIFEST_PATH.is_file():
        return None
    import json

    try:
        with open(MANIFEST_PATH, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):  # manifest.jsonl has comment lines
                    continue
                row = json.loads(line)
                if row.get("id") == clip_id:
                    return row.get("reference")
    except Exception:
        return None
    return None


def _run_selftest(config_path: str | None) -> int:
    print("=== OLIV selftest ===\n")

    print(f"[1/4] Loading config (path={config_path or f'<default: {Path.cwd()}/oliv.toml>'}) ...")
    config = load_config(config_path)
    print(config.pretty())

    print("\n[2/4] Picking a sample WAV clip ...")
    try:
        sample = _pick_sample_wav()
    except FileNotFoundError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"  clip: {sample}")
    reference = _manifest_reference(sample.stem)
    if reference is not None:
        print(f"  manifest reference: {reference!r}")

    print("\n[3/4] Building STT backend 'mlx-large-v3' (config default) ...")
    try:
        backend = build_backend("mlx-large-v3")
    except Exception as exc:
        print(f"FAIL: could not build backend: {exc}", file=sys.stderr)
        return 1

    print("  warming up (loading model weights) ...")
    t0 = time.time()
    warmed = backend.warm_up()
    t1 = time.time()
    if warmed:
        print(f"  model load time: {t1 - t0:.2f}s")
    else:
        print("  (backend has no separate warm_up(); load time will be included below)")

    print("\n[4/4] Transcribing sample clip (language=None, auto decode) ...")
    t2 = time.time()
    try:
        text = backend.transcribe(sample, language=None)
    except Exception as exc:
        print(f"FAIL: transcription failed: {exc}", file=sys.stderr)
        return 1
    t3 = time.time()
    label = "transcription time" if warmed else "model load + transcription time"
    print(f"  {label}: {t3 - t2:.2f}s")

    print(f"\nTranscript:\n  {text!r}")

    print("\n=== selftest OK ===")
    return 0


def _run_stt_test(config_path: str | None, backend_override: str | None) -> int:
    """--stt-test (W1-T4): transcribe one clip from each of the
    thai_only/english_only/mixed buckets through the CONFIGURED STT
    backend (or --backend override), printing each clip's transcript next
    to its benchmark/data/manifest.jsonl reference, plus model load time
    (once) and per-clip decode time -- feeds the W1-T6 latency budget."""
    print("=== OLIV STT test ===\n")

    print(f"[1/3] Loading config (path={config_path or f'<default: {Path.cwd()}/oliv.toml>'}) ...")
    config = load_config(config_path)
    backend_id = backend_override or config.stt_backend
    print(f"  configured stt_backend: {config.stt_backend!r}")
    if backend_override:
        print(f"  --backend override: {backend_override!r}")

    print(f"\n[2/3] Picking sample clips (thai_only/english_only/mixed) from {SAMPLE_CLIPS_DIR} ...")
    clips = _stt_test_clips()
    if not clips:
        print(f"FAIL: no sample clips found under {SAMPLE_CLIPS_DIR}", file=sys.stderr)
        return 1
    for label, path in clips:
        print(f"  {label:14s} {path.name}")

    print(f"\n[3/3] Building STT backend {backend_id!r} ...")
    try:
        backend = build_backend(backend_id)
    except Exception as exc:
        print(f"FAIL: could not build backend {backend_id!r}: {exc}", file=sys.stderr)
        return 1

    print("  warming up (loading model weights) ...")
    t0 = time.time()
    warmed = backend.warm_up()
    t1 = time.time()
    if warmed:
        print(f"  model load time: {t1 - t0:.2f}s")
    else:
        print("  (backend has no separate warm_up(); load time will be included in the first clip's decode time)")

    print("\nTranscribing sample clips (language=None, auto decode) ...")
    failures: list[str] = []
    for label, path in clips:
        reference = _manifest_reference(path.stem)
        print(f"\n--- {label} :: {path.name} ---")
        if reference is not None:
            print(f"  manifest reference: {reference!r}")
        t2 = time.time()
        try:
            text = backend.transcribe(path, language=None)
        except Exception as exc:
            print(f"  FAIL: transcription failed: {exc}", file=sys.stderr)
            failures.append(f"{label} ({path.name})")
            continue
        t3 = time.time()
        decode_label = "decode time" if warmed else "load + decode time (first clip)"
        print(f"  {decode_label}: {t3 - t2:.2f}s")
        print(f"  transcript: {text!r}")

    if failures:
        print(f"\n=== stt test FAIL ({len(failures)} clip(s): {', '.join(failures)}) ===")
        return 1
    print("\n=== stt test done ===")
    return 0


# ---------------------------------------------------------------------------
# W1-T2 hotkey CLI modes
# ---------------------------------------------------------------------------
def _print_access(can_listen: bool, can_post: bool, need_post: bool) -> None:
    """Print the permission-probe results + a hint listing only the grants
    that are actually missing for this mode (shared by the hotkey modes)."""
    print(f"  Input Monitoring (listen access): {'GRANTED' if can_listen else 'MISSING'}")
    print(f"  Accessibility    (post access):   {'GRANTED' if can_post else 'MISSING'}")
    missing: list[str] = []
    if not can_listen:
        missing.append("Input Monitoring (System Settings -> Privacy & Security -> Input Monitoring)")
    if need_post and not can_post:
        missing.append("Accessibility (System Settings -> Privacy & Security -> Accessibility)")
    if missing:
        print("  HINT: enable your terminal app for the following, then fully quit & relaunch it:")
        for item in missing:
            print(f"          - {item}")


def _resolve_hotkey(config_path: str | None):
    """Load config, resolve its hotkey to a pynput Key, print both. Returns
    (config, key). Raises ValueError for an unknown key name."""
    from app.hotkey import describe_key, resolve_key

    config = load_config(config_path)
    key = resolve_key(config.hotkey)
    print(f"Resolved hotkey: {config.hotkey!r} -> {describe_key(key)}")
    return config, key


def _run_hotkey_test(config_path: str | None, duration: float) -> int:
    from app.hotkey import PushToTalkListener, check_event_access, request_listen_access

    print("=== OLIV hotkey test ===\n")
    try:
        config, _key = _resolve_hotkey(config_path)
    except ValueError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    print("\nPermissions:")
    can_listen, can_post = check_event_access()
    _print_access(can_listen, can_post, need_post=False)
    if not can_listen:
        print("  (requesting Input Monitoring access -- watch for a system prompt)")
        request_listen_access()
        print("  NOTE: without Input Monitoring granted, no key events will arrive below.")

    print(
        f"\nHold {config.hotkey!r} to see PRESS/RELEASE lines. Listening for "
        f"{duration:g}s (Ctrl-C to stop early)...\n"
    )

    t0 = time.monotonic()
    counters = {"cycles": 0, "press_at": None}

    def on_press() -> None:
        now = time.monotonic() - t0
        counters["press_at"] = now
        print(f"PRESS   t={now:6.2f}", flush=True)

    def on_release() -> None:
        now = time.monotonic() - t0
        pressed_at = counters["press_at"]
        held = (now - pressed_at) if pressed_at is not None else float("nan")
        counters["cycles"] += 1
        print(f"RELEASE t={now:6.2f} (held {held:.2f}s)", flush=True)

    listener = PushToTalkListener(
        config.hotkey, on_press=on_press, on_release=on_release
    )
    listener.start()
    try:
        deadline = t0 + duration
        while time.monotonic() < deadline:
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\n(interrupted)")
    finally:
        listener.stop()

    print(f"\n=== done: {counters['cycles']} press/release cycle(s) ===")
    return 0


def _run_hotkey_selftest(config_path: str | None) -> int:
    """Automated verification via synthetic events. Exit 0 PASS / 1 FAIL /
    2 permission-gated (the W1-T6 grant, not a code failure)."""
    from app.hotkey import (
        PushToTalkListener,
        check_event_access,
        resolve_key,
    )

    print("=== OLIV hotkey selftest (automated) ===\n")
    config = load_config(config_path)
    try:
        key = resolve_key(config.hotkey)
    except ValueError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    print("Permissions:")
    can_listen, can_post = check_event_access()
    _print_access(can_listen, can_post, need_post=True)
    if not (can_listen and can_post):
        print(
            "\nPERMISSION-GATED: posting synthetic events needs Accessibility and "
            "receiving them needs Input Monitoring; see the missing grant(s) above."
        )
        print("This is the W1-T6 grant step, not a code failure. Exiting 2.")
        return 2

    from pynput import keyboard

    controller = keyboard.Controller()
    failures: list[str] = []

    class _Counter:
        def __init__(self) -> None:
            self.presses = 0
            self.releases = 0
            self.last_held: float | None = None
            self._t0: float | None = None

        def on_press(self) -> None:
            self.presses += 1
            self._t0 = time.monotonic()

        def on_release(self) -> None:
            self.releases += 1
            if self._t0 is not None:
                self.last_held = time.monotonic() - self._t0

    def _check(cond: bool, msg: str) -> None:
        status = "PASS" if cond else "FAIL"
        print(f"  [{status}] {msg}")
        if not cond:
            failures.append(msg)

    # -- Test 1: single synthetic press/release fires each callback once ----
    print(f"\n[1] single press/release of {config.hotkey!r}")
    c1 = _Counter()
    listener = PushToTalkListener(config.hotkey, on_press=c1.on_press, on_release=c1.on_release)
    listener.start()
    try:
        controller.press(key)
        time.sleep(0.30)
        controller.release(key)
        time.sleep(0.15)
    finally:
        listener.stop()
    _check(c1.presses == 1, f"on_press fired exactly once (got {c1.presses})")
    _check(c1.releases == 1, f"on_release fired exactly once (got {c1.releases})")
    _check(
        c1.last_held is not None and 0.15 <= c1.last_held <= 0.80,
        f"held time sane (~0.30s, got {c1.last_held})",
    )

    # -- Test 2: debounce -- two presses, one release => one of each ---------
    print("\n[2] debounce: press, press (repeat), release")
    c2 = _Counter()
    listener = PushToTalkListener(config.hotkey, on_press=c2.on_press, on_release=c2.on_release)
    listener.start()
    try:
        controller.press(key)
        time.sleep(0.05)
        controller.press(key)  # repeat / auto-repeat analogue
        time.sleep(0.05)
        controller.release(key)
        time.sleep(0.15)
    finally:
        listener.stop()
    _check(c2.presses == 1, f"repeat press debounced -> on_press once (got {c2.presses})")
    _check(c2.releases == 1, f"on_release once (got {c2.releases})")

    # -- Test 3: start / stop / start cycle still works ----------------------
    print("\n[3] start/stop/start cycle")
    c3 = _Counter()
    listener = PushToTalkListener(config.hotkey, on_press=c3.on_press, on_release=c3.on_release)
    listener.start()
    listener.stop()
    listener.start()  # fresh listener, same object
    try:
        controller.press(key)
        time.sleep(0.10)
        controller.release(key)
        time.sleep(0.15)
    finally:
        listener.stop()
    _check(c3.presses == 1, f"post-restart on_press once (got {c3.presses})")
    _check(c3.releases == 1, f"post-restart on_release once (got {c3.releases})")

    if failures:
        print(f"\n=== hotkey selftest FAIL ({len(failures)} check(s)) ===")
        return 1
    print("\n=== hotkey selftest PASS ===")
    return 0


# ---------------------------------------------------------------------------
# W1-T3 audio-capture CLI modes
# ---------------------------------------------------------------------------
def _run_audio_test(seconds: float) -> int:
    """--audio-test: probe mic permission, record `seconds`, print stats,
    save to /tmp/oliv_audio_test.wav."""
    import numpy as np

    from app.audio import Recorder, check_microphone_access, microphone_permission_hint, save_wav

    print("=== OLIV audio capture test ===\n")

    print("[1/3] Preflighting microphone access (AVFoundation, no prompt) ...")
    authorized, status = check_microphone_access()
    print(f"  authorization status: {status}")
    if status in ("denied", "restricted"):
        print(f"\nPERMISSION-GATED: microphone access is {status}.")
        print(f"HINT: {microphone_permission_hint()}")
        return 2
    if not authorized:
        print(
            "  (not yet determined, or AVFoundation unavailable -- attempting a probe "
            "capture next; macOS may show a permission prompt now)"
        )

    print("\n[2/3] Probe capture (0.3s) to sanity-check the signal path ...")
    probe = Recorder()
    try:
        probe.start()
        time.sleep(0.3)
        probe_audio = probe.stop()
    except Exception as exc:
        print(f"FAIL: could not open the microphone: {exc}", file=sys.stderr)
        print(f"HINT: {microphone_permission_hint()}", file=sys.stderr)
        return 2

    probe_silent = probe_audio.size == 0 or float(np.abs(probe_audio).max()) == 0.0
    if probe_silent:
        print("  WARNING: probe capture was completely silent (exact-zero samples).")
        print("  This strongly suggests the microphone is NOT authorized for this process")
        print("  (macOS feeds an unauthorized process silence rather than raising an error).")
        print(f"  HINT: {microphone_permission_hint()}")
        return 2
    print(f"  probe OK -- peak={probe.stats.peak:.5f}, path={probe.stats.path}")

    print(f"\n[3/3] Recording {seconds:g}s ...")
    recorder = Recorder()
    recorder.start()
    time.sleep(seconds)
    audio = recorder.stop()
    print(recorder.stats.pretty())

    out_path = Path("/tmp/oliv_audio_test.wav")
    save_wav(out_path, audio, samplerate=recorder.samplerate)
    print(f"\n  saved: {out_path}")

    print("\n=== audio test done ===")
    return 0


def _run_audio_e2e(seconds: float) -> int:
    """--audio-e2e: record `seconds`, hand the array straight to the
    mlx-large-v3 STT backend, print transcript + timings."""
    from app.audio import Recorder, check_microphone_access, microphone_permission_hint
    from app.stt import build_backend

    print("=== OLIV audio -> STT end-to-end test ===\n")

    authorized, status = check_microphone_access()
    print(f"Microphone authorization: {status}")
    if status in ("denied", "restricted"):
        print(f"\nPERMISSION-GATED: {microphone_permission_hint()}")
        return 2

    print(f"\n[1/3] Recording {seconds:g}s ...")
    recorder = Recorder()
    try:
        recorder.start()
        time.sleep(seconds)
        audio = recorder.stop()
    except Exception as exc:
        print(f"FAIL: could not capture audio: {exc}", file=sys.stderr)
        print(f"HINT: {microphone_permission_hint()}", file=sys.stderr)
        return 2
    print(recorder.stats.pretty())

    print("\n[2/3] Building STT backend 'mlx-large-v3' ...")
    try:
        backend = build_backend("mlx-large-v3")
    except Exception as exc:
        print(f"FAIL: could not build backend: {exc}", file=sys.stderr)
        return 1

    print("  warming up (loading model weights) ...")
    t0 = time.time()
    warmed = backend.warm_up()
    t1 = time.time()
    if warmed:
        print(f"  model load time: {t1 - t0:.2f}s")
    else:
        print("  (backend has no separate warm_up(); load time will be included below)")

    print("\n[3/3] Transcribing captured array (language=None, auto decode) ...")
    t2 = time.time()
    try:
        text = backend.transcribe(audio, language=None)
    except Exception as exc:
        print(f"FAIL: transcription failed: {exc}", file=sys.stderr)
        return 1
    t3 = time.time()
    label = "transcription time" if warmed else "model load + transcription time"
    print(f"  {label}: {t3 - t2:.2f}s")

    print(f"\nTranscript:\n  {text!r}")
    if not text.strip():
        print(
            "  (empty transcript -- expected for ambient/silent-room audio; "
            "this is a PASS of the array-contract plumbing, not a failure)"
        )

    print("\n=== audio e2e done ===")
    return 0


def _run_audio_unittest() -> int:
    """--audio-unittest: repeated-cycle + misuse checks on Recorder, no
    human interaction and no OS permission dialog required beyond whatever
    this machine's mic authorization already is."""
    from app.audio import Recorder

    print("=== OLIV Recorder unit test ===\n")
    failures: list[str] = []

    def _check(cond: bool, msg: str) -> None:
        status = "PASS" if cond else "FAIL"
        print(f"  [{status}] {msg}")
        if not cond:
            failures.append(msg)

    print("[1] misuse: stop() without start() raises RuntimeError")
    r = Recorder()
    try:
        r.stop()
        _check(False, "stop() without start() should have raised")
    except RuntimeError:
        _check(True, "stop() without start() raised RuntimeError")
    except Exception as exc:
        _check(False, f"stop() without start() raised wrong type: {exc!r}")

    print("\n[2] misuse: start() twice raises RuntimeError; first stream unaffected")
    r = Recorder()
    try:
        r.start()
        try:
            r.start()
            _check(False, "second start() should have raised")
        except RuntimeError:
            _check(True, "second start() raised RuntimeError")
        finally:
            r.stop()
    except Exception as exc:
        _check(False, f"setup for double-start test failed: {exc!r}")

    print("\n[3] repeated start/stop cycles (3x) on one Recorder")
    r = Recorder()
    cycles_ok = True
    for i in range(3):
        try:
            r.start()
            time.sleep(0.2)
            audio = r.stop()
        except Exception as exc:
            cycles_ok = False
            print(f"  cycle {i + 1} raised: {exc!r}")
            break
        print(
            f"  cycle {i + 1}: n_samples={len(audio)} peak={r.stats.peak:.5f} "
            f"path={r.stats.path}"
        )
    _check(cycles_ok, "3x start/stop cycles completed without error")

    print("\n[4] wedged-PortAudio stop: bounded, salvages audio, sets stop_forced")
    # Pa_StopStream can block forever on macOS when coreaudiod/HAL is in a bad
    # state (observed live). Simulate a fully wedged stream and prove stop()
    # still returns within its staged timeouts with the buffer intact.
    import threading as _threading

    import numpy as _np

    class _WedgedStream:
        def stop(self):  # pragma: no cover - must never be called by stop()
            _threading.Event().wait()

        def abort(self):
            _threading.Event().wait()  # blocks forever

        def close(self):
            _threading.Event().wait()  # blocks forever

    r = Recorder()
    r._stream = _WedgedStream()
    r._stop_requested = _threading.Event()
    r._finished = _threading.Event()  # never set -> graceful path times out
    fake = _np.full((1600, 1), 0.25, dtype=_np.float32)  # 0.1s of fake audio
    r._chunks = [fake]
    t0 = time.time()
    audio = r.stop()
    elapsed = time.time() - t0
    _check(elapsed < 8.0, f"wedged stop returned in {elapsed:.1f}s (bounded, <8s)")
    _check(len(audio) == 1600 and abs(float(audio.max()) - 0.25) < 1e-6,
           "captured audio salvaged intact from the wedged stream")
    _check(r.stats is not None and r.stats.stop_forced,
           "stats.stop_forced is True for the abandoned stream")
    _check(r.running is False, "recorder is reusable (no active stream) after forced stop")

    if failures:
        print(f"\n=== audio unittest FAIL ({len(failures)} check(s)) ===")
        return 1
    print("\n=== audio unittest PASS ===")
    return 0


class DictationSummary:
    """Tiny accumulator for --ptt-test's end-of-run summary. Kept separate
    from DictationSession (app/audio.py) since it's CLI-report bookkeeping,
    not part of the reusable capture seam."""

    def __init__(self) -> None:
        self.count = 0

    def record(self) -> int:
        self.count += 1
        return self.count


def _run_ptt_test(config_path: str | None, duration: float) -> int:
    """--ptt-test: the real integration -- wire PushToTalkListener to
    Recorder via DictationSession (press -> start, release -> stop -> save
    WAV -> transcribe). Requires a human holding the key; headless (0
    utterances) is a valid pass -- this just proves the plumbing starts
    cleanly and tears down cleanly after `duration`."""
    from app.audio import DictationSession, save_wav
    from app.hotkey import check_event_access, request_listen_access
    from app.stt import build_backend

    print("=== OLIV push-to-talk integration test ===\n")
    try:
        config, _key = _resolve_hotkey(config_path)
    except ValueError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    print("\nPermissions:")
    can_listen, can_post = check_event_access()
    _print_access(can_listen, can_post, need_post=False)
    if not can_listen:
        print("  (requesting Input Monitoring access -- watch for a system prompt)")
        request_listen_access()
        print("  NOTE: without Input Monitoring granted, no key events will arrive below.")

    print(f"\nBuilding STT backend {config.stt_backend!r} ...")
    backend = None
    try:
        backend = build_backend(config.stt_backend)
        t0 = time.time()
        warmed = backend.warm_up()
        if warmed:
            print(f"  model load time: {time.time() - t0:.2f}s")
    except Exception as exc:
        print(f"  WARNING: STT backend unavailable ({exc}); utterances will be captured " "but not transcribed.")

    summary = DictationSummary()

    def on_utterance(audio, stats) -> None:
        idx = summary.record()
        print(f"\n[utterance {idx}] {stats.duration_s:.2f}s peak={stats.peak:.4f} rms={stats.rms:.6f} " f"path={stats.path}")
        out_path = Path(f"/tmp/oliv_ptt_test_{idx}.wav")
        save_wav(out_path, audio, samplerate=stats.samplerate)
        print(f"  saved: {out_path}")
        if backend is not None:
            t0 = time.time()
            try:
                text = backend.transcribe(audio, language=None)
            except Exception as exc:
                print(f"  transcription FAILED: {exc}")
            else:
                print(f"  transcript ({time.time() - t0:.2f}s): {text!r}")

    def on_error(exc: Exception) -> None:
        print(f"\n[utterance error] {exc!r}")

    session = DictationSession(config.hotkey, on_utterance=on_utterance, on_error=on_error)
    session.start()
    print(
        f"\nhold {config.hotkey!r} to dictate... listening for {duration:g}s "
        "(Ctrl-C to stop early)\n"
    )
    try:
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\n(interrupted)")
    finally:
        session.stop()

    print(f"\n=== done: {summary.count} utterance(s) captured ===")
    return 0


def _run_hotkey_unittest() -> int:
    """Drive the PushToTalkListener state machine directly with fake key
    events -- no pynput listener, no OS permissions. Verifies debounce,
    resync, and the double-tap toggle gesture deterministically."""
    from app.hotkey import PushToTalkListener

    print("=== OLIV hotkey state-machine unit test (no OS events) ===\n")
    failures: list[str] = []

    def _check(cond: bool, msg: str) -> None:
        status = "PASS" if cond else "FAIL"
        print(f"  [{status}] {msg}")
        if not cond:
            failures.append(msg)

    class _Counter:
        def __init__(self) -> None:
            self.presses = 0
            self.releases = 0

        def on_press(self) -> None:
            self.presses += 1

        def on_release(self) -> None:
            self.releases += 1

    # -- Test 1: basic hold ------------------------------------------------
    print("[1] basic hold: press -> release")
    c = _Counter()
    lis = PushToTalkListener("right_option", on_press=c.on_press, on_release=c.on_release)
    k = lis.target_key
    lis._handle_press(k)
    lis._handle_release(k)
    _check(c.presses == 1 and c.releases == 1, f"one press/one release (got {c.presses}/{c.releases})")

    # -- Test 2: debounce repeated presses ---------------------------------
    print("\n[2] debounce: press, press, press, release")
    c = _Counter()
    lis = PushToTalkListener("right_option", on_press=c.on_press, on_release=c.on_release)
    k = lis.target_key
    lis._handle_press(k)
    lis._handle_press(k)
    lis._handle_press(k)
    lis._handle_release(k)
    _check(c.presses == 1, f"repeats debounced -> on_press once (got {c.presses})")
    _check(c.releases == 1, f"on_release once (got {c.releases})")

    # -- Test 3: spurious release ignored ----------------------------------
    print("\n[3] spurious release with no active press")
    c = _Counter()
    lis = PushToTalkListener("right_option", on_press=c.on_press, on_release=c.on_release)
    k = lis.target_key
    lis._handle_release(k)  # should be ignored
    _check(c.presses == 0 and c.releases == 0, f"ignored (got {c.presses}/{c.releases})")

    # -- Test 4: non-target key ignored ------------------------------------
    print("\n[4] a different key is ignored")
    from app.hotkey import resolve_key

    c = _Counter()
    lis = PushToTalkListener("right_option", on_press=c.on_press, on_release=c.on_release)
    other = resolve_key("right_shift")
    lis._handle_press(other)
    lis._handle_release(other)
    _check(c.presses == 0 and c.releases == 0, f"other key ignored (got {c.presses}/{c.releases})")

    # -- Test 5: resync on stop() mid-hold ---------------------------------
    print("\n[5] resync: press with no release, then stop() balances it")
    c = _Counter()
    lis = PushToTalkListener("right_option", on_press=c.on_press, on_release=c.on_release)
    k = lis.target_key
    lis._handle_press(k)  # recording started, never released
    lis.stop()  # no listener running; must still fire on_release to resync
    _check(c.presses == 1 and c.releases == 1, f"stop() fired resync on_release (got {c.presses}/{c.releases})")

    # -- Test 6: double-tap toggle -- lone short tap still releases ---------
    print("\n[6] toggle mode: lone short tap -> deferred on_release fires")
    c = _Counter()
    lis = PushToTalkListener(
        "right_option",
        on_press=c.on_press,
        on_release=c.on_release,
        toggle_double_tap=True,
        double_tap_window=0.05,
    )
    k = lis.target_key
    lis._handle_press(k)
    lis._handle_release(k)  # short tap -> release deferred by 0.05s
    _check(c.presses == 1 and c.releases == 0, f"release deferred (got {c.presses}/{c.releases})")
    time.sleep(0.12)  # let the deferred-release timer fire
    _check(c.presses == 1 and c.releases == 1, f"deferred release fired (got {c.presses}/{c.releases})")

    # -- Test 7: double-tap toggle -- lock then unlock ---------------------
    print("\n[7] toggle mode: tap-tap locks, next tap unlocks")
    c = _Counter()
    lis = PushToTalkListener(
        "right_option",
        on_press=c.on_press,
        on_release=c.on_release,
        toggle_double_tap=True,
        double_tap_window=0.05,
    )
    k = lis.target_key
    lis._handle_press(k)     # tap1 down -> on_press
    lis._handle_release(k)   # tap1 up (short) -> deferred
    lis._handle_press(k)     # tap2 down inside window -> LATCH (no 2nd on_press)
    lis._handle_release(k)   # tap2 up -> ignored (latched, keep recording)
    _check(c.presses == 1 and c.releases == 0, f"latched recording, no release yet (got {c.presses}/{c.releases})")
    time.sleep(0.12)  # prove the latch is NOT torn down by a stray timer
    _check(c.presses == 1 and c.releases == 0, f"still latched after window (got {c.presses}/{c.releases})")
    lis._handle_press(k)     # unlock tap down -> stop (on_release)
    lis._handle_release(k)   # unlock tap up -> swallowed
    _check(c.presses == 1 and c.releases == 1, f"unlock fired on_release once (got {c.presses}/{c.releases})")

    if failures:
        print(f"\n=== hotkey unit test FAIL ({len(failures)} check(s)) ===")
        return 1
    print("\n=== hotkey unit test PASS ===")
    return 0


# ---------------------------------------------------------------------------
# W1-T5 text-injection CLI modes
# ---------------------------------------------------------------------------
def _run_inject_test(config_path: str | None, text: str | None) -> int:
    """--inject-test: exercise paste-at-cursor. Probes Accessibility, prints
    the current clipboard, then runs inject_text (forcing mode=clipboard_restore
    to exercise the paste path). Exit 0 on a posted paste / 2 if Accessibility
    is missing (the W1-T6 gate -- not a code failure), matching
    --hotkey-selftest. When access IS granted the synthetic Cmd+V lands in
    WHATEVER app has focus, so we print a 3s countdown first."""
    import AppKit

    from app.inject import (
        DEFAULT_INJECT_TEXT,
        check_post_access,
        inject_text,
        post_access_hint,
        request_post_access,
        save_clipboard,
    )

    print("=== OLIV inject (paste-at-cursor) test ===\n")
    config = load_config(config_path)
    text = text if text is not None else DEFAULT_INJECT_TEXT
    print(f"  configured paste_mode: {config.paste_mode!r}")
    print("  (--inject-test forces mode='clipboard_restore' to exercise the paste path)")
    print(f"  text to inject: {text!r}")

    print("\n[1/4] Probing Accessibility (post-event) access (no prompt) ...")
    can_post = check_post_access()
    print(f"  Accessibility (post access): {'GRANTED' if can_post else 'MISSING'}")

    pb = AppKit.NSPasteboard.generalPasteboard()
    before = save_clipboard(pb)
    print(f"\n[2/4] Current clipboard (saved before injecting): {before.summary()}")

    if not can_post:
        print("\n  (requesting Accessibility -- watch for a system prompt / Settings entry)")
        request_post_access()
        print("  NOTE: Accessibility missing -- inject_text will still SET the pasteboard so")
        print("        you can paste manually, but will NOT synthesize Cmd+V and will NOT")
        print("        restore the clipboard (the text stays available for a manual Cmd+V).")
    else:
        print("\n  HEADLESS CAVEAT: Accessibility IS granted -- the synthetic Cmd+V will paste")
        print("  into WHATEVER app currently has focus. Focus a scratch text field NOW.")
        for n in (3, 2, 1):
            print(f"    pasting in {n} ...", flush=True)
            time.sleep(1.0)

    print("\n[3/4] Injecting (mode=clipboard_restore) ...")
    result = inject_text(text, mode="clipboard_restore")

    print("\n[4/4] Steps + result:")
    print(f"  clipboard saved:    {before.summary()}")
    print(f"  text set:           {text!r}")
    print(f"  Cmd+V posted:       {result.posted}")
    print(f"  clipboard restored: {result.clipboard_restored}")
    print(f"  used_fallback:      {result.used_fallback}")
    print()
    print(result.pretty())

    if not result.posted:
        print(f"\nPERMISSION-GATED: {post_access_hint()}")
        print("The pasteboard WAS set (paste manually with Cmd+V); the clipboard was NOT")
        print("restored so the text stays available. This is the same Accessibility grant")
        print("--hotkey-selftest needs (the W1-T6 gate), not a code failure. Exiting 2.")
        return 2

    print("\n=== inject test done ===")
    return 0


def _run_clipboard_unittest() -> int:
    """--clipboard-unittest: fully automated pasteboard fidelity + save/restore
    + InjectResult path checks. Needs NO OS permissions (never posts real keys;
    posting is mocked out). Hermetic: saves the user's real clipboard up front
    and restores it in a finally, so the machine is left exactly as found."""
    import AppKit

    import app.inject as inject_mod
    from app.inject import inject_text, restore_saved_clipboard, save_clipboard

    print("=== OLIV clipboard / inject unit test (no OS permissions) ===\n")
    failures: list[str] = []

    def _check(cond: bool, msg: str) -> None:
        status = "PASS" if cond else "FAIL"
        print(f"  [{status}] {msg}")
        if not cond:
            failures.append(msg)

    S = AppKit.NSPasteboardTypeString
    pb = AppKit.NSPasteboard.generalPasteboard()

    def _cur() -> str | None:
        return pb.stringForType_(S)

    # Save the user's REAL clipboard so we can leave the machine exactly as found.
    real_snapshot = save_clipboard(pb)
    print(f"[0] saved user's real clipboard: {real_snapshot.summary()}")

    orig_check = inject_mod.check_post_access
    orig_post = inject_mod._post_cmd_v
    try:
        # -- [1] UTF-8 fidelity (Thai / mixed / emoji+combining) --------------
        # Set a hermetic sentinel first and treat it as the "original" for the
        # round-trip test, so nothing depends on the user's real clipboard.
        print("\n[1] UTF-8 fidelity: set Thai/mixed/emoji strings, read back byte-identical")
        sentinel = "OLIV-SENTINEL-original"
        pb.clearContents()
        pb.setString_forType_(sentinel, S)
        sentinel_snapshot = save_clipboard(pb)
        samples = [
            ("thai", "สวัสดีครับ ยินดีต้อนรับ"),
            ("mixed", "OLIV ทดสอบ paste ภาษาไทย + English mixed ✓"),
            ("emoji+combining", "กราฟาน้ำ ✓ 🎙️"),
        ]
        for label, s in samples:
            pb.clearContents()
            pb.setString_forType_(s, S)
            back = _cur()
            ok = back == s and back.encode("utf-8") == s.encode("utf-8")
            _check(ok, f"{label}: byte-identical readback ({s!r})")

        # -- [2] save/restore restores the sentinel exactly -------------------
        print("\n[2] save/restore round-trip restores the original (sentinel) exactly")
        restore_saved_clipboard(sentinel_snapshot, pb)
        _check(_cur() == sentinel, f"restored sentinel exactly (got {_cur()!r})")

        # -- [3] multi-type round-trip: string + HTML + custom binary ---------
        print("\n[3] save/restore round-trip with multiple pasteboard types present")
        HTML = AppKit.NSPasteboardTypeHTML
        CUSTOM = "com.oliv.test.binary"
        raw = bytes(range(256))
        item = AppKit.NSPasteboardItem.alloc().init()
        item.setString_forType_("multi ไทย ✓", S)
        item.setString_forType_("<b>ไทย</b>", HTML)
        item.setData_forType_(AppKit.NSData.dataWithBytes_length_(raw, len(raw)), CUSTOM)
        pb.clearContents()
        pb.writeObjects_([item])
        multi_snapshot = save_clipboard(pb)
        pb.clearContents()  # clobber
        pb.setString_forType_("CLOBBERED", S)
        restore_saved_clipboard(multi_snapshot, pb)
        back_str = pb.stringForType_(S)
        back_html = pb.stringForType_(HTML)
        back_bin = pb.dataForType_(CUSTOM)
        _check(back_str == "multi ไทย ✓", f"string type restored ({back_str!r})")
        _check(back_html == "<b>ไทย</b>", f"HTML type restored ({back_html!r})")
        _check(back_bin is not None and bytes(back_bin) == raw, "custom binary type restored byte-identical")

        # -- [4] InjectResult path: posting mocked TRUE -> clipboard restored -
        print("\n[4] inject_text posted=True path (posting mocked): clipboard IS restored")
        inject_mod.check_post_access = lambda: True
        inject_mod._post_cmd_v = lambda: True
        pb.clearContents()
        pb.setString_forType_("ORIGINAL-A", S)
        r = inject_text("INJECTED-A", restore_clipboard=True, paste_timeout=0.05)
        _check(r.posted is True, f"posted=True (got {r.posted})")
        _check(r.clipboard_restored is True, f"clipboard_restored=True (got {r.clipboard_restored})")
        _check(r.used_fallback is False, f"used_fallback=False (got {r.used_fallback})")
        _check(_cur() == "ORIGINAL-A", f"clipboard restored to original (got {_cur()!r})")

        # -- [5] InjectResult path: gated posted=False -> text LEFT, NOT restored
        print("\n[5] inject_text gated posted=False path (access mocked missing): text left, NOT restored")
        inject_mod.check_post_access = lambda: False
        inject_mod._post_cmd_v = orig_post  # never reached on this path
        pb.clearContents()
        pb.setString_forType_("ORIGINAL-B", S)
        r = inject_text("INJECTED-B", restore_clipboard=True, paste_timeout=0.05)
        _check(r.posted is False, f"posted=False (got {r.posted})")
        _check(r.clipboard_restored is False, f"clipboard_restored=False (got {r.clipboard_restored})")
        _check(r.used_fallback is True, f"used_fallback=True (got {r.used_fallback})")
        _check(_cur() == "INJECTED-B", f"injected text LEFT on clipboard for manual paste (got {_cur()!r})")

        # -- [6] clipboard_only mode: set, never post, never restore ----------
        print("\n[6] clipboard_only mode: text set, no post, no restore (even with access)")
        posted_calls = {"n": 0}

        def _tracking_post() -> bool:
            posted_calls["n"] += 1
            return True

        inject_mod.check_post_access = lambda: True
        inject_mod._post_cmd_v = _tracking_post
        pb.clearContents()
        pb.setString_forType_("ORIGINAL-C", S)
        r = inject_text("INJECTED-C", mode="clipboard_only")
        _check(
            r.posted is False and r.used_fallback is False,
            f"posted=False used_fallback=False (got {r.posted}/{r.used_fallback})",
        )
        _check(posted_calls["n"] == 0, f"_post_cmd_v NOT called in clipboard_only mode (calls={posted_calls['n']})")
        _check(_cur() == "INJECTED-C", f"text set on clipboard (got {_cur()!r})")
    finally:
        inject_mod.check_post_access = orig_check
        inject_mod._post_cmd_v = orig_post
        # Leave the machine exactly as found.
        restore_saved_clipboard(real_snapshot, pb)
        print(f"\n[cleanup] restored user's real clipboard: {save_clipboard(pb).summary()}")

    if failures:
        print(f"\n=== clipboard unittest FAIL ({len(failures)} check(s)) ===")
        return 1
    print("\n=== clipboard unittest PASS ===")
    return 0


# ---------------------------------------------------------------------------
# W2-T3 frontmost-app / per-app cleanup toggle CLI modes
# ---------------------------------------------------------------------------
def _run_frontmost_test(duration: float = 5.0) -> int:
    """--frontmost-test: print the detected frontmost app (bundle id + name)
    once per second for ~`duration` seconds so a human can Cmd-Tab around and
    watch it change. No macOS permission is needed for this probe (unlike
    --hotkey-selftest's Input Monitoring or --inject-test's Accessibility)."""
    from app.frontmost import frontmost_app

    print("=== OLIV frontmost-app test ===\n")
    print(
        f"Printing the frontmost app once per second for {duration:g}s -- "
        "Cmd-Tab to another app and watch it change.\n"
    )

    ticks = max(1, int(round(duration)))
    for i in range(ticks):
        app = frontmost_app()
        if app is None:
            print(f"  t={i + 1}s  (unknown -- frontmost_app() returned None)")
        else:
            print(f"  t={i + 1}s  bundle_id={app.bundle_id!r}  name={app.name!r}")
        time.sleep(1.0)

    print("\n=== frontmost test done ===")
    return 0


def _run_cleanup_toggle_unittest() -> int:
    """--cleanup-toggle-unittest: hermetic checks for the per-app cleanup
    toggle wired into app/dictation.py's DictationApp.process(). Uses a stub
    STT backend + a stub CleanupClient (no model, no subprocess worker) and a
    fake frontmost_fn (no AppKit / OS permissions) so the bypass/gate logic
    can be asserted deterministically:
      (a) per-app "off" bypasses cleanup entirely (worker not called, final
          byte-identical to raw, including Thai text)
      (b) per-app "on" (and no per-app entry at all) runs cleanup normally
      (c) global cleanup_enabled=false wins over the table (no cleanup ever)
      (d) an unknown cleanup_apps mode value is dropped with a warning
          (app/config.py's OLIVConfig.__post_init__)
      (e) frontmost_fn returning None falls back to global (on) behavior
      (f) UtteranceRecord carries app_bundle_id + cleanup_applied
      (g) log_line()'s debug word-diff appears iff final != raw
      (h) frontmost_fn RAISING behaves exactly like it returning None (no
          crash, global behavior, app_bundle_id stays "")
      (i) a non-dict cleanup_apps (oliv.toml scalar typo, e.g.
          cleanup_apps = "off") degrades to {} without raising
          (app/config.py's OLIVConfig.__post_init__)
      (j) a non-str mode value (oliv.toml boolean typo, e.g.
          `"com.test.a" = true`) is dropped like any other unknown mode --
          one bad entry doesn't take a co-located valid entry down with it
          (app/config.py's OLIVConfig.__post_init__)
      (k) bundle-id matching is case-insensitive: a mixed-case key in
          cleanup_apps bypasses cleanup for a lowercase (or any differently
          -cased) frontmost bundle id, and vice versa (macOS itself treats
          bundle ids case-insensitively)
    """
    import logging as _logging

    from app.config import OLIVConfig
    from app.dictation import DictationApp
    from app.frontmost import FrontmostApp

    print("=== OLIV cleanup per-app toggle unit test (no model, no OS permissions) ===\n")
    failures: list[str] = []

    def _check(cond: bool, msg: str) -> None:
        status = "PASS" if cond else "FAIL"
        print(f"  [{status}] {msg}")
        if not cond:
            failures.append(msg)

    RAW_THAI = "สวัสดีครับ ผมใช้ ไฟล์จูน กับโมเดลนี้"

    class _StubBackend:
        """Canned transcript -- no real STT model load."""

        def __init__(self, text: str) -> None:
            self.text = text
            self.calls = 0

        def transcribe(self, audio, language=None) -> str:
            self.calls += 1
            return self.text

    class _StubCleanupClient:
        """Records whether clean() was invoked and returns a canned outcome
        -- no cleanup_worker.py subprocess is ever spawned."""

        def __init__(self, cleaned_text: str) -> None:
            self.cleaned_text = cleaned_text
            self.calls = 0

        def clean(self, text: str, timeout: float = 8.0):
            from app.cleanup import CleanupOutcome

            self.calls += 1
            return CleanupOutcome(
                text=self.cleaned_text,
                llm_ran=True,
                gate_reason="dict-hit",
                guardrail_flag="ok",
                t_total=0.01,
                used_fallback=False,
            )

    def _make_app(config, frontmost_fn, backend, cleanup) -> DictationApp:
        """Wire the stubs straight into a DictationApp WITHOUT calling
        build()/warm() (which would import app.stt / spawn the real worker)
        -- mirrors how --clipboard-unittest mocks app.inject's internals."""
        dapp = DictationApp(config, cleanup_enabled=config.cleanup_enabled, frontmost_fn=frontmost_fn)
        dapp.backend = backend
        dapp.cleanup = cleanup
        return dapp

    # -- (a) per-app off -> bypass: worker not called, byte-identical Thai --
    print("[1] per-app off -> bypass (worker not called, final==raw byte-identical)")
    config_a = OLIVConfig(cleanup_enabled=True, cleanup_apps={"com.test.editor": "off"})
    backend_a = _StubBackend(RAW_THAI)
    cleanup_a = _StubCleanupClient("SHOULD NOT APPEAR")
    app_a = _make_app(
        config_a,
        lambda: FrontmostApp(bundle_id="com.test.editor", name="Editor"),
        backend_a,
        cleanup_a,
    )
    rec_a = app_a.process(None, duration_s=1.0, inject=False)
    _check(cleanup_a.calls == 0, f"worker NOT called (calls={cleanup_a.calls})")
    _check(rec_a.final == RAW_THAI, f"final == raw Thai text byte-identical (got {rec_a.final!r})")
    _check(rec_a.final == rec_a.raw, "final == raw (identity)")
    _check(rec_a.t_cleanup == 0.0, f"t_cleanup == 0.0 (got {rec_a.t_cleanup})")
    _check(rec_a.cleanup_applied == "off-per-app", f"cleanup_applied == 'off-per-app' (got {rec_a.cleanup_applied!r})")
    _check(rec_a.app_bundle_id == "com.test.editor", f"app_bundle_id recorded (got {rec_a.app_bundle_id!r})")

    # -- (b) per-app on / absent -> cleanup runs ------------------------------
    print("\n[2] per-app on -> cleanup runs")
    config_b1 = OLIVConfig(cleanup_enabled=True, cleanup_apps={"com.test.email": "on"})
    backend_b1 = _StubBackend(RAW_THAI)
    cleanup_b1 = _StubCleanupClient("CLEANED-B1")
    app_b1 = _make_app(
        config_b1,
        lambda: FrontmostApp(bundle_id="com.test.email", name="Mail"),
        backend_b1,
        cleanup_b1,
    )
    rec_b1 = app_b1.process(None, duration_s=1.0, inject=False)
    _check(cleanup_b1.calls == 1, f"worker called once (calls={cleanup_b1.calls})")
    _check(rec_b1.final == "CLEANED-B1", f"final == cleaned text (got {rec_b1.final!r})")
    _check(rec_b1.cleanup_applied == "on", f"cleanup_applied == 'on' (got {rec_b1.cleanup_applied!r})")

    print("\n[3] no per-app entry (absent) -> cleanup runs (global default)")
    config_b2 = OLIVConfig(cleanup_enabled=True, cleanup_apps={})
    backend_b2 = _StubBackend(RAW_THAI)
    cleanup_b2 = _StubCleanupClient("CLEANED-B2")
    app_b2 = _make_app(
        config_b2,
        lambda: FrontmostApp(bundle_id="com.test.other", name="Other"),
        backend_b2,
        cleanup_b2,
    )
    rec_b2 = app_b2.process(None, duration_s=1.0, inject=False)
    _check(cleanup_b2.calls == 1, f"worker called once (calls={cleanup_b2.calls})")
    _check(rec_b2.cleanup_applied == "on", f"cleanup_applied == 'on' (got {rec_b2.cleanup_applied!r})")

    # -- (c) global cleanup_enabled=false wins over the table -----------------
    print("\n[4] global cleanup_enabled=false -> no cleanup regardless of table")
    config_c = OLIVConfig(cleanup_enabled=False, cleanup_apps={"com.test.editor": "off"})
    backend_c = _StubBackend(RAW_THAI)
    app_c = DictationApp(
        config_c,
        cleanup_enabled=False,
        frontmost_fn=lambda: FrontmostApp(bundle_id="com.test.editor", name="Editor"),
    )
    app_c.backend = backend_c
    app_c.cleanup = None  # what build() would leave it as when cleanup_enabled is False
    rec_c = app_c.process(None, duration_s=1.0, inject=False)
    _check(rec_c.final == RAW_THAI, f"final == raw (got {rec_c.final!r})")
    _check(rec_c.cleanup_applied == "off-global", f"cleanup_applied == 'off-global' (got {rec_c.cleanup_applied!r})")
    _check(rec_c.t_cleanup == 0.0, f"t_cleanup == 0.0 (got {rec_c.t_cleanup})")

    # -- (d) unknown mode value dropped, with a warning -----------------------
    print("\n[5] unknown cleanup_apps mode value -> dropped + warned")

    class _CaptureHandler(_logging.Handler):
        def __init__(self) -> None:
            super().__init__()
            self.records: list = []

        def emit(self, record: "_logging.LogRecord") -> None:
            self.records.append(record)

    cap = _CaptureHandler()
    config_logger = _logging.getLogger("oliv.config")
    config_logger.addHandler(cap)
    try:
        bad_config = OLIVConfig(cleanup_apps={"com.test.bad": "maybe"})
    finally:
        config_logger.removeHandler(cap)
    _check(bad_config.cleanup_apps == {}, f"unknown-mode entry dropped (got {bad_config.cleanup_apps!r})")
    warned = any("cleanup_apps" in r.getMessage() and "com.test.bad" in r.getMessage() for r in cap.records)
    _check(warned, "a warning was logged for the unknown mode value")

    # -- (e) frontmost=None -> global (on) behavior ---------------------------
    print("\n[6] frontmost=None -> global behavior (cleanup still runs)")
    config_e = OLIVConfig(cleanup_enabled=True, cleanup_apps={"com.test.editor": "off"})
    backend_e = _StubBackend(RAW_THAI)
    cleanup_e = _StubCleanupClient("CLEANED-E")
    app_e = _make_app(config_e, lambda: None, backend_e, cleanup_e)
    rec_e = app_e.process(None, duration_s=1.0, inject=False)
    _check(cleanup_e.calls == 1, f"worker called (calls={cleanup_e.calls})")
    _check(rec_e.app_bundle_id == "", f"app_bundle_id empty for unknown app (got {rec_e.app_bundle_id!r})")
    _check(rec_e.cleanup_applied == "on", f"cleanup_applied == 'on' (got {rec_e.cleanup_applied!r})")

    # -- (f) records carry app_bundle_id + cleanup_applied --------------------
    print("\n[7] records carry app_bundle_id + cleanup_applied (from cases above)")
    _check(
        all(hasattr(r, "app_bundle_id") and hasattr(r, "cleanup_applied") for r in (rec_a, rec_b1, rec_c, rec_e)),
        "all records expose app_bundle_id + cleanup_applied",
    )

    # -- (g) debug diff line: present iff final != raw ------------------------
    print("\n[8] debug diff line: present iff final != raw")
    _check("diff :" not in rec_a.log_line(), "no diff line when final == raw (bypass case)")

    diff_config = OLIVConfig(cleanup_enabled=True, cleanup_apps={})
    diff_backend = _StubBackend("ผมใช้ ไฟล์จูน กับโมเดลนี้")
    diff_cleanup = _StubCleanupClient("ผมใช้ fine-tune กับโมเดลนี้")
    diff_app = _make_app(
        diff_config, lambda: FrontmostApp(bundle_id="com.test.x", name="X"), diff_backend, diff_cleanup
    )
    rec_diff = diff_app.process(None, duration_s=1.0, inject=False)
    line = rec_diff.log_line()
    _check("diff :" in line, "diff line present when final != raw")
    _check("[-ไฟล์จูน +fine-tune]" in line, f"diff line shows the changed segment (line={line!r})")

    # -- (h) frontmost_fn RAISES -> behaves exactly like it returning None ----
    print("\n[9] frontmost_fn raises -> global behavior, no crash (app_bundle_id stays '')")

    def _boom() -> "FrontmostApp | None":
        raise RuntimeError("frontmost broke")

    config_h = OLIVConfig(cleanup_enabled=True, cleanup_apps={"com.test.editor": "off"})
    backend_h = _StubBackend(RAW_THAI)
    cleanup_h = _StubCleanupClient("CLEANED-H")
    app_h = _make_app(config_h, _boom, backend_h, cleanup_h)
    rec_h = app_h.process(None, duration_s=1.0, inject=False)  # must not raise
    _check(cleanup_h.calls == 1, f"worker called -- global behavior applied (calls={cleanup_h.calls})")
    _check(rec_h.app_bundle_id == "", f"app_bundle_id stays '' for a raising frontmost_fn (got {rec_h.app_bundle_id!r})")
    _check(rec_h.cleanup_applied == "on", f"cleanup_applied == 'on' (got {rec_h.cleanup_applied!r})")

    # -- (i) non-dict cleanup_apps (oliv.toml scalar typo) -> degrades to {}
    print("\n[10] cleanup_apps given as a non-dict scalar (e.g. 'off') -> degrades to {} without raising")
    cap2 = _CaptureHandler()
    config_logger.addHandler(cap2)
    try:
        scalar_config = OLIVConfig(cleanup_apps="off")
    except Exception as exc:
        scalar_config = None
        _check(False, f"OLIVConfig(cleanup_apps='off') must not raise (raised {exc!r})")
    else:
        _check(True, "OLIVConfig(cleanup_apps='off') did not raise")
    finally:
        config_logger.removeHandler(cap2)
    if scalar_config is not None:
        _check(scalar_config.cleanup_apps == {}, f"scalar cleanup_apps degraded to {{}} (got {scalar_config.cleanup_apps!r})")
        warned2 = any("cleanup_apps" in r.getMessage() for r in cap2.records)
        _check(warned2, "a warning was logged for the non-dict cleanup_apps value")

    # -- (j) non-str mode value (TOML boolean typo) dropped, valid entry kept
    print("\n[11] non-str cleanup_apps mode value (e.g. TOML boolean True) -> dropped + warned, valid entry kept")
    cap3 = _CaptureHandler()
    config_logger.addHandler(cap3)
    try:
        bool_config = OLIVConfig(cleanup_apps={"com.test.a": True, "com.test.b": "off"})
    except Exception as exc:
        bool_config = None
        _check(False, f"OLIVConfig(cleanup_apps={{'com.test.a': True, ...}}) must not raise (raised {exc!r})")
    else:
        _check(True, "OLIVConfig(cleanup_apps={'com.test.a': True, ...}) did not raise")
    finally:
        config_logger.removeHandler(cap3)
    if bool_config is not None:
        _check(
            bool_config.cleanup_apps == {"com.test.b": "off"},
            f"boolean entry dropped, valid entry kept (got {bool_config.cleanup_apps!r})",
        )
        warned3 = any("cleanup_apps" in r.getMessage() and "com.test.a" in r.getMessage() for r in cap3.records)
        _check(warned3, "a warning was logged for the non-str mode value")

    # -- (k) bundle-id matching is case-insensitive ---------------------------
    print("\n[12] bundle-id matching is case-insensitive (mixed-case config key vs lowercase frontmost report)")
    config_k = OLIVConfig(cleanup_enabled=True, cleanup_apps={"com.Test.Editor": "off"})
    _check(
        config_k.cleanup_apps == {"com.test.editor": "off"},
        f"cleanup_apps key normalized to lowercase (got {config_k.cleanup_apps!r})",
    )
    backend_k = _StubBackend(RAW_THAI)
    cleanup_k = _StubCleanupClient("SHOULD NOT APPEAR")
    app_k = _make_app(
        config_k,
        lambda: FrontmostApp(bundle_id="com.test.editor", name="Editor"),
        backend_k,
        cleanup_k,
    )
    rec_k = app_k.process(None, duration_s=1.0, inject=False)
    _check(cleanup_k.calls == 0, f"mixed-case config key bypasses lowercase frontmost report (calls={cleanup_k.calls})")
    _check(rec_k.cleanup_applied == "off-per-app", f"cleanup_applied == 'off-per-app' (got {rec_k.cleanup_applied!r})")

    print("\n[12b] bundle-id matching is case-insensitive (lowercase config key vs mixed-case frontmost report)")
    config_k2 = OLIVConfig(cleanup_enabled=True, cleanup_apps={"com.test.editor": "off"})
    backend_k2 = _StubBackend(RAW_THAI)
    cleanup_k2 = _StubCleanupClient("SHOULD NOT APPEAR")
    app_k2 = _make_app(
        config_k2,
        lambda: FrontmostApp(bundle_id="com.Test.Editor", name="Editor"),
        backend_k2,
        cleanup_k2,
    )
    rec_k2 = app_k2.process(None, duration_s=1.0, inject=False)
    _check(cleanup_k2.calls == 0, f"lowercase config key bypasses mixed-case frontmost report (calls={cleanup_k2.calls})")
    _check(rec_k2.cleanup_applied == "off-per-app", f"cleanup_applied == 'off-per-app' (got {rec_k2.cleanup_applied!r})")

    if failures:
        print(f"\n=== cleanup toggle unittest FAIL ({len(failures)} check(s)) ===")
        return 1
    print("\n=== cleanup toggle unittest PASS ===")
    return 0


# ---------------------------------------------------------------------------
# W1-T6 full-pipeline CLI modes (--run / --e2e-file / --e2e-latency)
# ---------------------------------------------------------------------------
# Representative latency clips: a couple mono/gate-skip (fast, LLM bypassed) and
# a few mixed/technical (LLM path exercised), so --e2e-latency covers both the
# gate-skip and the Gemma-4 branches.
_E2E_LATENCY_CLIPS = ["th01", "en02", "mx03", "mx09", "tc01"]


def _load_clip_array(path: Path):
    """Load a WAV as a 16kHz mono float32 numpy array -- proves the same
    array contract the live capture stage hands STT, in-process."""
    import librosa

    raw, _ = librosa.load(str(path), sr=16000, mono=True)
    import numpy as np

    return raw.astype(np.float32, copy=False)


def _resolve_clip(clip: str) -> Path:
    """Map a clip arg (a stem like 'mx03', a filename, or a full path) to a WAV
    Path under benchmark/data/clips/."""
    p = Path(clip)
    if p.is_file():
        return p
    for cand in (SAMPLE_CLIPS_DIR / clip, SAMPLE_CLIPS_DIR / f"{clip}.wav"):
        if cand.is_file():
            return cand
    raise FileNotFoundError(f"clip not found: {clip!r} (looked under {SAMPLE_CLIPS_DIR})")


def _print_run_permissions() -> tuple[bool, bool, bool]:
    """Print mic / Input Monitoring / Accessibility status via the existing
    probes. Returns (mic_ok, can_listen, can_post)."""
    from app.audio import check_microphone_access
    from app.hotkey import check_event_access
    from app.inject import check_post_access

    mic_ok, mic_status = check_microphone_access()
    can_listen, _can_post_ev = check_event_access()
    can_post = check_post_access()
    print(f"  Microphone       (capture):       {mic_status}")
    print(f"  Input Monitoring (hotkey listen):  {'GRANTED' if can_listen else 'MISSING'}")
    print(f"  Accessibility    (paste Cmd+V):    {'GRANTED' if can_post else 'MISSING'}")
    return mic_ok, can_listen, can_post


def _run_dictation(config_path: str | None, backend_override: str | None,
                   no_cleanup: bool, duration: float | None) -> int:
    """--run: the real hold-speak-paste app. Prints resolved config + permission
    status, warms models (reports load times), then runs the push-to-talk
    session until Ctrl-C (or `duration` seconds, for the headless startup
    smoke), and prints a session summary. Cmd+V is only synthesized when a real
    utterance is captured -- a headless run pastes nothing."""
    from app.dictation import DictationApp

    print("=== OLIV dictation (--run) ===\n")
    config = load_config(config_path)
    backend_id = backend_override or config.stt_backend
    cleanup_enabled = config.cleanup_enabled and not no_cleanup

    print("[1/4] Resolved config:")
    print(config.pretty())
    print(f"  -> effective STT backend: {backend_id!r}")
    print(f"  -> cleanup: {'ENABLED (subprocess worker)' if cleanup_enabled else 'DISABLED'}")

    print("\n[2/4] Permissions:")
    _print_run_permissions()

    print(f"\n[3/4] Building + warming (STT {backend_id!r}"
          + (" + cleanup worker" if cleanup_enabled else "") + ") ...")
    app = DictationApp(config, backend_id=backend_id, cleanup_enabled=cleanup_enabled)
    try:
        app.build()
    except Exception as exc:
        print(f"FAIL: could not build STT backend {backend_id!r}: {exc}", file=sys.stderr)
        app.close()
        return 1

    # One try/finally so a Ctrl-C during warm OR run always reaps the worker.
    try:
        app.warm()
        if app._stt_load_time is not None:
            print(f"  STT model load:     {app._stt_load_time:.2f}s")
        else:
            print("  STT model load:     (no separate warm_up; folded into first decode)")
        if cleanup_enabled:
            if app._cleanup_load_time is not None:
                print(f"  cleanup model load: {app._cleanup_load_time:.2f}s")
            else:
                print("  cleanup model load: (warm failed; cleanup will run cold / fall back)")

        print("\n[4/4] Running ...")
        app.run(duration=duration)
    except KeyboardInterrupt:
        print("\n(interrupted during startup)")
    finally:
        app.close()

    print("\n=== session summary ===")
    print(app.summary.pretty())
    print("\n=== dictation done ===")
    return 0


def _run_e2e_file(config_path: str | None, clip: str, backend_override: str | None,
                  no_cleanup: bool) -> int:
    """--e2e-file CLIP: load a benchmark clip as a 16kHz mono array and run it
    through STT -> cleanup (NO inject -- pasting into a background job's focus is
    unsafe). Prints raw STT, cleaned text, the manifest reference, and per-stage
    timings. Proves the STT->cleanup chain end-to-end (in-process STT + worker
    cleanup) without a human speaking."""
    from app.dictation import DictationApp

    print("=== OLIV end-to-end file test (STT -> cleanup, NO inject) ===\n")
    config = load_config(config_path)
    backend_id = backend_override or config.stt_backend
    cleanup_enabled = config.cleanup_enabled and not no_cleanup

    try:
        clip_path = _resolve_clip(clip)
    except FileNotFoundError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    reference = _manifest_reference(clip_path.stem)
    print(f"  clip:      {clip_path}")
    if reference is not None:
        print(f"  reference: {reference!r}")
    print(f"  backend:   {backend_id!r}   cleanup: {'on (worker)' if cleanup_enabled else 'off'}")

    print("\n[1/3] Loading clip as a 16kHz mono float32 array ...")
    audio = _load_clip_array(clip_path)
    print(f"  samples={len(audio)}  duration={len(audio) / 16000:.2f}s")

    print("\n[2/3] Building + warming ...")
    app = DictationApp(config, backend_id=backend_id, cleanup_enabled=cleanup_enabled)
    try:
        app.build()
    except Exception as exc:
        print(f"FAIL: could not build STT backend {backend_id!r}: {exc}", file=sys.stderr)
        return 1
    app.warm()
    if app._stt_load_time is not None:
        print(f"  STT model load:     {app._stt_load_time:.2f}s")
    if cleanup_enabled and app._cleanup_load_time is not None:
        print(f"  cleanup model load: {app._cleanup_load_time:.2f}s")

    print("\n[3/3] STT -> cleanup ...")
    try:
        rec = app.process(audio, duration_s=len(audio) / 16000, inject=False)
    finally:
        app.close()

    print(f"\n  RAW STT : {rec.raw!r}")
    print(f"  CLEANED : {rec.final!r}")
    if reference is not None:
        print(f"  REF     : {reference!r}")
    print(
        f"  timings : t_stt={rec.t_stt * 1000:.0f}ms  t_cleanup={rec.t_cleanup * 1000:.0f}ms"
        f"  llm_ran={rec.llm_ran}  gate={rec.gate_reason or '-'}"
        f"  guardrail={rec.guardrail_flag or '-'}  cleanup_fallback={rec.cleanup_fallback}"
    )
    print(
        f"  app     : {rec.app_bundle_id or '-'}   "  # W2-T3: per-app cleanup toggle
        f"cleanup_applied={rec.cleanup_applied or '-'}"
    )
    if rec.stt_error:
        print(f"  STT ERROR: {rec.stt_error}")
    if rec.cleanup_error:
        print(f"  cleanup fell back: {rec.cleanup_error}")

    # Assert-style transliteration-restore check for the mx03 mixed clip.
    if clip_path.stem == "mx03":
        restored = "fine-tune" in rec.final.lower() and "ไฟล์จูน" not in rec.final
        print(
            f"\n  CHECK[mx03]: transliteration restored "
            f"(ไฟล์จูน -> fine-tune)?  {'YES' if restored else 'NO'}"
        )

    print("\n=== e2e file done ===")
    return 0


def _run_e2e_latency(config_path: str | None, backend_override: str | None) -> int:
    """--e2e-latency: run the STT -> cleanup chain over ~5 representative clips
    (mono/gate-skip + mixed/technical/LLM) and print a per-clip latency table
    plus means. Model load times are reported separately (one-time). This is the
    W1-T6 latency deliverable. NO inject."""
    from app.dictation import DictationApp

    print("=== OLIV end-to-end latency (STT -> cleanup, NO inject) ===\n")
    config = load_config(config_path)
    backend_id = backend_override or config.stt_backend
    cleanup_enabled = config.cleanup_enabled

    clips: list[Path] = []
    for stem in _E2E_LATENCY_CLIPS:
        try:
            clips.append(_resolve_clip(stem))
        except FileNotFoundError:
            print(f"  (skipping missing clip {stem!r})")
    if not clips:
        print("FAIL: no latency clips found", file=sys.stderr)
        return 1

    print(f"  backend: {backend_id!r}   cleanup: {'on (worker)' if cleanup_enabled else 'off'}")
    print(f"  clips:   {', '.join(c.stem for c in clips)}")

    app = DictationApp(config, backend_id=backend_id, cleanup_enabled=cleanup_enabled)
    try:
        app.build()
    except Exception as exc:
        print(f"FAIL: could not build STT backend {backend_id!r}: {exc}", file=sys.stderr)
        return 1

    print("\nWarming (one-time model loads, excluded from per-clip timings) ...")
    app.warm()
    stt_load = f"{app._stt_load_time:.2f}s" if app._stt_load_time is not None else "n/a"
    cln_load = f"{app._cleanup_load_time:.2f}s" if app._cleanup_load_time is not None else "n/a"
    print(f"  STT model load: {stt_load}    cleanup model load: {cln_load}")

    header = (f"  {'clip':<7}{'audio':>7}{'t_stt':>9}{'t_cleanup':>11}"
              f"{'llm':>5}{'t_total':>9}  gate")
    print("\n" + header)
    print("  " + "-" * (len(header) - 2))
    try:
        for clip_path in clips:
            audio = _load_clip_array(clip_path)
            rec = app.process(audio, duration_s=len(audio) / 16000, inject=False)
            print(
                f"  {clip_path.stem:<7}{rec.duration_s:>6.2f}s"
                f"{rec.t_stt * 1000:>8.0f}m"
                f"{rec.t_cleanup * 1000:>10.0f}m"
                f"{'Y' if rec.llm_ran else '-':>5}"
                f"{rec.t_total * 1000:>8.0f}m"
                f"  {rec.gate_reason or '-'}"
            )
    finally:
        app.close()

    s = app.summary
    print("  " + "-" * (len(header) - 2))
    print(
        f"  {'MEAN':<7}{'':>7}{s._mean('t_stt') * 1000:>8.0f}m"
        f"{s._mean('t_cleanup') * 1000:>10.0f}m"
        f"{'':>5}{s._mean('t_total') * 1000:>8.0f}m"
    )
    print("\n  (t_total here = t_stt + t_cleanup; inject is skipped in this mode)")
    print("\n=== e2e latency done ===")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app", description="OLIV prototype CLI")
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="load config, build the mlx-large-v3 STT backend, and transcribe a sample clip",
    )
    parser.add_argument(
        "--stt-test",
        action="store_true",
        help="transcribe thai_only/english_only/mixed sample clips through the configured STT backend",
    )
    parser.add_argument(
        "--backend",
        metavar="ID",
        default=None,
        help="STT backend registry id to use for --stt-test, overriding config's stt_backend "
        "(e.g. mlx-large-v3, pathumma)",
    )
    parser.add_argument(
        "--hotkey-test",
        action="store_true",
        help="interactive push-to-talk listener: print PRESS/RELEASE while you hold the key",
    )
    parser.add_argument(
        "--hotkey-selftest",
        action="store_true",
        help="automated hotkey check via synthetic events (exit 2 if OS access not yet granted)",
    )
    parser.add_argument(
        "--hotkey-unittest",
        action="store_true",
        help="drive the hotkey state machine directly (no OS events / no permissions needed)",
    )
    parser.add_argument(
        "--audio-test",
        action="store_true",
        help="probe mic permission, record --seconds, print capture stats, save a WAV",
    )
    parser.add_argument(
        "--audio-e2e",
        action="store_true",
        help="record --seconds and hand the array straight to the mlx-large-v3 STT backend",
    )
    parser.add_argument(
        "--audio-unittest",
        action="store_true",
        help="Recorder repeated-cycle + misuse checks (no OS permission dialog required)",
    )
    parser.add_argument(
        "--ptt-test",
        action="store_true",
        help="wire PushToTalkListener to Recorder (+ STT): hold the hotkey to dictate",
    )
    parser.add_argument(
        "--inject-test",
        action="store_true",
        help="paste-at-cursor test: set clipboard + synthesize Cmd+V (exit 2 if Accessibility not granted)",
    )
    parser.add_argument(
        "--clipboard-unittest",
        action="store_true",
        help="automated clipboard fidelity + save/restore + inject-path checks (no OS permissions; leaves clipboard as found)",
    )
    parser.add_argument(
        "--frontmost-test",
        action="store_true",
        help="print the detected frontmost app (bundle id + name) once per second for ~5s",
    )
    parser.add_argument(
        "--cleanup-toggle-unittest",
        action="store_true",
        help="hermetic per-app cleanup toggle checks (stub backend + stub cleanup client, no OS permissions)",
    )
    parser.add_argument(
        "--run",
        action="store_true",
        help="the real hold-speak-paste app: capture -> STT -> cleanup -> paste (Ctrl-C to quit)",
    )
    parser.add_argument(
        "--e2e-file",
        metavar="CLIP",
        default=None,
        help="headless E2E: run one benchmark clip (e.g. mx03) through STT -> cleanup, NO inject",
    )
    parser.add_argument(
        "--e2e-latency",
        action="store_true",
        help="latency table: STT -> cleanup over ~5 representative clips (W1-T6 deliverable), NO inject",
    )
    parser.add_argument(
        "--no-cleanup",
        action="store_true",
        help="disable the cleanup stage for --run / --e2e-file (skip the CleanupClient worker)",
    )
    parser.add_argument(
        "--text",
        metavar="TEXT",
        default=None,
        help="text for --inject-test (default: a Thai+English+emoji demo string)",
    )
    parser.add_argument(
        "--seconds",
        metavar="SECONDS",
        type=float,
        default=None,
        help="seconds to record: --audio-test default 12, --audio-e2e default 8",
    )
    parser.add_argument(
        "--duration",
        metavar="SECONDS",
        type=float,
        default=None,
        help="seconds to listen: --hotkey-test default 15, --ptt-test default 20",
    )
    parser.add_argument(
        "--config",
        metavar="PATH",
        default=None,
        help="path to oliv.toml (default: <project root>/oliv.toml; missing file = defaults)",
    )
    args = parser.parse_args(argv)

    if args.selftest:
        try:
            return _run_selftest(args.config)
        except Exception as exc:  # last-resort catch-all so failures are always clear + nonzero
            print(f"FAIL: unexpected error during selftest: {exc!r}", file=sys.stderr)
            return 1

    if args.stt_test:
        try:
            return _run_stt_test(args.config, args.backend)
        except Exception as exc:
            print(f"FAIL: unexpected error during stt test: {exc!r}", file=sys.stderr)
            return 1

    if args.hotkey_test:
        try:
            return _run_hotkey_test(args.config, args.duration if args.duration is not None else 15.0)
        except Exception as exc:
            print(f"FAIL: unexpected error during hotkey test: {exc!r}", file=sys.stderr)
            return 1

    if args.hotkey_selftest:
        try:
            return _run_hotkey_selftest(args.config)
        except Exception as exc:
            print(f"FAIL: unexpected error during hotkey selftest: {exc!r}", file=sys.stderr)
            return 1

    if args.hotkey_unittest:
        try:
            return _run_hotkey_unittest()
        except Exception as exc:
            print(f"FAIL: unexpected error during hotkey unittest: {exc!r}", file=sys.stderr)
            return 1

    if args.audio_test:
        try:
            return _run_audio_test(args.seconds if args.seconds is not None else 12.0)
        except Exception as exc:
            print(f"FAIL: unexpected error during audio test: {exc!r}", file=sys.stderr)
            return 1

    if args.audio_e2e:
        try:
            return _run_audio_e2e(args.seconds if args.seconds is not None else 8.0)
        except Exception as exc:
            print(f"FAIL: unexpected error during audio e2e test: {exc!r}", file=sys.stderr)
            return 1

    if args.audio_unittest:
        try:
            return _run_audio_unittest()
        except Exception as exc:
            print(f"FAIL: unexpected error during audio unittest: {exc!r}", file=sys.stderr)
            return 1

    if args.ptt_test:
        try:
            return _run_ptt_test(args.config, args.duration if args.duration is not None else 20.0)
        except Exception as exc:
            print(f"FAIL: unexpected error during ptt test: {exc!r}", file=sys.stderr)
            return 1

    if args.inject_test:
        try:
            return _run_inject_test(args.config, args.text)
        except Exception as exc:
            print(f"FAIL: unexpected error during inject test: {exc!r}", file=sys.stderr)
            return 1

    if args.clipboard_unittest:
        try:
            return _run_clipboard_unittest()
        except Exception as exc:
            print(f"FAIL: unexpected error during clipboard unittest: {exc!r}", file=sys.stderr)
            return 1

    if args.frontmost_test:
        try:
            return _run_frontmost_test()
        except Exception as exc:
            print(f"FAIL: unexpected error during frontmost test: {exc!r}", file=sys.stderr)
            return 1

    if args.cleanup_toggle_unittest:
        try:
            return _run_cleanup_toggle_unittest()
        except Exception as exc:
            print(f"FAIL: unexpected error during cleanup toggle unittest: {exc!r}", file=sys.stderr)
            return 1

    if args.run:
        try:
            return _run_dictation(args.config, args.backend, args.no_cleanup, args.duration)
        except Exception as exc:
            print(f"FAIL: unexpected error during --run: {exc!r}", file=sys.stderr)
            return 1

    if args.e2e_file:
        try:
            return _run_e2e_file(args.config, args.e2e_file, args.backend, args.no_cleanup)
        except Exception as exc:
            print(f"FAIL: unexpected error during --e2e-file: {exc!r}", file=sys.stderr)
            return 1

    if args.e2e_latency:
        try:
            return _run_e2e_latency(args.config, args.backend)
        except Exception as exc:
            print(f"FAIL: unexpected error during --e2e-latency: {exc!r}", file=sys.stderr)
            return 1

    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
