# Dictation silently typed nothing through AirPods

**Shipped:** 0.1.7 (build 12) · **Fixed by:** `5125a6a`, `f860c01`, `58d10ea` · **Owner:** Chayapat

---

## Summary

Holding the hotkey and speaking through AirPods typed nothing — no text, no error, no
indication anything had happened. Three independent bugs stacked on the same path: the
sidecar's silence gate averaged RMS over the whole clip (so a short sentence inside a long
hold scored as silence), a Bluetooth HFP mic emitted 0.5–3 s of exact digital zeros while its
link woke (which those averages then swallowed), and every failure mode was reported to the
user identically to "you said nothing." Fixed by making the gate frame-wise, dropping the dead
lead-in frames instead of recording them, and giving the user a mic picker that defaults to the
built-in mic — which required replacing `AVAudioEngine` with a raw AUHAL, because
`AVAudioEngine` structurally cannot bind an input-only device.

---

## Symptom

Push-to-talk through AirPods Pro. User speaks. Nothing is typed. No error, no notice, no
log line — behaviourally identical to pressing the hotkey and staying silent.

Measured on a failing capture:

```
duration       2.90 s
dead lead-in   2.901 s of EXACT 0.0        <- the whole clip
whole-clip RMS 0.00000
sidecar verdict: silence -> no transcript -> nothing typed
```

The same code on the built-in mic: 0.000 s dead lead-in, speech RMS 0.028–0.040, works fine.

---

## Root cause

Three causes, stacked. Each alone is survivable; together they produce silent data loss.

### 1. `_is_silent()` used the wrong statistic — `sidecar/sidecar_server.py`

The gate computed **one RMS over the entire clip** and compared it to `_SILENCE_RMS = 0.005`.
A mean is the wrong statistic for the question "did anyone speak," and it fails in both
directions:

- **False negative:** 0.5 s of real speech inside a 30 s hold averages to `0.0043` — under the
  floor. Clip declared silence. Nothing typed.
- **False positive:** a 30 ms click at amplitude 0.5 in a 30 s clip averages to `0.0498` — ten
  times over the floor. Pure noise reaches Whisper, which hallucinates text.

This is the cause that actually produced the silence. It is also the one that had been live the
longest.

### 2. Bluetooth HFP mics emit digital zeros while the link comes up — `macos/OLIV/AudioCapture.swift`

An HFP mic delivers **0.5–3 s of exactly 0.0** after the engine opens, while its link
negotiates — sometimes no buffers at all. Those frames were written into the utterance as if
they were audio. A 3 s utterance landed entirely inside the hole. The zeros then dragged the
whole-clip mean under cause #1's threshold, which is how the two compounded: the mic produced
nothing, and the gate blamed the user for it.

Critically, these are not *quiet* audio. A real mic in a silent room still carries a noise floor
(~0.002 measured). **Only a dead device reads exactly 0.0** — which makes it a clean
discriminator, and is the basis of the fix.

### 3. `AVAudioEngine` cannot bind an input-only device — the reason the backend had to go

The real fix for #2 is "don't use the Bluetooth mic by default" — macOS silently promotes a
paired headset to default input, and OLIV followed the default. But pointing the capture at a
*chosen* device is impossible with `AVAudioEngine`: it backs `inputNode` and `outputNode` with
the **same audio unit**.

```
engine.outputNode.audioUnit == engine.inputNode.audioUnit   // verified true
```

Every laptop mic is input-only (0 output channels), so the engine cannot be pointed at one. It
returns `-10868` from `AUGraphParser::InitializeActiveNodesInInputChain`, or — worse — starts
cleanly and then delivers **zero buffers forever**.

---

## Why it produced the symptom

The chain runs backwards from where it's visible:

