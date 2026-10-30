# Keyboard appearance reference

The keyboard is measured against Apple's actual iPhone 17 keyboard on the iOS 27 Simulator, at 402 × 874 points / 1206 × 2622 pixels. `KeyboardVisualReferenceTests` captures both keyboards in the same native, empty `UITextView`; its Debug-only host does not record audio or contact a server. Reference captures include English and Thai letters, Shift, numbers and symbols. The Thai/English toggle intentionally occupies the native emoji slot.

## Measured portrait geometry

These are **visible keycap** measurements, not the larger accessibility/touch frames reported by UIKit.

| Property | English / numbers / symbols | Thai letters |
| --- | --- | --- |
| Rows including Space | 4 | 5 |
| Visible key height | 43 pt | 37–37⅓ pt, aligned to the 3× pixel grid |
| Vertical gap | 11 pt | 6 pt |
| Horizontal gap | 6 pt | 6 pt |
| First-row columns | 10 | 12 |
| Key corner radius | 8 pt | 8 pt |
| Light key fill, white host | `#ffffff` | `#ffffff` |
| Light native backdrop, white host | `#e2e3e8` | `#e2e3e8` |
| Dark key fill / native backdrop, black host | `#444444` / `#202020` | `#444444` / `#202020` |
| Key drop shadow | None in the observed reference | None in the observed reference |

The native English keycap row tops are 598, 652, 706 and 760 pt; Thai row tops are 593, 636⅓, 679⅓, 722⅔ and 765⅔ pt. Both last rows end at 803 pt. UIKit adds its own wrapper and footer around a keyboard extension, so equal intrinsic heights alone do not establish equal on-screen positions.

The observed extension's primary view ends at 799 pt. All 292 visible key rectangles across the eight captured OLIV pages match the reference x-position, width and height at the pixel grid, but their y-positions are uniformly 4 pt higher. Changing `UIInputView.Style` and translating the root view did not remove that difference. The implementation keeps every visible key and its touch region within the primary view instead of drawing an untappable strip into the system footer. This is a measured limitation, not pixel-identical placement.

