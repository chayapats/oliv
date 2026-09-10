#!/usr/bin/env python3
"""Fair Wispr Flow loopback eval against OLIV's existing clip set.

Why this is the fairest practical comparison
--------------------------------------------
OLIV's shipped numbers (e.g. ``eval_results/ship_hold.json``) feed the *same*
WAV bytes straight into the pipeline — no room, no mic colouring.

Wispr's consumer app has no file-upload path, so the closest equivalent is a
**digital** Core Audio loopback (BlackHole): play the identical PCM into a
virtual output while Wispr's input is that same virtual device. No speakers,
no room reverb, no second mic.

Do NOT play through laptop speakers into the built-in mic — that unfairly
hurts Wispr and is not comparable to OLIV's file eval.

Fairness checklist (run before scoring)
---------------------------------------
1. Install BlackHole 2ch; set **Wispr input** = BlackHole 2ch.
2. Playback targets BlackHole only (this script does that). Do not also route
   to speakers during an official run (feedback / AEC can distort).
3. Wispr settings for the scored run (write them into ``--notes``):
   - AI cleanup: pick ONE level and keep it. Recommended primary:
     the product default / Medium (OLIV also runs a cleanup pass).
   - Clear personal dictionary; disable auto-learn if the UI allows.
   - No snippets / tone styles / team dictionary.
   - Language: Auto (or Thai if Auto mis-detects on your account).
4. Do not edit Wispr's output to match the reference. Retries only for
   hard failures (no paste, network error) — the script logs retry count.
5. Score with the same metric as OLIV::

       benchmark/.venv/bin/python benchmark/semantic_score.py

   Compare the new ``eval_results/wispr_holdout_*.json`` against
   ``ship_hold.json`` (same holdout clips).

Typical session
---------------
    # once:
    brew install blackhole-2ch          # or install from existential.audio
    # In Wispr: set microphone / input to "BlackHole 2ch"
    # Open TextEdit (or any empty text field) and leave it frontmost for paste.

    benchmark/.venv/bin/python benchmark/wispr_loopback_eval.py setup
    benchmark/.venv/bin/python benchmark/wispr_loopback_eval.py run \\
        --manifest data/manifest_holdout.jsonl \\
        --device "BlackHole 2ch" \\
        --notes "cleanup=Medium dict=empty lang=Auto"

    # after the run (or use --export during run — export is automatic):
    benchmark/.venv/bin/python benchmark/semantic_score.py
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import metrics  # noqa: E402

CAPTURE_DIR = ROOT / "eval_results" / "wispr_captures"
DEFAULT_MANIFEST = ROOT / "data" / "manifest_holdout.jsonl"
DEFAULT_AUDIO_ROOT = ROOT / "data"
DEFAULT_DEVICE_CANDIDATES = (
    "BlackHole 2ch",
    "BlackHole 16ch",
    "BlackHole",
)


def bucket_of(cid: str) -> str:
    m = re.match(r"[a-z]+", cid)
    return m.group() if m else cid


def _norm_lines(s: str) -> str:
    """Same exact-match norm as eval_cleanup.py (keeps newlines for fm clips)."""
    lines = [ln.strip() for ln in s.replace("\u200b", "").split("\n")]
    return "\n".join(lines).strip().lower()


def load_manifest(path: Path, audio_root: Path) -> list[dict]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        r = json.loads(line)
        r["_abspath"] = str((audio_root / r["path"]).resolve())
        rows.append(r)
    return rows


def list_profiler_audio_devices() -> list[str]:
    """Device names from system_profiler (inputs + outputs)."""
    try:
        sp = subprocess.run(
            ["system_profiler", "SPAudioDataType", "-json"],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return []
    if sp.returncode != 0 or not (sp.stdout or "").strip():
        # plain-text fallback: lines that look like "Device Name:"
        sp2 = subprocess.run(
            ["system_profiler", "SPAudioDataType"],
            capture_output=True, text=True, check=False,
        )
        names = []
        for line in (sp2.stdout or "").splitlines():
            if line.startswith("        ") and line.endswith(":") and not line.startswith("            "):
                names.append(line.strip().rstrip(":"))
        return names
    try:
        data = json.loads(sp.stdout)
    except json.JSONDecodeError:
        return []
    names: list[str] = []
    for item in data.get("SPAudioDataType", []):
        # macOS shapes vary; collect every dict key that looks like a device
        for key, val in item.items():
            if key in ("_name", "name"):
                continue
            if isinstance(val, dict) and (
                "coreaudio_device_input" in val
                or "coreaudio_device_output" in val
                or "coreaudio_input_source" in val
                or "coreaudio_output_source" in val
                or "coreaudio_default_audio_input_device" in val
                or "coreaudio_default_audio_output_device" in val
            ):
                names.append(key)
            elif isinstance(val, dict) and any(
                k.startswith("coreaudio_") for k in val
            ):
                names.append(key)
    # Also walk items that use _name
    def walk(obj):
        if isinstance(obj, dict):
            n = obj.get("_name")
            if n and any(k.startswith("coreaudio_") for k in obj):
                names.append(str(n))
            for v in obj.values():
                walk(v)
        elif isinstance(obj, list):
            for v in obj:
                walk(v)
    walk(data)
    # dedupe preserve order
    seen = set()
    out = []
    for n in names:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out


def list_avfoundation_audio_devices() -> list[str]:
    """Input device names from ffmpeg avfoundation listing (stderr)."""
    if not shutil.which("ffmpeg"):
        return []
    proc = subprocess.run(
        ["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
        capture_output=True, text=True,
    )
    text = (proc.stderr or "") + (proc.stdout or "")
    names: list[str] = []
    in_audio = False
    for line in text.splitlines():
        if "AVFoundation audio devices" in line:
            in_audio = True
            continue
        if in_audio and "AVFoundation video devices" in line:
            break
        if not in_audio:
            continue
        # "...] [0] MacBook Pro Microphone"
        m = re.search(r"\]\s+\[(\d+)\]\s+(.+)$", line)
        if not m:
            m = re.search(r"\[(\d+)\]\s+(.+)$", line)
        if m:
            names.append(m.group(2).strip())
    return names


def list_audio_devices() -> list[str]:
    """Union of profiler + avfoundation names (order: BlackHole first if present)."""
    seen = set()
    out: list[str] = []
    for n in list_profiler_audio_devices() + list_avfoundation_audio_devices():
        if n not in seen:
            seen.add(n)
            out.append(n)
    out.sort(key=lambda s: (0 if "blackhole" in s.lower() else 1, s.lower()))
    return out


def find_blackhole(preferred: str | None) -> str | None:
    devices = list_audio_devices()
    if preferred:
        if not devices or preferred in devices:
            return preferred
        for d in devices:
            if preferred.lower() in d.lower():
                return d
        return preferred  # still try; ffmpeg may accept it
    for cand in DEFAULT_DEVICE_CANDIDATES:
        for d in devices:
            if cand.lower() in d.lower():
                return d
    for d in devices:
        if "blackhole" in d.lower():
            return d
    return None


def pad_wav(src: Path, dst: Path, pre_s: float, post_s: float) -> None:
    """Concatenate leading/trailing digital silence — no gain / resample."""
    with wave.open(str(src), "rb") as r:
        params = r.getparams()
        frames = r.readframes(r.getnframes())
        rate = r.getframerate()
        width = r.getsampwidth()
        ch = r.getnchannels()
    pre_n = max(0, int(round(rate * pre_s)))
    post_n = max(0, int(round(rate * post_s)))
    silence_frame = b"\x00" * (width * ch)
    padded = (silence_frame * pre_n) + frames + (silence_frame * post_n)
    with wave.open(str(dst), "wb") as w:
        w.setparams(params)
        w.writeframes(padded)


def play_to_device(wav_path: Path, device: str) -> None:
    """Play WAV into a Core Audio device with a bit-transparent path.

    Preferred: temporarily set the system **output** to ``device`` and ``afplay``
    the file (works on stock macOS / Homebrew ffmpeg without coreaudio muxer).
    Falls back to ``ffmpeg -f coreaudio`` when SwitchAudioSource is missing.
    """
    switch = shutil.which("SwitchAudioSource")
    if switch and shutil.which("afplay"):
        before = subprocess.check_output(
            [switch, "-c", "-t", "output"], text=True
        ).strip()
        try:
            set_p = subprocess.run(
                [switch, "-t", "output", "-s", device],
                capture_output=True, text=True,
            )
            if set_p.returncode != 0:
                raise RuntimeError(
                    f"Cannot set output to {device!r}: "
                    f"{(set_p.stderr or set_p.stdout or '').strip()}"
                )
            play = subprocess.run(
                ["afplay", str(wav_path)],
                capture_output=True, text=True,
            )
            if play.returncode != 0:
                raise RuntimeError(
                    f"afplay failed: {(play.stderr or play.stdout or '').strip()}"
                )
        finally:
            subprocess.run(
                [switch, "-t", "output", "-s", before],
                capture_output=True, text=True,
            )
        return

    if not shutil.which("ffmpeg"):
        raise SystemExit(
            "Need SwitchAudioSource+afplay (brew install switchaudio-osx) "
            "or an ffmpeg build with coreaudio output."
        )
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-i", str(wav_path),
        "-f", "coreaudio", device,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(
            f"ffmpeg playback to {device!r} failed (exit {proc.returncode}).\n"
            f"{err}\n\n"
            "Fix: brew install switchaudio-osx blackhole-2ch, then re-run."
        )


def key_event(keycode: int, down: bool) -> None:
    """Post a HID keyboard event (Carbon keycode). Needs Accessibility."""
    import ctypes
    from ctypes import c_bool, c_uint32, c_void_p

    cg = ctypes.CDLL(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    )
    create = cg.CGEventCreateKeyboardEvent
    create.restype = c_void_p
    create.argtypes = [c_void_p, c_uint32, c_bool]
    post = cg.CGEventPost
    post.argtypes = [c_uint32, c_void_p]
    release = ctypes.CDLL(
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    ).CFRelease
    release.argtypes = [c_void_p]
    ev = create(None, c_uint32(keycode), c_bool(down))
    if not ev:
        raise RuntimeError("CGEventCreateKeyboardEvent failed")
    post(0, ev)  # kCGHIDEventTap
    release(ev)


def wispr_latest_history(db_path: Path, after_ts: str | None = None) -> dict | None:
    """Read the newest Wispr History row (formattedText preferred)."""
    import sqlite3
    if not db_path.is_file():
        return None
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        con.row_factory = sqlite3.Row
        if after_ts:
            row = con.execute(
                "SELECT formattedText, asrText, timestamp, e2eLatency, micDevice "
                "FROM History WHERE timestamp > ? "
                "ORDER BY timestamp DESC LIMIT 1",
                (after_ts,),
            ).fetchone()
        else:
            row = con.execute(
                "SELECT formattedText, asrText, timestamp, e2eLatency, micDevice "
                "FROM History ORDER BY timestamp DESC LIMIT 1"
            ).fetchone()
        return dict(row) if row else None
    finally:
        con.close()


def wispr_history_max_ts(db_path: Path) -> str | None:
    import sqlite3
    if not db_path.is_file():
        return None
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        row = con.execute("SELECT MAX(timestamp) FROM History").fetchone()
        return row[0] if row else None
    finally:
        con.close()


def pbpaste() -> str:
    return subprocess.check_output(["pbpaste"], text=True)


def pbcopy(text: str) -> None:
    subprocess.run(["pbcopy"], input=text, text=True, check=True)


def applescript(script: str) -> str:
    proc = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "osascript failed")
    return (proc.stdout or "").rstrip("\n")


def frontmost_select_all_copy() -> str:
    """Cmd+A / Cmd+C in the frontmost app, then read the clipboard."""
    # Small settle so Wispr can finish injecting before we select.
    script = '''
    tell application "System Events"
        keystroke "a" using command down
        delay 0.08
        keystroke "c" using command down
    end tell
    '''
    applescript(script)
    time.sleep(0.15)
    return pbpaste()


def capture_path_for(run_id: str) -> Path:
    CAPTURE_DIR.mkdir(parents=True, exist_ok=True)
    return CAPTURE_DIR / f"{run_id}.jsonl"


def load_captures(path: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        out[row["id"]] = row
    return out


def append_capture(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def rewrite_captures(path: Path, by_id: dict[str, dict], order: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for cid in order:
            if cid in by_id:
                f.write(json.dumps(by_id[cid], ensure_ascii=False) + "\n")


def export_eval_json(
    *,
    captures: dict[str, dict],
    manifest_rows: list[dict],
    out_path: Path,
    label: str,
    notes: str,
    device: str,
    manifest_path: Path,
) -> Path:
    clips = []
    by_bucket: dict[str, list[dict]] = defaultdict(list)
    for row in manifest_rows:
        cap = captures.get(row["id"])
        if not cap or not cap.get("final"):
            continue
        final = cap["final"]
        ref = row["reference"]
        sc = metrics.score(ref, final, row.get("keywords"))
        b = row.get("bucket") or bucket_of(row["id"])
        clip = {
            "id": row["id"],
            "bucket": b,
            "difficulty": row.get("difficulty"),
            "reference": ref,
            "raw": final,   # Wispr app exposes only the polished paste
            "final": final,
            "exact": _norm_lines(ref) == _norm_lines(final),
            "wer": round(sc.wer_newmm, 4),
            "kw_recall": None if sc.keyword_recall is None else round(sc.keyword_recall, 3),
            "llm_ran": None,
            "guardrail": "wispr-app",
            "fillers_removed": None,
            "format_commands_fired": None,
            "replacements_fired": None,
            "latency_s": cap.get("latency_s"),
            "retries": cap.get("retries", 0),
        }
        clips.append(clip)
        by_bucket[b].append(clip)

    def agg(xs: list[dict]) -> dict:
        n = len(xs)
        return {
            "n": n,
            "exact_pct": round(100.0 * sum(1 for c in xs if c["exact"]) / n, 1) if n else 0.0,
            "mean_wer": round(sum(c["wer"] for c in xs) / n, 4) if n else 0.0,
            "mean_latency_s": round(
                sum(c["latency_s"] for c in xs if c.get("latency_s") is not None)
                / max(1, sum(1 for c in xs if c.get("latency_s") is not None)),
                3,
            ) if any(c.get("latency_s") is not None for c in xs) else None,
        }

    payload = {
        "label": label,
        "engine": "wispr-flow-app",
        "cleanup_model": notes or "wispr-app-default",
        "manifest": str(manifest_path.resolve()),
        "no_vocab": True,
        "protocol": {
            "kind": "digital_loopback",
            "device": device,
            "notes": notes,
            "fairness": (
                "Identical WAV PCM as OLIV file eval, played into BlackHole; "
                "Wispr mic = same device. No speaker→mic path."
            ),
        },
        "overall": agg(clips),
        "aggregate": {b: agg(xs) for b, xs in sorted(by_bucket.items())},
        "clips": clips,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return out_path


def cmd_devices(_: argparse.Namespace) -> int:
    names = list_audio_devices()
    if not names:
        print("Could not list audio devices.")
        print("Open System Settings → Sound and look for BlackHole.")
        return 1
    print("Audio devices (system_profiler + avfoundation):")
    for i, n in enumerate(names):
        mark = "  ← use this" if "blackhole" in n.lower() else ""
        print(f"  [{i}] {n}{mark}")
    found = find_blackhole(None)
    print()
    if found and "blackhole" in found.lower():
        print(f"Suggested --device {found!r}")
        print("Also set Wispr's microphone/input to that exact name.")
        return 0
    print("BlackHole not detected yet.")
    print("  brew install blackhole-2ch")
    print("  # or https://existential.audio/blackhole/")
    print("  Then re-login / reboot if it does not appear, and re-run: devices")
    return 2


def cmd_setup(_: argparse.Namespace) -> int:
    print("""Fair Wispr ↔ OLIV loopback setup