1. User holds hotkey, speaks into AirPods.
2. HFP link is still waking → `AudioCapture` records exact zeros for 0.5–3 s (cause #2).
3. A short utterance fits entirely inside that hole, or is heavily diluted by it.
4. The clip reaches the sidecar. `_is_silent()` averages it. The zeros drag the mean under
   `_SILENCE_RMS` (cause #1).
5. Sidecar returns "silence." No transcript.
6. `DictationController` maps *no transcript* to `.nothingToDo` — the same outcome as "the user
   held the key without speaking." **Nothing is shown.**

Step 6 is why this survived for months. The system had the information to say "your mic was
dead" and instead said nothing, which is indistinguishable from working correctly when you
happen to say nothing.

---

## Fix

**`5125a6a` — stop dropping speech.**
- `_is_silent()` is now **frame-wise**: 30 ms frames (`_FRAME_S = 0.03`), require at least
  `_MIN_SPEECH_S = 0.15` of audio *actually at speech level*. Kills both the false negative and
  the false positive; a lone transient no longer clears the bar, and a short sentence in a long
  hold does.
- **Liveness gate** in `AudioCapture`: frames that are exactly 0.0 before the device has ever
  produced signal are **dropped, not recorded** (`bufferHasSignal` is the pure seam).
  `CaptureStats.deviceLive` records whether the mic ever woke. A 5 s backstop
  (`liveWaitTimeout`) means a genuinely all-zero virtual device degrades to "records silence"
  rather than "records nothing, forever."
- **Never fail silently:** a `.micNotReady` outcome distinct from `.nothingToDo`, a `.warming`
  HUD phase ("Getting the mic ready"), and a visible notice when `audio.start()` throws.

**`f860c01` — the mic picker, on a raw AUHAL.**
Capture moves to `kAudioUnitSubType_HALOutput` with the **output element disabled**, which has
no input/output coupling and binds any input device. `AudioDevices.swift` persists a **device
UID, not an `AudioDeviceID`** — ids are reassigned on reconnect (the AirPods went 106 → 107 →
104 in one afternoon), so an id would silently rebind to the wrong mic. Default is the built-in
mic.

**`58d10ea` — four review findings, one of them serious.** See "Self-inflicted regressions."

### What was *not* changed, deliberately

The Settings warning still says a Bluetooth mic degrades playback **"while you dictate."** An
earlier measurement said the degradation was *sticky* (20 s+, no recovery) and the plan was to
reword. That measurement was confounded — see below. Re-measured cleanly, the headset recovers
A2DP **~2 s** after the mic is released. The existing wording is correct; rewording it would
have shipped a false claim.

---

## How it was found

**Repro:** deterministic. Hold hotkey, speak a short sentence through AirPods. Instrumented
capture prints dead-lead-in duration and whole-clip RMS.

**The experiment that nailed cause #2:** dump the raw captured buffer and count leading samples
that are *exactly* `0.0`. 2.901 s of a 2.90 s clip. Not "quiet" — bit-exact zero, which no real
microphone produces. That single number separated "the user was silent" from "the device was
dead" and made the rest of the chain legible.

**The experiment that nailed cause #3:** compare the audio unit pointers.
`engine.outputNode.audioUnit == engine.inputNode.audioUnit` → true. One line, and it ends the
argument about whether `AVAudioEngine` can be made to work.

**Hypotheses rejected:**
- *Whisper/model is the problem* — rejected: the same clip transcribes fine when the leading
  zeros are stripped by hand.
- *The hotkey/permission path drops the capture* — rejected: samples were arriving, they were
  just zeros.
- *macOS refuses to restore A2DP after HFP* — rejected, but only at the very end. See below.

---

## The confound that produced two wrong root causes

`/System/Library/ExtensionKit/Extensions/Sound.appex` — the **System Settings ▸ Sound pane** —
holds the microphone **open continuously** to drive its input-level meter. That forces a paired
headset into the HFP call profile and **pins it there**, and macOS re-promotes the headset to
default input within ~2 s of any attempt to move it away.

The pane was open during an entire measurement session. Consequences:

- "AirPods can't be moved off default input" — false; that was the pane re-promoting it.
- "HFP is sticky; macOS never restores A2DP" — false; that was the pane never releasing the mic.
  With the pane quit, A2DP returns ~2 s after release. **This nearly shipped a user-facing
  warning that was wrong.**

**The tool that found it:** `kAudioHardwarePropertyProcessObjectList` +
`kAudioProcessPropertyIsRunningInput` (macOS 14+) enumerates processes currently holding an
input stream, by PID. It names the culprit directly. **Any future measurement of mic or
Bluetooth-profile behaviour on this machine must assert this list is empty first, or the result
is void.**

---

## Self-inflicted regressions during the fix

Recorded because they are the most instructive part of this bug.

**1. A capture backend that started cleanly and captured nothing — shipped to the user.**
An `AVAudioEngine` variant was declared working because `engine.start()` returned without
error. It delivered zero buffers, forever. *"The engine starts"* is not *"audio flows."* Every
capture claim now requires non-zero samples at a plausible RMS.

**2. A use-after-abandon in the AUHAL rewrite** (caught in review, fixed in `58d10ea`).
`shutdown()` deliberately **abandons** a unit whose teardown wedges — without stopping it (the
hardened stop exists because this machine has produced an 8-minute Core Audio wedge for real).
An abandoned unit's IOProc **keeps running**. The render callback's `refCon` was `self`, and it
rendered into whatever `self.unit` currently was — so the moment the user pressed the hotkey
again, the zombie IOProc called `AudioUnitRender` on the **new** unit, from the **old** unit's
thread, with the **old** unit's timestamp and frame count. Two threads then raced on one shared
render buffer and appended into one `samples`.

Fixed by giving each open its own `CaptureSession` (its own unit, buffers, converter) passed as
the `refCon`, plus a `generation` stamp bumped per `start()` that drops stale frames at the
door. On the clean path the session is released once `AudioOutputUnitStop` has returned; on the
wedge path it is leaked *with* its unit, on purpose.

Three lesser findings fixed in the same commit: the render thread allocated a PCM buffer per
callback and called `NSLog` inline (while a comment claimed it "allocates nothing");
`lifecycleLock` was held across `AudioOutputUnitStart` **and** an `NSLog` that the render thread
then blocked on; and `kAudioDevicePropertyBufferFrameSize` was never read, so a device with a
larger IO buffer overflowed the fixed 4096-frame buffer and the callback answered by returning
`noErr` **without rendering** — dropping every frame of every capture, silently, in the one file
whose entire purpose is to never lose audio silently.

---

## Why it slipped through

**Workload gap, then a reporting gap.**

The whole-clip-mean gate was correct for the workload it was written against: built-in mic, no
dead lead-in, utterances that fill the hold. It only breaks when a device injects a long silent
prefix — which nothing did until Bluetooth. macOS then made that device the *default*, so users
hit it without choosing to.

The reporting gap is the reason it stayed invisible: `.nothingToDo` was used for both "no speech
detected" and "the device produced no audio." Those are different facts and the system knew
which was which. Collapsing them meant the failure was, by construction, indistinguishable from
correct behaviour.

Tests did not catch it and could not have: every test in `AudioCaptureTests` exercises a pure
seam (`boundedTeardown`, `appendBudget`, `LevelThrottle`, `normalizedLevel`). None of them touch
a real device, a real render callback, or a real teardown race. **135/135 green said nothing
about any of the three root causes.**

---

## Validation

- **Swift 142/142**, **sidecar 44/44** — run fresh at the shipped tree.
- **Red-green verified.** The new tests were confirmed to *fail* before passing: reintroducing
  the generation gate (`acceptsFrames` → `true`) and the naive conversion-buffer size
  (`convertCapacity` → `maxFrames`) fails 4 tests; removing the regressions passes 142/142. A
  test that has never been red proves nothing.
- **Live, on the real app, with the confound removed** (Sound pane quit; input-holder list
  empty):
  - Picker = built-in: AUHAL binds device 78 (`MacBook Pro Microphone`,
    `Input:Yes | Output:No`, 1 input stream / 0 output streams). The AirPods input (device 106)
    is never opened *despite being the system default input*. AirPods **output** holds
    48000 Hz / 2 ch across every dictation, sampled 5×/sec — zero transitions. Includes a **28 s
    continuous dictation**, full text out, and **zero CoreAudio error/overload lines** for the
    whole capture.
  - Picker = AirPods: output drops to 24000 Hz / 1 ch **while the mic is held**, and returns to
    48000 Hz / 2 ch **~2 s after release**. This is the measurement that kept the Settings
    warning as-is.
- **Shipping artifact verified.** The published DMG is byte-identical to the notarized one;
  `spctl` on the *downloaded* file reports `accepted / source=Notarized Developer ID`; the
  Sparkle feed and enclosure URLs both resolve. The `--e2e-file` harness runs the real
  STT + cleanup pipeline inside the shipped bundle. The user dictated with the published 0.1.7
  from `/Applications`.

**Coverage limits, stated honestly:** all Bluetooth measurements are from **one** device model
(AirPods Pro) on **one** machine. Aggregate devices and non-Apple Bluetooth headsets are
untested. The render/teardown race is reasoned and unit-tested at its seam but **not** stress
tested against a real wedge — Core Audio wedges are not reproducible on demand.

---

## Action items

- **Regression tests added** at the seams the fix introduced: `acceptsFrames` (the generation
  gate), `convertCapacity` (buffer sizing, incl. the sub-16 kHz upsampling case), and
  `deviceBufferFrameSize` fallback. In `58d10ea`.
- **Release-pipeline guard added.** `scripts/release.sh` defaulted to
  `OLIV_SIGN_IDENTITY="Apple Development"`, which cannot be notarized but *is* reported present
  by `security find-identity` — so it sailed past the "identity not found" check and submitted a
  bundle Apple was always going to reject. It now hard-stops before the upload and prints the
  correct invocation. In `0e2d980`.
- **CHANGELOG gate.** The appcast's release notes are generated from `CHANGELOG.md`; a missing
  version section silently produced an empty `<ul>`, which would have offered every 0.1.6 user
  an auto-update with a blank changelog. Fixed for 0.1.7 (`a110248`); **no check prevents it
  recurring** — worth a `release.sh` assertion that the section is non-empty.
- **Open: no test exercises a real capture.** Every audio test is a pure seam. A harness that
  drives `AudioCapture` against a synthetic/loopback device would have caught cause #2 and the
  zero-buffer regression. Unowned.
- **Open: `AVCaptureSession` as the exit from realtime constraints.** It can bind a specific
  audio device *and* delivers on a dispatch queue rather than the IOProc thread, which would
  make the entire class of render-thread bug in `58d10ea` structurally impossible. Not
  recommended now — AUHAL is measured and working — but it is the escape hatch if this area
  needs another round.
