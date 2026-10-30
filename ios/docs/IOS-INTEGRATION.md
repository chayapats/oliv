# iPhone integration

OLIV records only after an explicit action and sends audio to the user's configured OLIV server. The optional minimal OLIV keyboard can insert the new transcript into its original unchanged field. With Apple's keyboard, the result is available through Copy/Paste. Neither route keeps a microphone open while idle or requires another transcription vendor.

The app targets iOS 18 or newer. Action button support depends on the iPhone model; Back Tap, Control Center, and widgets provide alternatives. Initial API checks used Xcode's iOS 26.5 SDK; the complete simulator build subsequently passed with the installed Xcode beta and iOS 27 SDK.

## Recommended everyday workflow

Complete server/key setup and microphone permission inside OLIV first. An HTTPS OLIV server works without a private VPN. Use an individual iPhone key with scope `dictate`; standalone text cleanup additionally needs `clean`. **Test connection** reports public API liveness only, not key validity or model readiness. Leave Live Activities enabled for OLIV in iPhone Settings.

For automatic insertion, enable the OLIV keyboard and Allow Full Access, select it in the destination field, and create a shortcut containing **Toggle OLIV**. By default, one Action button invocation starts recording and speech detection finishes it after a 1.5-second pause. A second invocation can finish sooner, while the keyboard remains the input surface. Automatic delivery is attempted only for the original unchanged focus; the keyboard does not record audio. Full setup and the delivery protocol are in [Keyboard](KEYBOARD.md).

With Apple's keyboard and automatic finish, use **Copy Latest OLIV** after processing, then paste. For the two-invocation clipboard flow, turn off **Action button auto-finish** in OLIV Settings and create a shortcut with these actions:

1. **Toggle OLIV** (the action supplied by OLIV).
2. **If** the result **has any value**.
3. **Copy to Clipboard**, using that result. Enable **Local Only** if text should stay on this iPhone; an optional expiration limits clipboard lifetime.
4. End If.

Assign this shortcut to the Action button, or to **Settings → Accessibility → Touch → Back Tap → Double Tap / Triple Tap**. Back Tap lists shortcuts saved in the user's collection; an App Shortcut alone is not enough for this clipboard chain.

Invoke once to start, speak, then invoke again to finish. The first invocation returns empty text; the second waits for the new transcript and returns it to the Copy to Clipboard action. A no-speech result is also empty and does not overwrite the clipboard. With Apple's keyboard, paste into the destination using the keyboard or the system Paste menu. With OLIV's active keyboard, delivery independently checks and claims the new result for the captured field.

Finish through the shortcut before the two-minute limit to deliver its result to the clipboard action. Automatic finish, the time limit and interruptions can finish recording without a waiting shortcut. Those completions can still use an unchanged eligible OLIV keyboard target; otherwise, wait for processing and use **Copy Latest OLIV**, or open the result and copy it. Running Toggle after automatic completion starts another recording; it does not return the previous result.