================================

1) Install virtual audio device
   brew install blackhole-2ch
   # reboot / re-login if the device does not appear

2) Wire Wispr to the virtual mic
   Wispr Flow → Settings → Microphone / Input → "BlackHole 2ch"
   (name must match `python benchmark/wispr_loopback_eval.py devices`)

3) Wispr fairness settings (write into --notes when you run)
   - Cleanup level: ONE choice for the whole run (recommend product default/Medium)
   - Clear personal dictionary; turn off auto-learn if available
   - Disable snippets / per-app tone
   - Language: Auto

4) Prepare a paste target
   Open TextEdit with a blank document and keep it frontmost while scoring.
   This script will Cmd+A / Cmd+C after each clip to read the paste.

5) What NOT to do
   - Do not play through speakers into the Mac mic
   - Do not manually "fix" transcripts to match the reference
   - Do not change Wispr settings mid-run

6) Run holdout (40 clips) first
   cd benchmark
   .venv/bin/python wispr_loopback_eval.py run \\
     --manifest data/manifest_holdout.jsonl \\
     --device "BlackHole 2ch" \\
     --notes "cleanup=Medium dict=empty lang=Auto"

7) Score with the same metric as OLIV
   .venv/bin/python semantic_score.py
   # compare wispr_holdout_* vs ship_hold in _semantic.json