The system backdrop is also state-dependent on the tested runtime: captures of the same build show the glass starting either 17 pt above the primary view or at its top, with identical key positions. The latter state places the portrait glass top 17 pt below the Apple reference. A same-binary Apple→OLIV reentry capture (`TestResults/Build8PortraitReentry.xcresult`) restored the native backdrop position while leaving the key rectangles unchanged. A [developer report on Apple's forums](https://developer.apple.com/forums/thread/843093) describes the same host-owned inset changing after keyboard/app transitions without an extension-bounds or safe-area change. This is corroborating evidence, not an Apple-confirmed diagnosis or a supported workaround. OLIV does not alter private host constraints or compensate with a guessed extra height.

Thai follows the observed iPhone map: `_` in the first row, `ฃ` and `ฅ` at the end of the third row, and twelve equal key slots per letter row. Thai's number page uses `฿`; its secondary symbol page includes `$`, `€`, `¥`, `•`. English uses `$` on the number page and `€`, `£`, `¥`, `•` on the secondary page. Thai combining marks must insert their original Unicode scalars regardless of keycap rendering.

Public system-font outlines are optically aligned to measured native ink bounds and cached per label/text/font. Thai combining marks and Sara Am use a hidden shaping anchor; only the requested glyph is drawn and the original scalar is inserted. Uniform scaling preserves glyph proportions. Thai letters use the public system font's light weight, except Sara Am (`ำ`), for which regular is a closer measured fit. An actual-extension iOS 27 capture reduced the median Thai ink-area ratio against Apple from 1.244 to 1.030 on the lower page, and from 1.176 to 0.977 on Shift. A separate iOS 26 font experiment compared the renderer's regular/intermediate/light candidates before choosing the public weight. Sara Am and some curve/antialiasing details still differ; the remaining raster/outline differences are not presented as exact identity.

## Measured landscape geometry

The iPhone 17 reference rotates to 874 × 402 pt. UIKit supplies the two 75 pt side regions; the extension's primary width is 724 pt. Landscape has its own measured key rectangles and optical glyph metrics rather than stretched portrait keys.

| Property | English / numbers / symbols | Thai letters |
| --- | --- | --- |
| Primary view height, build 8/9 | 204 pt | 207 pt |
| First visible row, screen y | 228 pt | 225 pt |
| Key height / vertical gap | 32 / 8 pt | 27 / 5 pt |
| Last visible key bottom | 380 pt | 380 pt |
| System glass top | 178 pt | 175 pt |

The four Thai rows use twelve equal slots. Number and symbol pages use the English geometry with the language-specific currency mappings. Captured landscape PNGs carry an orientation tag; measurements apply that tag before computing dimensions.

## Key previews and touch delivery

The actual iOS 27 reference uses a separate floating rounded rectangle, without a connecting stem: approximately 58⅓ × 65⅔ pt, 14.5 pt corner radius and a 3 pt gap above the pressed key. Edge previews clamp to the left/right screen edge. Recorded q/f/p presses showed no intermediate scaled shape; adjacent captured frames bracketed appearance/disappearance, but the variable frame-rate recording cannot prove an exact animation duration. OLIV shows the preview immediately and retains both preview and pressed-key appearance for approximately 60 ms after committing the character, without adding a spring animation. The build 8 q/f/p hold test passed; recorded frames verify the same cap dimensions and the middle-row gap. Removing the old upward label translation brought the `f` ink center within about 0.17 pt vertically of the native cap-relative center. Its glyph outline, width and height still differ, so this is not an exact font or timing match.

The top-row native preview previously extended above the extension's primary view. A real iOS 27 experiment removed local clipping and placed q/p previews at negative y; the remote host still cut the upper cap and glyph at the primary-view boundary (`FeelUnclippedPopupExperiment`). Builds 8/9 therefore clamped the preview inside the view, overlapping the first row. Build 10 instead reserves additional space above the keys, as described below; the boundary guard remains for smaller or unmeasured layouts.

Actual button bounds cover the gaps between visible keycaps; noninteractive inset artwork keeps the visual spacing unchanged. Slide-to-neighbor commits the release target, sliding outside cancels, and a canceled touch cannot later insert text. Wide Space uses its visible edges rather than distance from the key's center.

## Build 12 tighter preview and faster Delete

The portrait top gap is now 41 pt (31 pt measured base offset plus 10 pt preview headroom), down from build 11's 51 pt. The cap shrinks from 45.667 to 35.667 pt while keeping the 36 pt font. Latin previews use the glyph outline's ink center instead of the font line box; Thai metrics retain their offsets, clamped by translation to a 2 pt vertical inset. No glyph is scaled down. This avoids the low descender alignment that previously required more empty space. A raster regression checks every character from both languages, shifted/unshifted letters, numbers and symbols against the same rendering in a spacious cap; size and containment pass.

The bottom-anchored keys keep their positions. Primary heights are 246/251 pt in portrait (English/Thai letters) and 204/207 pt in landscape. No additional landscape headroom remains. This still needs a real top gap to contain a visible preview inside the extension; it cannot eliminate that gap while retaining the same glyph size and separation.

Delete now uses a deliberately faster profile than the measured native one: 0.35 s initial repeat delay, 0.08 s character repeats, word acceleration after 1.55 s and 15 repeats, then the existing 0.35 s word cadence. Word eligibility no longer reads proxy context during character repeats or early timer wakeups. The guarded deletion session, context checks, bounded work and release cancellation are unchanged. The haptic duplicate guard is 60 ms, leaving tolerance below the new 80 ms cadence so a slightly early repeat does not lose its light pulse. Distinct key presses remain unthrottled.

[Physical timing evidence](Screenshots/keyboard-delete-build12.json) records same-device fixed English fixture runs. Native/build 11 first repeats were 0.4907/0.4903 s; build 12 was 0.3463 s. Character medians were 0.1000/0.0999/0.0794 s, and the first multi-scalar edits occurred at 2.5177/2.5121/1.5672 s. All traces preserve the input prefix and contain no edits after gesture return. These are host edit intervals, not finger-to-first-edit latency measurements; the original broader report of perceived lag is not disproved by the matched baseline fixture cadence.

Final raw captures verify **41 pt** from the primary view's top to the first row on both the physical phone and Simulator in the same portrait UITextView host. Physical English and Thai primary heights are 246/251 pt; first-key y remains 594/589 pt. [Physical English](Screenshots/keyboard-compact-build12-physical-english-q.png), [physical Thai](Screenshots/keyboard-compact-build12-physical-thai-top.png), [Thai mark](Screenshots/keyboard-compact-build12-physical-thai-mark.png), and [Simulator English](Screenshots/keyboard-compact-build12-simulator-english-q.png) preserve the original screenshots. [Metadata](Screenshots/keyboard-compact-build12.json) records exact geometry and differing accessibility settings: the phone has Reduce Transparency/Increase Contrast enabled, the Simulator does not. The fixture does not reproduce a larger physical top gap; the user-reported difference in other apps remains unestablished. No accessibility settings were changed.

## Build 11 compact preview

The selected compact design removes 20 pt of reserved height and 20 pt of popup frame height together. Extra first-row headroom is now 20 pt in portrait and 1 pt in landscape (previously 40/21 pt); the popup is 45.667 pt tall instead of 65.667 pt. The font remains 36 pt, the minimum width 58.333 pt and the key-to-popup gap 3 pt. Centering in the shorter cap moves the glyph 10 pt nearer its key, without reducing its size. The full popup stays inside the extension's public primary view.

Bottom-anchored key positions are preserved. The English letter surface is 256 pt portrait / 205 pt landscape; Thai letters are 261 / 208 pt. Number-pad layouts do not reserve popup headroom and are unaffected. This is a deliberate compactness tradeoff, not an exact reproduction of Apple's taller preview. Making the root input view transparent was also tried in an isolated Simulator probe; the system continued drawing its backdrop, so that approach is not shipped.

Raw physical captures show the compact [English q](Screenshots/keyboard-compact-build11-physical-english-q.png), [Thai first-row ๅ](Screenshots/keyboard-compact-build11-physical-thai-top.png), and [isolated Thai ิ](Screenshots/keyboard-compact-build11-physical-thai-mark.png). The phone's English primary view is `(0, 543, 402, 256)`; q is still at `(6.667, 594, 33.333, 43)`. Comparing held p against the build 10 physical light capture gives identical ink size, 16.667 × 24.667 pt. The glyph moves 10 pt down on screen as its cap top moves 20 pt down. These are held-state captures, not a new animation or perceived-haptic comparison.

All six real-extension hold sequences pass: physical English/light and Thai/dark portrait, plus Simulator English/Thai in light portrait and dark landscape. [Thai landscape](Screenshots/keyboard-compact-build11-simulator-thai-landscape.png) retains the full first-row preview. [Capture metadata](Screenshots/keyboard-compact-build11.json) includes primary-view/key frames, accessibility settings, unchanged-image hashes, result paths and the physical glyph comparison.

## Build 10 preview headroom and haptics

The standard English and Thai letter, number and symbol pages reserve **40 pt more height in portrait and 21 pt in landscape**. The keys move down by that same amount within the enlarged view, preserving their screen positions when the host anchors the keyboard at the bottom. This provides room for the complete 65⅔ pt preview, its 3 pt gap and the 2 pt boundary margin. Portrait primary heights become 276 pt for English/numbers/symbols and 281 pt for Thai letters; landscape heights become 225 and 228 pt respectively. The cost is that the blank keyboard header occupies more of the app's screen. It does not add predictions or remove the earlier key-position and host-backdrop differences. Number-pad and decimal-pad fields are excluded from this change; their preview geometry has not been established by the reference captures.

An isolated iOS 27 actual-extension prototype passed the q/f/p hold sequence with the new extension inside the previous test host. Raw screenshots were taken during each synthesized hold. They show complete q/p previews above the first row, with the measured gap and flush left/right edge positions; the middle-row f preview remains complete. The primary view is `(0, 523, 402, 276)` pt and visible English row tops remain **594, 648, 702 and 756 pt**, unchanged from the earlier OLIV capture. This is direct English portrait visual evidence. It is not a physical-device, Thai/landscape, App Group handoff or haptic-sensation result. [Raw captures and provenance](Screenshots/keyboard-popup-headroom-build10.json) preserve the staging and test details.

The physical build 10 Debug sequence subsequently passed in **light and dark appearance** (75.998 / 74.589 s; `Build10PhysicalPopupRun2-light` / `-dark`). Direct screenshots during each q/f/p hold show full caps and glyphs above the first row, while both the primary-view frame and visible key-row positions match the Simulator prototype. Increased Contrast and Reduce Transparency were enabled; VoiceOver was off. This establishes English portrait rendering on that phone, not Thai/landscape rendering or perceived haptic strength. The first attempt timed out before entering the test because iOS required the device owner's passcode to enable XCTest automation; the user completed that prompt before the successful retry. [Physical capture provenance](Screenshots/keyboard-popup-physical-build10.json) records settings, unchanged-image hashes and scope.

Build 10 requests a subtle haptic once at an enabled key's physical touch-down using Apple's public, view-associated [`UIImpactFeedbackGenerator`](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/init(style:view:)). A light impact uses intensity 0.35; a logical held-Delete repeat uses 0.20, with an 80 ms minimum repeat interval. Individual rapid key presses are not throttled, and a word deletion still requests one repeat pulse. Release, sliding onto another key and accessibility activation do not request duplicate pulses. VoiceOver and detached/hidden views suppress requests; cancellation or leaving the keyboard removes the generator interaction.

The generator is allocated only after a touch and prepared after a pulse for a likely next press, following Apple's [`prepare()` guidance](https://developer.apple.com/documentation/uikit/uifeedbackgenerator/prepare()). Its prepared state expires without an OLIV timer. No audio session, microphone, network request or persistent idle loop is involved. UIKit decides whether supported hardware actually produces feedback. The helper does not read or reproduce Apple's separate Keyboard Feedback setting, and [Apple's Open Access documentation](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard) does not establish a haptic guarantee with Full Access disabled. Unit/routing checks observe admitted generator requests, not physical vibration or perceived strength; those limits must remain separate from visual validation.

## Observed native press feedback

Further iOS 27 captures separate control presses from character presses. In light appearance, held Shift and Delete use a flat `#c5c5c9` fill and solid black filled icons; Delete's cross reveals the key fill. Their glyph bounds do not materially move. Shift changes the letter page to uppercase while held. Raw stills captured during three further 8-second native holds confirmed the following rendered colors on uniform hosts:

| Held element | Light / white host | Dark / black host |
| --- | --- | --- |
| Character key, upper→lower interior | grayscale 220→229 | grayscale 103→105 |
| Character popup, upper→lower interior | `#ffffff` throughout | grayscale 78→91 |
| Delete key | `#c5c5c9` throughout | `#828282` throughout |
| Delete filled icon | Black | White |

The character's observed edge highlight and upper darkening include the nearby popup shadow; these samples do not identify Apple's underlying material recipe. No character-key or glyph scaling/translation was resolved. All three capture tests passed (`Feel-native-f-light`, `Feel-native-f-dark`, `Feel-native-delete-dark` result bundles); a still was taken approximately two seconds into each actual hold, not after release.

For three prescribed 60 ms XCUI presses (`q`, `f`, `p`), **both** the popup and pressed key remained visible after text appeared in the field. Adjacent video PTS bound that persistence to 48–72, 42–68 and 43–73 ms respectively. Approximately 60 ms is therefore a measured implementation target; actual finger-release timing was not captured. No intermediate scaled or faded popup was resolved in those frames. Recorder process-start time is not video PTS zero, and `typeText` events are not evidence of physical rapid taps.

A separate host/keyboard appearance matrix shows that native keycaps also respond to the backdrop:

| Keyboard appearance / host background | Key fill | Inter-key/header backdrop |
| --- | --- | --- |
| Light / white | `#ffffff` | `#e2e3e8` |
| Light / black | `#f6f7fa` | `#c1c3c7` |
| Dark / black | `#444444` | `#202020` |
| Dark / white | `#575757` | `#373737` |

These are raw PNG samples from the same device/host geometry, not universal palette constants. A white fill at approximately 16% opacity over the measured dark backdrop reproduces both observed dark key fills; this is an empirical candidate, not a claim about Apple's private material implementation. Light caps do not fit the same simple blend. UIKit's public [keyboard input-view style](https://developer.apple.com/documentation/uikit/uiinputview/style/keyboard) remains the basis for host-aware blur and tint. `Scripts/measure_keyboard_press.py` reports key-relative glyph bounds and vertical/edge RGB profiles without altering the source images. The verified candidate's light held `f` matches the native pressed-key grayscale at all ten sampled heights (220, 221, 222, 224, 225, 227, 228, 229, 229, 229). Its dark pressed key remains 1–2 encoded RGB levels brighter in the lower portion. Raw light/dark captures confirm the preview glyph is visible. A mixed white-host/dark-keyboard capture also matches the native normal key/backdrop samples (`#575757` / `#373737`). These are specific measured matches, not a whole-keyboard identity claim.

The final three appearance tests passed (`Feel-verified-f-light`, `Feel-verified-f-dark`, `Feel-verified-short-light`). In the short-tap video, text is already visible while the popup and key remain pressed, then both clear in the same captured frame. Coarser variable-rate frames bound that persistence to approximately 13–82 ms across the three presses, consistent with the 60 ms implementation delay; they cannot independently measure exact finger-release timing.

## Physical contrast and build 9 behavior

Same-host captures from the paired iPhone 17 show why build 8 looked too dark: both Apple and OLIV rendered the backdrop as `#2b2b2b`, but native high-contrast keys were 106–107 gray while OLIV retained `#444444` and added an invented gray outline. Build 9 removes that outline and uses white at 30% opacity for high contrast, versus 16% normally. The normal dark-on-white-host render was also verified: OLIV and Apple both produced `#575757` keys over `#373737` glass. Light native high-contrast keys remain white over a `#d1d3d9` backdrop.

The physical host reports both Increased Contrast and Reduce Transparency enabled (default Large text, Bold Text and Reduce Motion off). Their independent contributions have not been separated. Physical feedback with these settings is a separate reference: the dark pressed character spans 133–136 gray and its popup is flat `#515151`; normal-contrast Simulator popups have the gradient in the table above. Physical held Delete is flat `#888888` in dark appearance and approximately `#b7b9bf` in light appearance, both with filled icons. The light physical pressed-character samples closely match the Simulator's 220–229 range. These are rendered observations, not copied private assets. The Debug fixture exports public contrast, transparency, motion, font and appearance metadata alongside its screenshots. A final Simulator actual-extension light hold reproduced all ten native sampled pressed-key grayscale values exactly; the normal dark pressed key remains 1–2 RGB levels brighter at lower samples. The popup glyph outline and subtle edge rendering still differ.

The physical English reference has no prediction bar: native glass starts at y573 pt, whereas OLIV's reserved header appeared at y546 or y563 pt after different host transitions. The resulting 27 or 10 pt difference is independent of the cap-color correction. The existing 4 pt key-position difference also remains. The extension cannot read Apple's private prediction preference or host geometry; these captures do not establish universal background-shape identity.

Build 9 retains the preview **and** depressed character for 60 ms after a committed touch. A new press replaces the old preview immediately; generation checks keep old dismissal tasks from hiding a newer key. Cancellations and leaving the keyboard remove feedback immediately. Shift acts on touch-down, supports holding while another finger types and restores the prior state on cancellation.

Held Delete starts with one host deletion, waits 0.5 s, repeats characters every 0.1 s, then accelerates at approximately 2.5 s to two lexical chunks per 0.35 s. English and Thai were measured independently against native. The actual OLIV Thai extension reached its first word pulse at 2.512 s after the first deletion, with native-matching word boundaries. Small scheduling delays do not accumulate and missed intervals cannot replay a burst. Word deletion is bounded by current document/selection/context checks; unavailable or unexpected context falls back to a single host deletion. No timer runs while idle. On the physical phone, the first word pulse occurred at 2.518 s (dark) and 2.522 s (light), close to native 2.531/2.528 s. The first seven accelerated suffixes matched exactly. Later OLIV pulses deleted `The` and a space separately, while native removed longer suffixes; over the 8-second hold OLIV removed 184 scalars versus native 201. All edits preserved a strict prefix and stopped after release. The conservative context checks may explain this partial-pulse behavior, but that cause is not established without proxy-context instrumentation. It remains a known difference, not an identity pass.

## Reproduction and limits

Run the opt-in `OlivKeyboardAppearance` scheme on a prepared Simulator with Apple English, Thai and OLIV enabled and the hardware keyboard disconnected. The scheme enables `OLIV_VISUAL_REFERENCE_TESTS=1` and includes the appearance, layout and real-touch cases. `OLIV_REFERENCE_APPEARANCE=dark` selects the dark reference; `OLIV_REFERENCE_TYPE` selects the field type; `OLIV_REFERENCE_ORIENTATION=landscape` requests rotation in the Debug-only fixture. Captures preserve full-screen PNGs, keyboard accessibility frames and hierarchies as test attachments. `Scripts/measure_keyboard.py` reads the original PNGs and reports key bounds, colors and glyph ink bounds; it does not rescale or repaint them. The comparison script preserves source pixels and records hashes, crop bounds and EXIF orientation in a JSON sidecar.

The surface uses a 1/255-alpha native-color wash over UIKit's material. A completely clear surface caused gap taps to disappear before reaching the extension on both tested runtimes. Opaque native color fixed the unchanged coordinate test; the minimal-alpha version then passed all four real touch cases while retaining the system material. Drawing an inset keycap inside a larger control is insufficient on its own. Light/dark raster tests also verify Shift, Delete and Return remain visible above the keycap layer.

The hold test uses `OLIV_REFERENCE_KEYBOARD` (default `English`) and `OLIV_REFERENCE_CHARACTER` (default `f`). Record the Simulator while it holds the key to inspect popup geometry and transitions; its before/after screenshots are not evidence of the held state.

Apple's prediction engine and private keyboard artwork are not exposed to extensions. UIKit also restricts drawing outside the extension's primary view. A blank header can provide room for previews, but does not reproduce Apple's word predictions. The system owns the globe/dictation footer. These boundaries, the observed host-backdrop variation, other iOS versions, different display settings and unmeasured field types prevent a universal 100% identity claim. See [Apple's custom keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html).

## Saved visual evidence

- Build 10 English portrait headroom prototype: raw [before](Screenshots/keyboard-popup-headroom-before-build10.png), [held q](Screenshots/keyboard-popup-headroom-held-q-build10.png), [held f](Screenshots/keyboard-popup-headroom-held-f-build10.png) and [held p](Screenshots/keyboard-popup-headroom-held-p-build10.png). The [JSON sidecar](Screenshots/keyboard-popup-headroom-build10.json) records unchanged-image hashes, staging, test result and measured key positions.
- Build 10 physical English portrait: [light f](Screenshots/keyboard-popup-physical-build10-light-held-f.png), [light p](Screenshots/keyboard-popup-physical-build10-light-held-p.png), [dark q](Screenshots/keyboard-popup-physical-build10-dark-held-q.png), [dark f](Screenshots/keyboard-popup-physical-build10-dark-held-f.png) and [dark p](Screenshots/keyboard-popup-physical-build10-dark-held-p.png), with [metadata](Screenshots/keyboard-popup-physical-build10.json). These are raw held-state screenshots. An unrelated notification in the light-q full-screen capture excludes it from saved repository evidence.
- Build 9 actual held-key feedback: [light/dark native and OLIV](Screenshots/keyboard-feedback-comparison-ios27.png), with unchanged crop pixels and source hashes in the adjacent JSON. OLIV crop origins compensate the existing 4 pt row offset only for comparison; the keyboard itself is not moved.
- Build 8 same-size portrait comparisons: [English](Screenshots/keyboard-comparison-english-ios27.png) and [Thai](Screenshots/keyboard-comparison-thai-ios27.png). Source hashes and exact unscaled crop rectangles are recorded in adjacent JSON files.
- Build 8 held-key comparison: [q / f / p popups](Screenshots/keyboard-popup-comparison-ios27.png), with frame timestamps, source hashes and measured bounds in the adjacent JSON.
- Final physical feedback comparison: [native and OLIV light/dark f and Delete](Screenshots/keyboard-feedback-comparison-physical.png), with both accessibility settings recorded and source hashes in the adjacent JSON. Normal-key outlines are gone; measured physical resting/pressed fills agree within 0–2 encoded RGB levels, except native dithering. The popup height, glyph and rim differences remain visible.
- Build 8 dark captures: [English](Screenshots/keyboard-english-dark.png), [Thai](Screenshots/keyboard-thai-dark.png).
- Build 8 landscape captures: [English](Screenshots/keyboard-landscape-english.png), [Thai](Screenshots/keyboard-landscape-thai.png).
- The alternate host-backdrop state, from the same build: [English](Screenshots/keyboard-english-compact-backdrop.png), [Thai](Screenshots/keyboard-thai-compact-backdrop.png).

The older linked comparisons are build 8 Simulator captures of the actual extension, not design mockups. The build 9 measurements above additionally use raw physical iPhone screenshots during Xcode-driven gestures; iPhone Mirroring is not required for those captures. Release 0.1.0 (9) was independently confirmed on the paired phone for that evidence. Current test outcomes and device-installation status are recorded in [TESTING.md](TESTING.md).

## Build 13–14 interaction changes

Key geometry, colors and popup appearance remain the measured build 12 values. Space trackpad gains vertical navigation, including paragraph crossings and blank lines. Build 14 reduces each vertical step from 24 to 12 pt, stabilizes axis turns, and resets fractional travel on a meaningful direction reversal. Visual wrapping is estimated because the extension has no host layout API; hidden paragraph probes assume LF separators. See [interaction behavior and limits](KEYBOARD.md#space-trackpad-and-delete--build-14).

The quicker Delete profile uses a 220 ms initial delay, 60 ms character cadence, and word eligibility after 900 ms plus ten completed repeats. Initial proxy observations are reused only synchronously; every resumed word operation still validates fresh document/selection/context before editing. Word tasks yield between issued deletions, and repeat refreshes are coalesced. Haptic requests use the same light generator with stronger 0.55 press / 0.32 repeat intensities and a 40 ms duplicate guard. No claim is made about a person's perceived vibration strength or measured finger-to-first-edit latency.
