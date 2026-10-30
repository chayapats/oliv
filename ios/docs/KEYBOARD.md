# OLIV keyboard

The optional OLIV keyboard provides a quiet typing surface and receives the result of an explicitly requested OLIV dictation. English and Thai layouts, key geometry and feedback are measured against the iPhone 17 keyboard on iOS 27. The Thai/English switch occupies the emoji slot. It has no OLIV toolbar, subscription panel or recording session kept alive while typing. The [appearance reference](KEYBOARD-APPEARANCE.md) records the measurements and remaining platform limits.

It is a custom implementation, not an embedded copy of Apple's keyboard. Apple supplies an initially empty keyboard view; the extension must implement its own interface and typing behavior. Apple prediction, QuickPath swipe typing, learned corrections and the full Thai language engine are not exposed for reuse here. The current keyboard does not implement predictive suggestions, autocorrection or swipe typing. See [creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard) and [UIInputViewController.inputView](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/inputview).

## Space trackpad and Delete — build 14

Hold Space and drag in any direction. Horizontal movement keeps the existing 8 pt step; vertical movement uses 12 pt steps, retains the desired column within a gesture, and supports blank paragraphs. Build 14 halves the vertical travel from build 13; axis hysteresis rejects incidental sideways drift, deliberate turns can change direction, and reversal starts from the latest finger extreme rather than retracing the whole gesture. The public text proxy exposes paragraph-sized context on the tested iOS 27 hosts, so vertical movement waits for each boundary adjustment to be acknowledged before reading the next paragraph. A new edit, document change, new gesture or keyboard disappearance cancels pending movement. Context stays in memory only during navigation; it is never saved or sent.

Visual wrapping uses an estimated 17 pt font and keyboard width minus 32 pt. A keyboard extension cannot read the host's actual font, text insets, line rectangles or caret affinity, so alignment on soft-wrapped lines is approximate. Hidden paragraph crossings assume LF separators. Arbitrarily clipped host context, hidden CRLF and delayed host acknowledgement can prevent exact native behavior. Empty contexts allow one bounded separator probe per requested step; they never authorize an unbounded scan.

Delete requests its first edit before haptic playback, reuses the synchronous initial hold observation, and avoids duplicate host reads in word pulses. Holding starts repeats after 220 ms at a 60 ms character cadence, then admits two-word pulses after 900 ms and ten completed repeats (normally around 940 ms). Word cadence remains 350 ms. Release and field guards remain active. Light haptic requests increase from 0.35 to 0.55 for a press and from 0.20 to 0.32 for repeats; UIKit and device settings still control actual playback.