Why this matches OLIV fairly
  OLIV holdout numbers use the same WAV files via wav_path (no mic).
  This harness plays those same files digitally into Wispr's input device.
""")
    rc = cmd_devices(_)
    return 0 if rc in (0, 2) else rc


def cmd_run(args: argparse.Namespace) -> int:
    manifest = Path(args.manifest)
    if not manifest.is_absolute():
        manifest = (ROOT / manifest).resolve()
    audio_root = Path(args.audio_root)
    if not audio_root.is_absolute():
        audio_root = (ROOT / audio_root).resolve()

    device = args.device or find_blackhole(None)
    if not device:
        print("No BlackHole device found. Run: python wispr_loopback_eval.py setup")
        return 2

    rows = load_manifest(manifest, audio_root)
    missing = [r["id"] for r in rows if not Path(r["_abspath"]).is_file()]
    if missing:
        print(f"Missing {len(missing)} wav(s), e.g. {missing[:5]}")
        return 1

    run_id = args.run_id or datetime.now(timezone.utc).strftime("wispr_holdout_%Y%m%d_%H%M%S")
    cap_path = Path(args.captures) if args.captures else capture_path_for(run_id)
    done = load_captures(cap_path)
    order = [r["id"] for r in rows]

    out_json = Path(args.out) if args.out else (
        ROOT / "eval_results" / f"{run_id}.json"
    )
    if not out_json.is_absolute():
        out_json = (ROOT / out_json).resolve()

    print("=" * 60)
    print("Wispr digital-loopback eval")
    print(f"  manifest : {manifest}")
    print(f"  clips    : {len(rows)} ({len(done)} already captured)")
    print(f"  device   : {device}")
    print(f"  captures : {cap_path}")
    print(f"  export   : {out_json}")
    print(f"  notes    : {args.notes or '(none — please set --notes)'}")
    print("=" * 60)
    print("""
