# OLIV for iPhone

A small native iPhone client for an [OLIV server](../server/README.md): speak Thai and English, keep the original OLIV cleanup pipeline, then use the text where you are writing.

**An optional minimal keyboard, with no always-listening microphone.** An Action button or Back Tap shortcut starts recording; by default, OLIV finishes after speech and a 1.5-second pause. A second invocation can still finish sooner. When the OLIV keyboard remains active in the same unchanged field, the app can hand the new transcript to it for automatic insertion. You can also keep Apple's keyboard and use Copy/Paste. **Capture with OLIV** remains a separate action that deliberately opens the app.

Repeated Action button starts passed 12 of 12 on a physical iPhone in build 18. See [test evidence](docs/TESTING.md#repeated-action-button-starts--build-18).

## Implemented

- 16 kHz mono 16-bit PCM capture, up to two minutes, with on-device speech detection for automatic finish.
- Public HTTPS OLIV API with an individual device key: automatic Thai/English recognition, fillers, dictionary/phonetic/vocabulary correction, selective LLM cleanup, guardrails, casing and Thai numbers/reduplication.
- A personal Dictionary (words plus optional "when I say" corrections, star and on/off) synced with the OLIV server and your other devices; edits made offline sync later. Older servers without sync still receive it as vocabulary/replacements.
- Durable audio before upload, original settings for retry, cancellation, interrupted-recording recovery, local history, raw/finished comparison and timing.
- Text cleanup using the same pipeline; failed cleanup keeps the draft.
- App Intents, Control Center controls, Home/Lock Screen widget, Live Activity and Dynamic Island stop/cancel.
- Optional English/Thai keyboard with no OLIV toolbar; explicit capture-to-keyboard delivery checks the original field before insertion.
- Keychain token storage, private HTTP opt-in, no redirects, analytics or bundled transcription model. Build 7 bundles an approximately 1.2 MB speech-activity detector; it needs no model download or extra permission.
- SwiftUI light/dark interface, Dynamic Type and accessibility.

Inserted text is a draft; OLIV does not select a conversation or send a message in LINE, T3 Code or another app. There is no public API for global insertion while retaining Apple's keyboard. Automatic insertion uses OLIV's already-active keyboard; it cannot silently switch keyboards or bypass host restrictions. The layout is custom and does not include Apple's prediction, autocorrection or swipe typing. Background clipboard writes are not assumed to work: the Apple-keyboard route uses Shortcuts' Copy to Clipboard action. Physical-device behavior must be verified before calling this better than another dictation product.

## Build

Requires Xcode with an installed iOS runtime, XcodeGen, and iOS 18 or newer.

~~~sh
xcodegen generate
open Oliv.xcodeproj
~~~

Select the **Oliv** scheme and an iPhone simulator or paired iPhone. For another developer account, change Development Team and bundle identifiers in project.yml, update the Keychain access group in App/Oliv.entitlements, and register a matching App Group for the app and keyboard. The App Group identifier must agree in App/Oliv.entitlements, Keyboard/OlivKeyboard.entitlements and Shared/KeyboardBridgeEnvironment.swift. Regenerate the project after changes. OlivCore is a local Swift package with no third-party runtime dependencies.

On this development Mac, Xcode-beta.app supplies the working iOS 27 SDK and runs the installed iOS 26.4.1 simulator. Xcode.app reports a missing iOS 26.5 platform component. Commands below select beta without changing the system-wide selection.

## Getting started

First launch walks through everything, and each step checks itself:

1. **Start free trial** requests a trial key from the server baked into the build (`OLIV_DEFAULT_API_URL`) and saves it to Keychain. Nobody sees or pastes a key. **I have an API key** goes to Settings instead. Source builds have no default server, so they show only that option.
2. **Allow microphone**, with a button to iPhone Settings if it was refused.
3. **Try it now** records and shows a first result, before any keyboard setup.
4. **Use it in every app** opens OLIV's page in iPhone Settings, then confirms OLIV's keyboard is live in a practice field.
5. **Start with one press** shows how to put **Toggle OLIV** on the Action button or in Control Center.

The app and the optional [free-trial server](../server/README.md#free-trial) work together; a server without one answers the trial request with a plain "closed" message.

## Connect your own server

1. Ask the OLIV administrator for an API key for this iPhone. A key with scope **dictate** includes cleanup during dictation; **Clean existing text** also needs scope **clean**.
2. In Settings, enter your OLIV server's HTTPS URL and paste the key. It goes into this device's Keychain, never the repository or settings JSON.
3. Tap **Test connection**. This checks that the server responds and that the key works, without sending speech or using quota. Before saving a new address it checks only that the server responds, so a saved key never reaches an unsaved address.

On upgrade, vocabulary and replacements move into the Dictionary.

No real token is bundled. Do not put it in a commit, issue, or launch argument. See [privacy](docs/PRIVACY.md).

If the API rate-limits a request, OLIV preserves pending audio and honors the server's cooldown across launches. `429` without a usable `Retry-After` uses 60 seconds. Wait before manually retrying; changing the key or URL does not bypass the cooldown. `401` means the key is invalid, expired or revoked; `403` can mean a missing operation scope or an edge access rule.

## Action button with the OLIV keyboard

Enable OLIV in **Settings → General → Keyboard → Keyboards → Add New Keyboard**, then enable **Allow Full Access** for its shared dictation handoff. Select OLIV in the destination field. Put **Toggle OLIV** on **Settings → Action Button → Controls**, or add it to Control Center on any iPhone. No shortcut is needed. Back Tap still needs a shortcut containing **Toggle OLIV**, set in **Accessibility → Touch → Back Tap**.

Press and hold the Action button once, wait for Listening/the orange microphone indicator, speak, then pause. **Action button auto-finish** is on by default: after detecting speech, OLIV finishes on 1.5 seconds of classified non-speech. A second invocation finishes sooner. If no speech begins, capture cancels after eight seconds plus up to 1.5 seconds of detector grace. Releasing the button is not a stop event. Toggle stays in the current app or reports failure; it does not implicitly open OLIV. The assigned shortcut must contain **Toggle OLIV**. The keyboard never holds the microphone open; the app releases it before transcription. Automatic insertion requires the original field and cursor to remain unchanged. If focus changes or delivery is unavailable, the result stays in OLIV for copying. Setup, limits and the physical acceptance matrix are in [Keyboard](docs/KEYBOARD.md).

## Keep Apple's keyboard

With automatic finish, run **Copy Latest OLIV** after processing and paste the result. For a two-invocation clipboard workflow, turn off **Action button auto-finish** in OLIV Settings and create this in Apple Shortcuts:

~~~text
Toggle OLIV
If [Result] has any value
    Copy [Result] to Clipboard (Local Only)
End If
~~~

Assign it in **Settings → Action Button → Shortcut**, or **Accessibility → Touch → Back Tap**. Run once to start and again to finish. Paste in the current app.

Finish through this shortcut before the two-minute limit to copy its result directly. If recording stops automatically after speech, at the limit, or after an interruption, use **Copy Latest OLIV** once processing finishes. A later Toggle starts a new recording; it does not retrieve the automatically finished result.

**Quick access** includes a native Shortcuts link and setup steps. “Capture with OLIV” opens the app; “Finish OLIV” only stops; “Copy Latest OLIV” opens and copies the newest available result.

See [iOS integration](docs/IOS-INTEGRATION.md) for Apple API evidence and the physical-device acceptance matrix.

## Test

~~~sh
swift test
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/test.sh
~~~

The script runs app/UI tests with explicitly simulated audio/server fixtures. Enable the separate real recorder test with OLIV_RUN_MICROPHONE_TESTS=1. Both macOS and the simulated iPhone can request microphone permission. It records about 400 ms locally and never uploads that audio.

Debug-only --demo and --ui-testing arguments use isolated storage, synthetic WAV and a fake service, with a persistent banner. The explicit --keyboard-test-host and --keyboard-integration-demo fixtures additionally opt into the real keyboard App Group to test delivery with synthetic audio/server results. Release builds exclude these entry points. None proves live transcription accuracy or physical Action button behavior.

The opt-in **OlivPhysicalAudioValidation** scheme selects a separate real-microphone diagnostic on a physical iPhone with permission already granted. It launches `--keyboard-test-host --real-audio-background-test`, starts capture explicitly, presses Home for at least two seconds, returns and checks background PCM/classification progress and cleanup. Capture has an eight-second limit; audio is discarded from isolated temporary storage with no network request or user-history access. It does not exercise an Action button start. Execution results are tracked in [test evidence](docs/TESTING.md#automatic-finish--build-7).

To run the opt-in tests against the actual keyboard extension, first install OLIV on an isolated simulator and manually enable its keyboard and **Allow Full Access**. In Simulator, turn off **I/O → Keyboard → Use the Same Keyboard Language as macOS** so macOS does not re-add its keyboards; also turn off **Connect Hardware Keyboard** to show the on-screen keyboard. Then run:

~~~sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project Oliv.xcodeproj -scheme OlivKeyboardValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' \
  -parallel-testing-enabled NO test
~~~

Use the destination where you enabled OLIV. This scheme sets `OLIV_KEYBOARD_TESTS=1`; the normal test scheme skips these tests. The suite can select an already enabled OLIV through the globe menu, but never changes Settings or grants access. It tests English/Thai key input, new-result insertion once, changed-field/edit rejection and cancellation using the real extension with synthetic audio/server responses. It does not invoke the physical Action button or prove capture while another app is foreground. See [keyboard validation](docs/KEYBOARD.md#simulator-validation).

For a real authenticated round trip with **synthetic** audio:

~~~sh
python3 Scripts/server_smoke.py --url https://oliv.example.com \
  --token-file /secure/local/path/api.token --wav /path/to/synthetic-16k-mono.wav
~~~

Use an individual key with scope **dictate**. The script sends `User-Agent: oliv-ios/0.1.0`, allows 120 seconds per network operation, refuses redirects and checks minimal public health before submitting the synthetic WAV. Health establishes liveness only; only a valid dictation reply establishes this authenticated round trip. Output includes status, duration and output length, never the key or transcript. Linux evaluation recordings are not copied. The command is a procedure, not a claim that an authenticated live run has passed; see [test evidence](docs/TESTING.md).

See [test evidence](docs/TESTING.md).

The explicit OlivLiveValidation scheme enables public HTTPS liveness and unauthorized-request checks using a deliberately invalid key. It does not submit recorded speech or require the real access key:

~~~sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project Oliv.xcodeproj -scheme OlivLiveValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' test
~~~

## Source map

- App/: SwiftUI, coordinator, recorder, Keychain and ActivityKit.
- Shared/ and Widget/: intents, system controls and Live Activity.
- Keyboard/: minimal English/Thai typing and guarded insertion through the active text proxy.
- Sources/OlivCore/: protocol, strict decoding, ordered requests, WAV validation and stores.
- Tests/, AppTests/, UITests/: package, lifecycle and UI tests.
- project.yml: source of truth for the checked-in Xcode project.
- [Core parity](docs/CORE-PARITY.md): mapped to the current Linux API migration and reference pipeline.

See [TestFlight distribution](docs/TESTFLIGHT.md) for archive/upload commands and external beta setup. A local archive is not a published TestFlight build; availability must be verified in App Store Connect.