**Build 4 completed one physical background start/stop, transcription and keyboard insertion.** App diagnostics show background microphone activation, a second Toggle about seven seconds later, microphone stop, `resultReady` and `deliveryPublished`; the keyboard then recorded `keyboardDelivered` after its insertion call. A later start, about five seconds after publication, found no visible keyboard and failed audio activation with `561015905` (`cannotStartPlaying`). Repeat-start reliability remains unresolved. Toggle no longer uses foreground continuation; the user can separately choose **Capture with OLIV** to open the app. See [device evidence](TESTING.md#background-microphone-activation--build-4).

Apple documents [Copy to Clipboard](https://support.apple.com/guide/shortcuts/apd081d9d61f/ios), [Back Tap shortcuts](https://support.apple.com/guide/shortcuts/apd897693606/ios), and [system paste gestures](https://support.apple.com/guide/iphone/iph1a9cae52c/ios).

## Implemented actions and surfaces

| Name shown by OLIV | Behavior |
| --- | --- |
| **Toggle OLIV** | Start recording and bind eligible fresh keyboard focus. Automatic finish is on by default; a second invocation can finish sooner and return the new text. Remain in the current app or return failure guidance. Button release is not a second invocation. |
| **Capture with OLIV** / shortcut tile **Capture** | Deliberately open OLIV and begin recording after setup. This is a separate user-selected action. |
| **Finish OLIV** / shortcut tile **Finish** | Finish only an active recording and return its text. It never starts a new recording. |
| **Copy Latest OLIV** / shortcut tile **Copy Latest** | Open OLIV and copy the latest result. |
| **Cancel OLIV** | Discard an active recording. Used by Live Activity controls and hidden from the public shortcut gallery. |

The background Action Intent route has no button-release callback, so holding then releasing cannot implement release-to-stop here. Apple’s [ControlWidgetButton](https://developer.apple.com/documentation/widgetkit/controlwidgetbutton/) invokes a discrete action. Its separate camera-event API exposes press phases only while a foreground app actively uses the camera; [Apple’s camera session](https://developer.apple.com/videos/play/wwdc2025/253/) explicitly excludes backgrounded or inactive-camera apps. OLIV does not activate a camera to obtain those events. **Action button auto-finish** is now on by default for Toggle. The separate **Finish after a pause** setting applies the same detector to other captures and remains off by default.

The app publishes four App Shortcuts. **Toggle OLIV** and **Capture with OLIV** also appear as WidgetKit Control buttons for Control Center, the Lock Screen and supported Action button configurations. Buttons deliberately do not pretend to show shared recording state; the authoritative state is in the Live Activity and app.

**Capture with OLIV** conforms to `OpenIntent`, Apple's documented app-opening contract for controls. Its single `AppEnum` target defaults to Capture, so existing shortcuts and fixed controls need no additional choice. The intent is included in both app and widget targets. It selects the capture screen (or Settings when setup is incomplete), then uses foreground recording. The target has no URL representation, so its `perform()` implementation handles this action. This establishes the supported routing contract; it does not replace testing the installed control on an iPhone. See [OpenIntent](https://developer.apple.com/documentation/appintents/openintent).

**OLIV Capture** supports small and medium Home Screen widgets, plus circular and rectangular Lock Screen widgets. The Home Screen widget's Capture button runs **Capture with OLIV**. The circular and rectangular Lock Screen widgets open the capture screen, where the user taps Capture; their deep links do not start the microphone. The separate WidgetKit Control buttons run their named intent. A static timeline avoids repeated refresh work. Widget and Live Activity deep links use `oliv://capture` and `oliv://latest`.

During capture, the Live Activity shows **Listening**, elapsed time, **Finish** and **Discard**. Processing shows **Finding your words**. A completed result says **Ready in OLIV / Open to copy or share**. No transcript, server address or token is placed on the Lock Screen. Finishing directly through Control Center or the Live Activity saves a result; it is not equivalent to running the custom clipboard shortcut.

Toggle, Finish, Capture and Copy Latest require local device authentication because they may record or return private text. Lock Screen entry can therefore require unlock. Discard does not expose transcript content. The user chooses Action button and Back Tap assignments; the app does not change system settings automatically.

Sources: [WidgetKit Controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system), [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts), [Action button](https://developer.apple.com/design/human-interface-guidelines/action-button).

## Automatic finish

Build 7 replaces Apple's built-in SoundAnalysis classifier with a bundled, approximately 1.2 MB [Silero VAD](https://github.com/snakers4/silero-vad) model converted from official v6.2.3 weights to a fixed Core ML graph. [Model provenance](../App/Resources/SileroVAD-PROVENANCE.md) records the pinned source, MIT license, conversion and numerical checks. A direct Core ML wrapper loads the compiled model with [`MLComputeUnits.cpuOnly`](https://developer.apple.com/documentation/coreml/mlcomputeunits), using no GPU. It classifies speech only during an explicit recording, without transcribing words, downloading a model or sending audio to another service for classification.

After speech is detected, 1.5 seconds of classified non-speech ends capture. With no initial speech, capture cancels after eight seconds plus up to 1.5 seconds of detector grace. Timing includes classifier latency; this is not an exact wall-clock silence timer. Other speech can extend recording, and classification can miss quiet speech. The two-minute cap and manual Finish/Discard remain available.

`automaticActionButtonFinish` defaults to true even for older settings without the new optional stored value. `stopAfterSilence` remains false by default for other capture paths. The classifier runs only for active capture and stops before upload; there is no idle microphone, extra speech-recognition service or new permission. A real iPhone test verified foreground-started capture and classification across Home and return, followed by cleanup. An Action button start-to-insertion round trip remains pending; see [test status](TESTING.md#automatic-finish--build-7).

The change follows a failed physical build 6 attempt and [developer reports of built-in SoundAnalysis GPU failures in the background](https://developer.apple.com/forums/thread/765376). Apple recommends CPU-only Core ML execution for apps that may run in the background. GPU denial is a plausible explanation, **not a confirmed diagnosis of the local failure**; the device events did not expose its underlying cause. The new hardware probe tests actual background audio/classification independently of the synthetic keyboard tests.

## Recording lifecycle

The shared `ToggleCaptureIntent` and `StopCaptureIntent` conform to both `AudioRecordingIntent` and `LiveActivityIntent`. The recording implementation is compiled only into the main app using `OLIV_APP`; extension execution fails clearly instead of reporting false success. Widgets do not need an App Group or access to credentials, recordings or history. The optional keyboard and main app share a separate, narrowly scoped focus/result delivery container.

On iOS 27, app-owned intents additionally set `allowedExecutionTargets` to `.main` explicitly; older supported iOS versions retain the protocol-based routing. This removes extension execution as an allowed target on the new SDK but is not evidence that an individual system invocation succeeded. See [allowed execution targets](https://developer.apple.com/documentation/appintents/appintent/allowedexecutiontargets).

Apple requires an active Live Activity for recording intents. ActivityKit documents background Live Activity creation through `LiveActivityIntent`, and WidgetKit documents that this intent runs in the main app process. The implementation creates the Live Activity and starts the real microphone session before returning from the start action. A detached task that returns early is unsuitable for this lifecycle. App Intent runtime selection still depends on the invocation surface and system state.

Sources: [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent), [ActivityKit lifecycle](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [interactive widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities), [intent runtime behavior](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents).

`LiveActivityManager` invalidates in-progress starts when cancellation occurs across an asynchronous boundary. Dismissing its activity during preparation or recording cancels capture. The recorder writes mono 16 kHz PCM WAV and has a two-minute recording limit. Real interruption or route loss stops capture. The app declares the audio background mode so an already active recording can continue after the app backgrounds. Stop/cancel releases the recorder and deactivates its session before network processing. Idle state and ordinary typing have no OLIV recording session or metering task.

The build 4 correction uses `.playAndRecord`, `.measurement`, and options `.mixWithOthers` / `.allowBluetoothHFP` for the explicit recording session. Apple defines [cannotInterruptOthers](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotinterruptothers) as background activation of a nonmixable session. [mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers) is supported with `.playAndRecord`; [measurement](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement) reduces system signal processing, and [allowBluetoothHFP](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp) allows compatible Bluetooth input. This addresses the observed failure mechanism; it does not prove that every background state or audio route will work. No audio is played to keep the process alive.

Build 4 also removes implicit foreground continuation from Toggle. A failed start should release its audio session and Live Activity, report the problem, and leave the destination app in place. The separate **Capture** action remains an app-opening `OpenIntent`; the in-app Capture button can record without Live Activities. One physical background recording-to-keyboard round trip is verified; a subsequent audio-activation failure still requires investigation.

The background mode is not a blanket permission to open the microphone from arbitrary code. An [Apple DTS response about BLE-triggered recording](https://developer.apple.com/forums/thread/816408) describes this restriction; it does not establish that a properly system-invoked recording intent is unsupported. The genuine system invocation must be tested separately.

## Cross-app limits

There is no public general-purpose API here to type into another app's focused text field while retaining Apple's keyboard. `textDocumentProxy` belongs to the active custom keyboard. OLIV uses that proxy only inside its already-active extension, after an explicit capture and fresh context verification. With Apple's keyboard, OLIV returns text to Shortcuts or copies on a foreground action, and the user pastes. There is no global key injection, silent keyboard switching, automatic return to a previous app or systemwide overlay. Insertion creates a draft; it does not read incoming chats, select a LINE/T3 Code conversation or invoke another app’s Send action.

The optional keyboard has no recording or network behavior. It exchanges only focus metadata and a requested result with the main app, using event-driven checks before capture and publication. It has no idle heartbeat. A new field, edited context, cursor movement or keyboard dismissal invalidates the target. Canceled/failed capture, no-speech replies, retries and standalone cleanup cannot publish a new keyboard result. Shared-container storage and expiry are documented in [Keyboard](KEYBOARD.md) and [Privacy](PRIVACY.md).

The keyboard uses a custom minimal interface. Apple's complete UI, prediction/autocorrection engine and swipe typing are not supplied by `UIInputViewController`; exact Apple keyboard parity is not claimed. Secure and phone fields use the system keyboard, and host apps can reject third-party keyboards. Clipboard writes from a background process remain unvalidated; the Apple-keyboard shortcut uses Apple's own Copy to Clipboard action.

Sources: [textDocumentProxy](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/textdocumentproxy), [UIPasteboard](https://developer.apple.com/documentation/uikit/uipasteboard/), [creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [keyboard interface and restrictions](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface).

The implementation uses public recording APIs for their intended purpose. It does not hold the app alive with silent playback, VoIP, PushToTalk, location updates or an always-open microphone. Recording has an explicit user trigger and a visible status. See [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.5.1, 2.5.4 and 2.5.14.

## Transport configuration

The app uses the configured server URL (source builds prefill none; a release build can bake one in through `OLIV_DEFAULT_API_URL`), validates certificates and hostnames normally, sends `User-Agent: oliv-ios/0.1.0`, and refuses redirects. Request/resource timeouts are 120 seconds; recording itself remains capped at two minutes. No private VPN is needed. Public health is minimal liveness only; there is no cleanup, status or model preflight.

The app does not enable `NSAllowsArbitraryLoads`. Its property list keeps `NSAllowsLocalNetworking` for user-configured local services and removes the retired private address's insecure HTTP exception. Custom HTTP still requires explicit opt-in and a recognized private/local host; that validation does not guarantee ATS will allow every custom address. Test any custom configuration through the actual app and keep any necessary ATS exception narrow rather than disabling transport security globally.

Legacy-default settings are staged for public HTTPS, private HTTP is turned off, and the saved address/key binding is cleared. The user must explicitly save a new individual key. Custom endpoints and local vocabulary, replacements, history and pending recordings are preserved. The retired shared token is not automatically paired with the public endpoint.

Sources: [NSExceptionDomains](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains), [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

## Verification status and physical-device acceptance

These are separate evidence levels; a passing build does not establish physical-device behavior.

| Check | Evidence currently available |
| --- | --- |
| Shared intent + widget sources, iOS 18 deployment, extension API restrictions | Passed independent Swift 6 typecheck using the iOS 26.5 simulator SDK. |
| App intent + ActivityKit manager sources | Passed independent Swift 6 typecheck against an AppModel contract stub, then the complete integrated build below. |
| Widget extension Info.plist | Passed `plutil -lint`. |
| Full integrated app + widget build | Passed Xcode beta `xcodebuild`, iOS 27 simulator SDK, iOS 18 deployment target, signing disabled. Log: `/tmp/oliv-integration-build.log`. |
| Capture control's OpenIntent contract | Passed a fresh generic-simulator build after adopting `OpenIntent`. App and widget metadata both contain `OpenEntity`, foreground launch, and default target `capture`; the App Shortcut retains its identifier, title and phrases. Log: `/tmp/oliv-openintent-build.log`. No simulator or device was launched for this check. |
| App tests and UI tests | See the root project's current test report; compilation does not establish behavior. |
| Shortcuts discovery and foreground intent routing | Verified through the actual Shortcuts UI on the iOS 26.4 simulator. All four OLIV actions appeared. After the final OpenIntent change, the existing **OLIV Capture Test** shortcut ran **Capture with OLIV** again without requesting a target, opened OLIV's Settings, and correctly requested server/token setup. No real token or recording was used. |
| Siri phrase training | Xcode beta reported a non-fatal SSU archive diagnostic. It did not block Shortcuts discovery or foreground routing above; spoken Siri phrases remain unverified. |
| Build 4 audio-session correction | 64 app tests passed; opt-in live HTTP and Simulator-unavailable physical protection were skipped; real Simulator recorder category/WAV check passed. Signed Release and in-place install passed; device confirms 0.1.0 (4). Compiled Toggle metadata is background-only without foreground continuation. Physical observations are separate; see [test record](TESTING.md#background-microphone-activation--build-4). |
| Physical Toggle background start | Build 4: one background start, second-Toggle stop, result publication and keyboard insertion verified. A later start had no visible keyboard and failed audio activation with `561015905`. Repeat-start reliability, cold start, Back Tap and Lock Screen cases remain open. |
| Actual iPhone microphone/AirPods quality, interruptions and energy impact | Unverified. |
| Clipboard shortcut while another app remains foreground | Unverified on physical hardware. |
| Optional OLIV keyboard handoff | One physical build 4 round trip reached `keyboardDelivered` after `textDocumentProxy` insertion. No transcript was read and recognition quality was not assessed. Fixtures and device observations remain separate in [test results](TESTING.md). |

Simulator evidence: [action catalog](Screenshots/shortcuts.png), [saved Capture test](Screenshots/shortcuts-capture-test.png), [foreground routing to setup](Screenshots/shortcuts-capture-routing.png).

Before calling the background path ready, install a signed build and run this matrix:

| Area | Cases | Pass condition |
| --- | --- | --- |
| Startup | App foreground, background, suspended, terminated; Action button, saved Back Tap shortcut, Control Center | Toggle starts valid audio with a visible activity while the destination stays foreground, or fails clearly without opening OLIV. Explicit Capture opens OLIV. No false success. |
| Lock state | Unlocked, locked, newly rebooted before first unlock | Authentication and credential protection are respected; no hidden recording or leaked result. |
| Setup | Missing token, invalid endpoint, microphone denied/revoked, Live Activities disabled | Clear recovery path; no stuck activity or permanently active microphone. |
| Completion | Same toggle, explicit Finish, Live Activity Finish, two-minute cap, optional silence stop | Exactly one result and microphone released before processing. Toggle/Finish return new text to their caller. An eligible unchanged OLIV keyboard can receive the result; other completions remain available through Copy Latest. |
| Cancellation | Preparing, active recording, processing; activity dismissed; 20 rapid invocations | No duplicate sessions, zombie activity or late result replacing a new operation. Saved retries remain consistent. |
| Audio | Built-in mic, AirPods, wired input, incoming call, Siri, route disconnect | Clear stop/interruption behavior and valid WAV; no silent success. |
| Network | Offline, timeout, 401, 429, server failure, background time expiration | Audio preserved for retry; status does not falsely say copied or ready. |
| Durability | Force quit while recording/uploading, relaunch, storage failure, invalid recovery file | Prior history loads; recoverable audio survives; invalid remnants cannot permanently block capture. |
| Delivery | OLIV insertion and ordinary Paste in Notes, Safari text fields and Messages; altered cursor/field; no-speech result | One new insertion only into the original unchanged OLIV target, or explicit Paste with another keyboard. No-speech and stale targets never insert text. |
| Energy | Idle vs active capture, repeated captures and stop | No microphone, meter loop or background work persists while idle. |

Do not use an eight-minute test as though long-form recording were supported: the implemented cap is two minutes. Simulator microphone routing also does not prove iPhone hardware behavior.