Before each clip:
  1. Focus your empty TextEdit (or paste target)
  2. Hold Wispr push-to-talk
  3. Press Enter here — audio plays (you will NOT hear it; that's correct)
  4. Release Wispr after the play finishes (script will cue you)
  5. Wait for paste, then confirm / edit only for capture glitches
""")
    if not args.yes:
        input("Press Enter when Wispr input is BlackHole and TextEdit is ready… ")

    # Probe playback once with 200ms silence so failures are loud early.
    if not args.skip_probe:
        print(f"\nProbing playback → {device!r} …")
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            probe = Path(tmp.name)
        try:
            # 48k stereo silence 0.2s — matches clip format
            with wave.open(str(probe), "wb") as w:
                w.setnchannels(2)
                w.setsampwidth(2)
                w.setframerate(48000)
                w.writeframes(b"\x00\x00" * 2 * 9600)
            play_to_device(probe, device)
            print("Probe OK.\n")
        except Exception as exc:
            print(f"Probe FAILED: {exc}")
            return 1
        finally:
            probe.unlink(missing_ok=True)

    for idx, row in enumerate(rows, 1):
        cid = row["id"]
        if cid in done and not args.overwrite:
            print(f"[{idx}/{len(rows)}] {cid} — skip (already captured)")
            continue

        wav = Path(row["_abspath"])
        print("-" * 60)
        print(f"[{idx}/{len(rows)}] {cid}  bucket={row.get('bucket') or bucket_of(cid)}")
        if args.show_reference:
            print(f"  REF (do not chase this while capturing): {row['reference']!r}")
        else:
            print("  REF hidden (fair mode). Pass --show-reference to peek.")

        retries = 0
        while True:
            # Clear paste target content so Cmd+A copies only this utterance.
            if not args.no_clear:
                try:
                    # Select-all + delete in frontmost app
                    applescript('''
                    tell application "System Events"
                        keystroke "a" using command down
                        delay 0.05
                        key code 51
                    end tell
                    ''')
                    time.sleep(0.1)
                except Exception as exc:
                    print(f"  (clear skipped: {exc})")

            pbcopy("")  # sentinel
            input("  Hold Wispr PTT, then press Enter to play… ")

            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                padded = Path(tmp.name)
            t0 = time.perf_counter()
            try:
                pad_wav(wav, padded, args.pre_s, args.post_s)
                play_to_device(padded, device)
            finally:
                padded.unlink(missing_ok=True)

            print("  >>> RELEASE Wispr now — waiting for paste …")
            time.sleep(args.settle_s)
            latency = round(time.perf_counter() - t0, 3)

            try:
                text = frontmost_select_all_copy().strip()
            except Exception as exc:
                print(f"  auto-copy failed ({exc}); falling back to clipboard.")
                text = pbpaste().strip()

            print(f"  GOT ({latency}s): {text!r}")
            action = input(
                "  [Enter]=accept  e=type/paste manually  r=retry  s=skip > "
            ).strip().lower()
            if action == "r":
                retries += 1
                continue
            if action == "s":
                print("  skipped")
                break
            if action == "e":
                print("  Paste/type the Wispr text, then press Enter:")
                # Read a single line; for multi-line fm clips allow \\n escapes
                manual = input("  > ")
                text = manual.replace("\\n", "\n").strip()
                if not text:
                    print("  empty — retrying")
                    retries += 1
                    continue
            if not text:
                print("  empty capture — retrying (count as retry)")
                retries += 1
                continue

            rec = {
                "id": cid,
                "final": text,
                "latency_s": latency,
                "retries": retries,
                "device": device,
                "notes": args.notes,
                "ts": datetime.now(timezone.utc).isoformat(),
                "wav": row["path"],
            }
            # Replace prior line for this id if overwrite
            done[cid] = rec
            rewrite_captures(cap_path, done, order)
            export_eval_json(
                captures=done,
                manifest_rows=rows,
                out_path=out_json,
                label=args.label or run_id,
                notes=args.notes or "",
                device=device,
                manifest_path=manifest,
            )
            print(f"  saved → {cap_path.name}  ({len(done)}/{len(rows)})")
            break

    export_eval_json(
        captures=done,
        manifest_rows=rows,
        out_path=out_json,
        label=args.label or run_id,
        notes=args.notes or "",
        device=device,
        manifest_path=manifest,
    )
    print()
    print(f"Done. Captured {len(done)}/{len(rows)}.")
    print(f"Eval JSON: {out_json}")
    print("Score:  benchmark/.venv/bin/python benchmark/semantic_score.py")
    print("Compare config keys: ship_hold  vs ", out_json.stem)
    return 0


def ensure_system_input(device: str) -> str | None:
    """Point macOS default input at BlackHole; return previous name."""
    switch = shutil.which("SwitchAudioSource")
    if not switch:
        return None
    before = subprocess.check_output(
        [switch, "-c", "-t", "input"], text=True
    ).strip()
    subprocess.run([switch, "-t", "input", "-s", device], check=False)
    return before


def cmd_auto(args: argparse.Namespace) -> int:
    """Hold Wispr PTT via HID keycode, play clip into BlackHole, read History DB."""
    manifest = Path(args.manifest)
    if not manifest.is_absolute():
        manifest = (ROOT / manifest).resolve()
    audio_root = Path(args.audio_root)
    if not audio_root.is_absolute():
        audio_root = (ROOT / audio_root).resolve()

    device = args.device or find_blackhole(None)
    if not device:
        print("No BlackHole device found.")
        return 2

    rows = load_manifest(manifest, audio_root)
    if args.limit and args.limit > 0:
        rows = rows[: args.limit]
    missing = [r["id"] for r in rows if not Path(r["_abspath"]).is_file()]
    if missing:
        print(f"Missing {len(missing)} wav(s), e.g. {missing[:5]}")
        return 1

    db = Path(args.history_db).expanduser()
    run_id = args.run_id or datetime.now(timezone.utc).strftime("wispr_holdout_%Y%m%d_%H%M%S")
    cap_path = Path(args.captures) if args.captures else capture_path_for(run_id)
    done = load_captures(cap_path)
    order = [r["id"] for r in load_manifest(manifest, audio_root)]
    out_json = Path(args.out) if args.out else (ROOT / "eval_results" / f"{run_id}.json")
    if not out_json.is_absolute():
        out_json = (ROOT / out_json).resolve()

    ptt = int(args.ptt_keycode)
    prev_input = ensure_system_input(device)

    # Focus paste target
    if not args.no_textedit:
        subprocess.run(["open", "-a", "TextEdit"], check=False)
        time.sleep(0.4)
        try:
            applescript('''
            tell application "TextEdit"
              activate
              if (count of documents) = 0 then make new document
            end tell
            ''')
        except Exception as exc:
            print(f"(TextEdit focus soft-fail: {exc})")

    print("=" * 60)
    print("Wispr AUTO digital-loopback eval")
    print(f"  clips     : {len(rows)} (resume {len(done)})")
    print(f"  device    : {device}")
    print(f"  PTT key   : Carbon {ptt} (Wispr default Right Shift = 60)")
    print(f"  history db: {db}")
    print(f"  notes     : {args.notes}")
    print("=" * 60)
    print("REQUIREMENT: Wispr mic = BlackHole 2ch OR Auto-detect with")
    print("system input already set to BlackHole.")
    if not args.yes:
        input("Press Enter to start auto run… ")

    # Probe playback
    print(f"\nProbing afplay → {device!r} …")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        probe = Path(tmp.name)
    try:
        with wave.open(str(probe), "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(48000)
            w.writeframes(b"\x00\x00" * 2 * 4800)
        play_to_device(probe, device)
        print("Probe OK.\n")
    except Exception as exc:
        print(f"Probe FAILED: {exc}")
        return 1
    finally:
        probe.unlink(missing_ok=True)

    try:
        for idx, row in enumerate(rows, 1):
            cid = row["id"]
            if cid in done and not args.overwrite:
                print(f"[{idx}/{len(rows)}] {cid} — skip")
                continue

            wav = Path(row["_abspath"])
            print("-" * 60)
            print(f"[{idx}/{len(rows)}] {cid}")

            # Clear TextEdit body so paste is unambiguous
            if not args.no_clear:
                try:
                    applescript('''
                    tell application "TextEdit" to activate
                    delay 0.05
                    tell application "System Events"
                      keystroke "a" using command down
                      delay 0.05
                      key code 51
                    end tell
                    ''')
                except Exception:
                    pass

            before_ts = wispr_history_max_ts(db)
            retries = 0
            text = ""
            latency = None
            while retries <= args.max_retries:
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                    padded = Path(tmp.name)
                t0 = time.perf_counter()
                try:
                    pad_wav(wav, padded, args.pre_s, args.post_s)
                    key_event(ptt, True)
                    time.sleep(0.12)  # arm PTT before speech
                    play_to_device(padded, device)
                finally:
                    try:
                        key_event(ptt, False)
                    except Exception:
                        pass
                    padded.unlink(missing_ok=True)

                # Poll Wispr History for a new row
                deadline = time.time() + args.settle_s
                hist = None
                while time.time() < deadline:
                    time.sleep(0.35)
                    hist = wispr_latest_history(db, after_ts=before_ts)
                    if hist and (hist.get("formattedText") or hist.get("asrText")):
                        break

                latency = round(time.perf_counter() - t0, 3)
                if hist:
                    text = (hist.get("formattedText") or hist.get("asrText") or "").strip()
                    mic = hist.get("micDevice")
                    print(f"  hist mic={mic!r} lat={latency}s → {text!r}")
                    if text:
                        break
                elif not args.no_textedit:
                    # Clipboard / TextEdit fallback only in interactive paste-target mode.
                    try:
                        text = frontmost_select_all_copy().strip()
                    except Exception:
                        text = pbpaste().strip()
                    print(f"  fallback clipboard lat={latency}s → {text!r}")
                    if text:
                        break
                else:
                    print(f"  no History row yet lat={latency}s (no-clipboard mode)")

                retries += 1
                print(f"  empty — retry {retries}/{args.max_retries}")
                before_ts = wispr_history_max_ts(db)

            if not text:
                print(f"  FAILED {cid}: no transcript after retries")
                if args.fail_fast:
                    return 3
                continue

            done[cid] = {
                "id": cid,
                "final": text,
                "latency_s": latency,
                "retries": retries,
                "device": device,
                "notes": args.notes,
                "ts": datetime.now(timezone.utc).isoformat(),
                "wav": row["path"],
                "source": "wispr-history",
            }
            rewrite_captures(cap_path, done, order)
            export_eval_json(
                captures=done,
                manifest_rows=load_manifest(manifest, audio_root),
                out_path=out_json,
                label=args.label or run_id,
                notes=args.notes or "",
                device=device,
                manifest_path=manifest,
            )
            print(f"  saved ({len(done)}/{len(order)})")
    finally:
        if prev_input and shutil.which("SwitchAudioSource"):
            subprocess.run(
                ["SwitchAudioSource", "-t", "input", "-s", prev_input],
                check=False,
            )

    print()
    print(f"Done. Captured {len(done)}/{len(order)} → {out_json}")
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    manifest = Path(args.manifest)
    if not manifest.is_absolute():
        manifest = (ROOT / manifest).resolve()
    audio_root = Path(args.audio_root)
    if not audio_root.is_absolute():
        audio_root = (ROOT / audio_root).resolve()
    rows = load_manifest(manifest, audio_root)
    cap_path = Path(args.captures)
    if not cap_path.is_absolute():
        cap_path = (ROOT / cap_path).resolve()
    captures = load_captures(cap_path)
    out_json = Path(args.out) if args.out else (
        ROOT / "eval_results" / f"{cap_path.stem}.json"
    )
    if not out_json.is_absolute():
        out_json = (ROOT / out_json).resolve()
    export_eval_json(
        captures=captures,
        manifest_rows=rows,
        out_path=out_json,
        label=args.label or cap_path.stem,
        notes=args.notes or "",
        device=args.device or "BlackHole 2ch",
        manifest_path=manifest,
    )
    print(f"wrote {out_json}  ({len(captures)} captures)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_setup = sub.add_parser("setup", help="Print fair-protocol setup steps")
    p_setup.set_defaults(func=cmd_setup)

    p_dev = sub.add_parser("devices", help="List audio devices / find BlackHole")
    p_dev.set_defaults(func=cmd_devices)

    p_run = sub.add_parser("run", help="Interactive digital-loopback capture")
    p_run.add_argument("--manifest", default=str(DEFAULT_MANIFEST.relative_to(ROOT)))
    p_run.add_argument("--audio-root", default=str(DEFAULT_AUDIO_ROOT.relative_to(ROOT)))
    p_run.add_argument("--device", default=None, help="Core Audio device name")
    p_run.add_argument("--pre-s", type=float, default=0.45,
                       help="Leading silence so PTT is armed before speech")
    p_run.add_argument("--post-s", type=float, default=0.55,
                       help="Trailing silence so Wispr does not clip the end")
    p_run.add_argument("--settle-s", type=float, default=2.0,
                       help="Wait after playback for Wispr to paste")
    p_run.add_argument("--notes", default="",
                       help="Wispr settings used, e.g. cleanup=Medium dict=empty")
    p_run.add_argument("--run-id", default=None)
    p_run.add_argument("--captures", default=None, help="Resume/write this jsonl")
    p_run.add_argument("--out", default=None, help="eval_results JSON path")
    p_run.add_argument("--label", default=None)
    p_run.add_argument("--overwrite", action="store_true")
    p_run.add_argument("--show-reference", action="store_true",
                       help="Show reference text (slightly less blind)")
    p_run.add_argument("--no-clear", action="store_true",
                       help="Do not Cmd+A/Delete the paste target before play")
    p_run.add_argument("--skip-probe", action="store_true")
    p_run.add_argument("-y", "--yes", action="store_true", help="Skip ready prompt")
    p_run.set_defaults(func=cmd_run)

    p_auto = sub.add_parser(
        "auto",
        help="Automated loopback: hold Wispr PTT keycode, play WAV, read History DB",
    )
    p_auto.add_argument("--manifest", default=str(DEFAULT_MANIFEST.relative_to(ROOT)))
    p_auto.add_argument("--audio-root", default=str(DEFAULT_AUDIO_ROOT.relative_to(ROOT)))
    p_auto.add_argument("--device", default=None)
    p_auto.add_argument("--ptt-keycode", type=int, default=60,
                        help="Carbon keycode for Wispr PTT (60=Right Shift in default prefs)")
    p_auto.add_argument("--pre-s", type=float, default=0.45)
    p_auto.add_argument("--post-s", type=float, default=0.55)
    p_auto.add_argument("--settle-s", type=float, default=8.0,
                        help="Max seconds to wait for Wispr History row")
    p_auto.add_argument("--max-retries", type=int, default=2)
    p_auto.add_argument("--limit", type=int, default=0, help="Only first N clips (0=all)")
    p_auto.add_argument("--notes", default="")
    p_auto.add_argument("--run-id", default=None)
    p_auto.add_argument("--captures", default=None)
    p_auto.add_argument("--out", default=None)
    p_auto.add_argument("--label", default=None)
    p_auto.add_argument("--overwrite", action="store_true")
    p_auto.add_argument("--fail-fast", action="store_true")
    p_auto.add_argument("--no-clear", action="store_true")
    p_auto.add_argument("--no-textedit", action="store_true")
    p_auto.add_argument("--history-db",
                        default="~/Library/Application Support/Wispr Flow/flow.sqlite")
    p_auto.add_argument("-y", "--yes", action="store_true")
    p_auto.set_defaults(func=cmd_auto)

    p_ex = sub.add_parser("export", help="Rebuild eval JSON from a capture jsonl")
    p_ex.add_argument("--captures", required=True)
    p_ex.add_argument("--manifest", default=str(DEFAULT_MANIFEST.relative_to(ROOT)))
    p_ex.add_argument("--audio-root", default=str(DEFAULT_AUDIO_ROOT.relative_to(ROOT)))
    p_ex.add_argument("--out", default=None)
    p_ex.add_argument("--label", default=None)
    p_ex.add_argument("--notes", default="")
    p_ex.add_argument("--device", default="BlackHole 2ch")
    p_ex.set_defaults(func=cmd_export)

    args = ap.parse_args()
    # Accessibility: Cmd+A/C needs permission for Terminal/iTerm/Cursor.
    if args.cmd == "run" and sys.platform == "darwin":
        # Ensure we don't inherit OLIV sidecar import side effects
        os.environ.setdefault("OLIV_SIDECAR_IMPORT_ONLY", "1")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