Safari's inline URL completion remains a known limitation. Manual comparison reproduced OLIV deleting the typed prefix while the visual completion remained; Apple's keyboard first dismissed the completion. The public proxy provides no completion identity or dedicated dismissal command, and the visual suffix did not behave like an ordinary selected range when OLIV requested deletion. This build does **not** claim a Safari fix or issue an unconditional extra deletion. A 2026-10-30 simulator probe confirmed the proxy reports no selection or after-context while the completion is visible, and twelve public proxy operations failed to dismiss it ([record](TESTING.md#host-keyboard-crash-and-safari-completion--2026-10-30)). See [Apple's proxy API](https://developer.apple.com/documentation/uikit/uitextdocumentproxy) and [text interaction guide](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards).

## Setup and everyday use

1. Complete first-run setup in the main app, which covers the connection and microphone permission. Keep Live Activities enabled for background dictation.
2. In iPhone Settings, add OLIV under **General → Keyboard → Keyboards → Add New Keyboard**.
3. Enable **Allow Full Access** for OLIV if automatic dictation insertion is desired. Ordinary typing does not require this access.
4. Select OLIV in the destination app's text field. Put **Toggle OLIV** on **Settings → Action Button → Controls**, or add it to Control Center. **Capture with OLIV** opens the app and does not retain the destination keyboard field.
5. **Press and hold once** until Listening/the orange microphone indicator appears, speak, then pause. With **Action button auto-finish** on (the default), 1.5 seconds of classified non-speech after speech finishes capture. Invoke again to finish sooner. The unchanged eligible field receives the result as a draft; OLIV does not send it. No microphone button or new spacebar control is added to the keyboard.

The keyboard must already be active. The app cannot silently replace Apple's keyboard in the current field. Opening OLIV's foreground Capture flow does not carry a target field forward; the result remains available in OLIV for copying. Build 4 removes Toggle’s implicit foreground continuation so a failed start cannot move away from the target app and silently change the workflow.

Changing fields, moving the cursor, editing text, dismissing the keyboard or switching away invalidates the target. The app preserves a successful transcript in History when enabled, or in the current result when History is disabled. A refused insertion does not reroute text to a different field. A canceled/failed operation, a no-speech result, a retry and standalone text cleanup never publish text for automatic insertion.

Physical build 4 completed one background start, second-Toggle stop, transcription and keyboard insertion: `deliveryPublished` was followed by the keyboard’s `keyboardDelivered` acknowledgement after `textDocumentProxy` insertion. No transcript was read or accuracy assessed. A later start found the keyboard not visible and failed audio activation with `561015905` (`cannotStartPlaying`); repeat-start reliability, cold launch and the broader cross-app matrix remain open. See [integration evidence](IOS-INTEGRATION.md) and [test results](TESTING.md).

If Toggle cannot start, build 4 should report specific setup, Live Activity or microphone-start guidance while leaving the current app in place. The separate **Capture with OLIV** action still deliberately opens OLIV. On iOS 27, the intent explicitly selects the main app as its execution target. If transcription succeeds but the original keyboard field cannot be verified, the app explains that the result is ready for copying rather than silently treating publication failure as normal delivery. One successful device round trip does not establish reliability across other apps and device states.

Releasing the Action button does not finish a recording. Automatic finish responds to detected speech and a pause, not release events; a second invocation still stops manually. No initial speech cancels capture after eight seconds plus up to 1.5 seconds of detector grace. The separate **Finish after a pause** setting for other recordings remains off by default. See [detector behavior and limits](IOS-INTEGRATION.md#automatic-finish). Build 6's physical speech-analysis attempt failed. Build 7's CPU-only replacement passed a bounded device background-capture probe, while Action button completion and insertion still need validation. Build 4 evidence above covers manual stop.

## Microphone lifetime

Only the main app's recorder opens the microphone, after an explicit capture action. The bundled speech detector in build 7 runs on that current recording only; it does not listen while the keyboard is idle. The keyboard never loads the model, activates the microphone or sends network requests. There is no idle audio session, silent playback, heartbeat recording, keep-alive capture or timer that periodically restarts recording.

`AudioCaptureService.stop()` stops recording and input analysis, then deactivates its audio session before returning audio data. `AppModel` calls this before preparing an upload, waiting on the server or publishing a keyboard result. Cancel and failed-start paths also release the recorder and deactivate the session. A two-minute limit and the existing interruption handling remain in force. Automatic insertion adds no change to microphone or Live Activity authorization checks.

Tests use an instrumented recorder and service to verify that idle/text-only operations never start capture and that the recorder is inactive before the first transcription request. Physical-device testing must additionally inspect the system microphone indicator and audio routing; a synthetic recorder cannot prove hardware state.

## Shared access and delivery

Apple requires open access to let a keyboard write to a shared app container. This is the reason for **Allow Full Access**. OLIV uses the App Group `group.com.chayapat.oliv.ios` for short-lived focus metadata and one requested dictation result. The keyboard does not use network access. Server credentials, audio files, history and settings stay in the main app's private storage. See [Apple's open-access documentation](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard).

The bridge is event driven:

1. At the start of a background recording action, the app sends a payload-free Darwin notification requesting fresh keyboard focus. It waits at most about 250 ms for a response. There is no periodic idle poll.
2. A visible keyboard checks its current document, selection and surrounding context, then publishes a six-second focus lease. Only identifiers, a revision, timestamps and a SHA-256 context digest are shared; surrounding typed text is not stored in the bridge.
3. The app binds that exact lease to the new recording's UUID before starting audio. It does not replace the target with whichever field is visible later.
4. After a successful transcription and after releasing the microphone, the app requests another fresh focus response. Publication requires the same document, focus identifier, revision and digest as at capture start.
5. The keyboard recomputes its current context before claiming the result. A cross-process, nonblocking file lock protects the focus check and atomic removal. The consumed result is removed durably before `textDocumentProxy.insertText` is called, so a repeated notification cannot insert it twice.

The store rejects stale or malformed state and canceled/already-published session identifiers. Temporary contention produces bounded retry or a normal copy-from-OLIV fallback; it never blocks the keyboard waiting on a suspended app. If the keyboard process ends after claiming text but before insertion, the result may not be inserted, but it cannot be inserted twice by a replay.

Delivery eligibility expires after 60 seconds. Consumed text is removed immediately; expired unconsumed text is pruned on the next bridge operation. There is no timer that guarantees physical deletion from disk at the exact expiration instant. Receipt records contain only session identifiers and expiration dates. Shared files are excluded from backup and protected until the device's first unlock.

Default `AppModel` initializers and existing test/demo fixtures have no keyboard coordinator. Production wiring is explicit; the Debug-only keyboard integration fixture opts in separately. Tests use temporary directories and fake credentials/audio/server responses.

## Simulator validation

The `OlivKeyboardValidation` scheme opts into `KeyboardUITests` with `OLIV_KEYBOARD_TESTS=1`. Without that flag, the suite skips. Its `--keyboard-test-host` screen contains native text fields and explicit Start, Finish and Cancel controls. The keyboard runs as the installed extension and exchanges focus and text through the real App Group. The recorder and server are synthetic, and the host visibly identifies the fixture.

Before running on an isolated simulator, install OLIV, enable its keyboard and grant **Allow Full Access** manually. Turn off Simulator's **I/O → Keyboard → Use the Same Keyboard Language as macOS** to prevent macOS language synchronization from re-adding Apple keyboards. Turn off **Connect Hardware Keyboard** as well. The test launch helper selects an already enabled OLIV from the system globe menu when needed; it does not change Settings or access permissions. Disable parallel simulator testing so the configured simulator, rather than a fresh clone, supplies these prerequisites. The command is in the [README](../README.md#test).

The suite checks actual English and Thai key insertion, delivery of a new transcript exactly once, rejection after a field change or typing during capture, and cancellation. These checks establish extension behavior and cross-process delivery in the native fixture host. They do not establish cross-app Action button routing, a real background microphone session, live recognition quality or physical-device behavior. Current executed results are recorded in [test evidence](TESTING.md).

## Platform limits and acceptance checks

Secure fields and phone/name-phone fields use the system keyboard. Host apps may reject third-party keyboards entirely. These restrictions remain even if OLIV is the user's only everyday enabled keyboard. [Apple documents these limits](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface).

Before relying on automatic insertion on a personal iPhone, verify:

| Case | Expected result |
| --- | --- |
| OLIV idle or ordinary typing for several minutes | No OLIV microphone use, audio session or recurring focus polling. |
| Action button start/finish with OLIV visible in Notes, Messages and browser fields | One new transcript in the original field; microphone released before processing finishes. |
| Typing, cursor movement, selection changes or switching fields during dictation | No insertion into an altered or replacement target; transcript remains accessible in OLIV. |
| Keyboard dismissed, app changed, device locked or keyboard process restarted | Stale targets fail closed; no delayed insertion into a later field. |
| Cancel during focus lookup, recording, upload or final delivery lookup | No new automatic insertion; retryable audio follows the main app's existing retention behavior. |
| No speech, offline, server error, retry and standalone cleanup | No automatic insertion from these paths. |
| Long capture beyond the initial six-second focus lease | A freshly revalidated unchanged target can receive the new result. No idle heartbeat is required. |
| Full Access off or app group unavailable | Ordinary keyboard typing works; automatic delivery remains unavailable. |
| Built-in microphone, AirPods, incoming call and route disconnection | Correct microphone release and interruption behavior; no recording kept alive to preserve the keyboard. |
| Light/dark appearance, Thai/English, portrait/landscape, Return and secure-field fallback | Usable key layout and host-appropriate behavior without claiming parity with Apple's full keyboard engine. |
