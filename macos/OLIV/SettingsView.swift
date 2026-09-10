// Settings window — real, persisted controls (W3-T4). Replaces the W3-T1
// placeholder. Values live in OLIVSettings (UserDefaults, "oliv." namespace)
// and are pushed into the running DictationController live via the coordinator's
// settings.onChange, so engine / cleanup / hotkey / verbatim changes take effect
// on the next utterance (a hotkey change restarts the tap) with no relaunch.
//
//   General       — hotkey picker + engine picker + launch-at-login
//   Cleanup       — global toggle + filler-word toggle + formatting commands +
//                   per-app verbatim list
//   Replacements  — user snippets (spoken phrase → replacement), add/remove
//   Vocabulary    — custom terms that bias recognition (B3), add/remove
//   Models        — storage path + per-repo state/size + Download / Re-check
//
// The Models tab reuses the SAME download flow as first-run onboarding
// (ModelState.download), so there is one code path for fetching models.

import AppKit
import Combine
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            CleanupSettingsView()
                .tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            ReplacementsSettingsView()
                .tabItem { Label("Replacements", systemImage: "arrow.left.arrow.right") }
            VocabularySettingsView()
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "square.and.arrow.down") }
        }
        // Fixed window (a Settings scene isn't user-resizable); every pane scrolls
        // (SettingsPane / the General Form is wrapped in a ScrollView) so a pane
        // taller than this height scrolls instead of clipping its top and bottom
        // rows. Panes grew past the old 410 (mic picker, cloud fallback, the Thai
        // toggle) and macOS neither scrolls nor resizes an over-tall pane on its own.
        .frame(width: 520, height: 460)
    }
}

// MARK: - Layout helpers

/// Wraps a settings pane's content in a ScrollView so a pane taller than the
/// fixed window scrolls rather than clipping (macOS clips an over-tall pane, it
/// doesn't scroll it). Content is top-aligned and full-width — a short pane
/// leaves space below instead of floating vertically centred.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

/// A bordered, non-scrolling stand-in for `List`, for use inside a SettingsPane's
/// ScrollView — a real `List` can't live in a ScrollView (it demands unbounded
/// height and collapses to nothing). These collections are small and
/// user-curated, so a plain stack of rows is enough; the pane does the scrolling.
private struct SettingsListBox<Content: View>: View {
    var minHeight: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @EnvironmentObject private var models: ModelState
    @State private var launchEnabled = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    /// Per-engine weights presence (engine id → weights on disk), refreshed on
    /// appear and when a download finishes — cached in state so the picker
    /// isn't re-scanning the models dir on every render.
    @State private var enginePresence: [String: Bool] = [:]

    var body: some View {
      ScrollView {
        Form {
            Text("Push-to-talk")
                .font(.headline)
            HotkeyRecorderField(slot: .primary)
            HotkeyRecorderField(slot: .secondary)
            Text("Hold the full shortcut to record (chords like Control + Option + F17 are OK). Release any key to stop.")
                .font(.caption).foregroundStyle(.secondary)
            // Inline (non-blocking) warning: a text-typing key will insert
            // characters wherever the cursor is while it's held down.
            if settings.activeChords.contains(where: \.typesText) {
                Text("This shortcut types text — dictation will hold it down; a modifier "
                     + "or function key is recommended.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HotkeyRecorderField(slot: .undo)
            Text("Press once after a bad paste to undo it (sends ⌘Z). Default Control+Shift+Z. "
                 + "Cleared after one successful undo.")
                .font(.caption).foregroundStyle(.secondary)
            if let undo = settings.undoHotkeyChord, settings.activeChords.contains(undo) {
                Text("This matches a push-to-talk shortcut — pick a different undo key.")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            MicrophonePicker()

            Divider()

            SpeakerBleedControls()

            Divider()

            Toggle("Show recording indicator", isOn: $settings.showRecordingIndicator)
            Text("A floating pill with a live waveform while you dictate.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("Keep recent transcripts in the menu", isOn: $settings.historyEnabled)
            Text("The last 10 dictations, in memory only — cleared when this is "
                 + "turned off and when OLIV quits. Click one to copy it back.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Picker("STT engine", selection: $settings.engineID) {
                // Gated: the cloud engine only appears while the fallback toggle
                // is on AND a key is present (see OLIVSettings.availableEngines).
                ForEach(settings.availableEngines) { engine in
                    Text(engine.displayName + (needsDownload(engine) ? "  (not downloaded)" : ""))
                        .tag(engine.id)
                }
            }
            Text("Takes effect on the next utterance — no restart.")
                .font(.caption).foregroundStyle(.secondary)
            // Ready-before-dictate: an engine whose weights aren't on disk would
            // otherwise fail its first utterance with a generic "Couldn't
            // transcribe" (the sidecar loads offline by design). Say so here and
            // offer the SAME download flow as onboarding / the Models tab.
            if let repo = missingEngineRepo {
                Label("This engine's model isn't on this Mac yet — dictation "
                      + "with it will fail until it's downloaded.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                HStack(spacing: 8) {
                    Button {
                        models.download([repo])
                    } label: {
                        Label("Download model", systemImage: "square.and.arrow.down")
                    }
                    .disabled(models.isDownloading)
                    if models.isDownloading {
                        // Determinate linear bar — a bare spinner reads as
                        // "stuck" during a multi-GB fetch; the sidecar already
                        // streams whole percents. Only when THIS repo has a
                        // progress line though: a download started elsewhere
                        // (onboarding/Models fetch RequiredModels.all, which
                        // may not include this engine's repo) must not render
                        // a frozen determinate 0% for a repo it isn't fetching.
                        if let pct = models.progressByRepo[repo] {
                            ProgressView(value: Double(pct), total: 100)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: .infinity)
                            Text("\(pct)%")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                if let err = models.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Divider()

            // Cloud fallback (W3-T4): OFF by default. OLIV is local-first, so
            // audio only leaves the Mac when the user opts in here AND selects the
            // Groq engine above.
            Text("Cloud fallback").font(.headline)
            Toggle("Enable Groq cloud engine (sends audio to Groq)",
                   isOn: $settings.groqCloudEnabled)
            SecureField("Groq API key", text: $settings.groqAPIKey)
                .textFieldStyle(.roundedBorder)
                .disabled(!settings.groqCloudEnabled)
            Text("Audio leaves your Mac only when the Groq engine is selected as "
                 + "the STT engine above. Every other engine runs entirely on-device. "
                 + "The key is stored in your macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("Launch at login", isOn: Binding(
                get: { launchEnabled },
                set: { setLaunch($0) }))
            Text(LaunchAtLogin.statusDescription())
                .font(.caption).foregroundStyle(.secondary)
            if let err = launchError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .onAppear {
            launchEnabled = LaunchAtLogin.isEnabled
            refreshEnginePresence()
        }
        // A finished download (isDownloading true → false) must flip the picker
        // state live; models.repos also republishes then via recheck().
        .onChange(of: models.isDownloading) { downloading in
            if !downloading { refreshEnginePresence() }
        }
      }
    }

    /// The weights repo the SELECTED engine still needs, or nil when ready.
    private var missingEngineRepo: String? {
        OLIVSettings.missingRepo(for: settings.engineID) { repo in
            enginePresence[repo] ?? false
        }
    }

    private func needsDownload(_ engine: OLIVSettings.Engine) -> Bool {
        guard let repo = engine.repo else { return false }
        return !(enginePresence[repo] ?? false)
    }

    /// One disk scan per engine repo, cached into state (keyed by REPO id —
    /// missingRepo and needsDownload both look presence up by repo).
    private func refreshEnginePresence() {
        var presence: [String: Bool] = [:]
        for engine in OLIVSettings.Engine.all {
            if let repo = engine.repo {
                presence[repo] = ModelState.diskInfo(repo).present
            }
        }
        enginePresence = presence
    }

    private func setLaunch(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchError = nil
        } catch {
            // Surface the failure and reflect the real status rather than lying.
            launchError = "Could not \(enabled ? "enable" : "disable") launch at login: \(error). "
                + "Move OLIV to /Applications and try again."
        }
        launchEnabled = LaunchAtLogin.isEnabled
    }
}

/// Mic picker. Defaults to the built-in mic and says plainly what a Bluetooth mic
/// costs — because macOS silently promotes a paired headset to default input, and
/// dictating through one eats the first ~1 s of speech while its link wakes AND
/// drops that headset's own playback from 48 kHz stereo to a 24 kHz mono call
/// profile (music goes tinny and stutters). Both were measured on AirPods Pro; see
/// AudioDevices. Users can still choose the headset — they just get to know.
private struct MicrophonePicker: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var devices: [InputDevice] = []
    @State private var systemDefaultID: AudioDeviceID = 0

    /// Devices come and go while Settings is open (AirPods connect, a dock is
    /// unplugged). A picker still listing a mic that is no longer there is how a
    /// user ends up selecting one that records nothing.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var systemDefaultName: String {
        devices.first(where: { $0.id == systemDefaultID })?.name ?? "none"
    }

    private var warnsAboutBluetooth: Bool {
        AudioDevices.resolvesToBluetooth(
            selection: settings.micDevice, devices: devices, systemDefaultID: systemDefaultID)
    }

    var body: some View {
        Picker("Microphone", selection: $settings.micDevice) {
            Text("Built-in microphone").tag(MicSelection.builtIn)
            Text("System default — \(systemDefaultName)").tag(MicSelection.systemDefault)
            if !devices.isEmpty {
                Divider()
                ForEach(devices) { device in
                    Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name)
                        .tag(device.uid)
                }
            }
        }

        Group {
            if warnsAboutBluetooth {
                Label("A Bluetooth mic switches your headphones to call quality — music "
                      + "and video go mono and stutter while you dictate — and its link "
                      + "takes about a second to wake, so speak only once the pill shows "
                      + "a waveform.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("The built-in mic records instantly and leaves Bluetooth headphone "
                     + "audio untouched — you can still wear AirPods to listen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        devices = AudioDevices.inputDevices()
        systemDefaultID = AudioDevices.systemDefaultInputID()
    }
}

/// The 0.1.10 speaker-bleed pair. Music playing out loud goes into the mic along
/// with the speech, and STT does not just get less accurate on it — it INVENTS
/// text from it. One switch cancels the echo of what the Mac is playing; the
/// other turns that playback down for the length of the hold. Both default ON,
/// and both are worth stating plainly rather than hiding behind a single
/// "improve audio" toggle, because each has a visible side effect (a filtered
/// mic; music that dips while you talk).
private struct SpeakerBleedControls: View {
    @EnvironmentObject private var settings: OLIVSettings

    var body: some View {
        Toggle("Cancel speaker echo", isOn: $settings.echoCancellation)
        Text("Subtracts what your Mac is playing from what the mic hears, so music "
             + "and video don't end up in your transcript. Applies when the mic "
             + "above is also your system input device; skipped with Bluetooth "
             + "audio, which doesn't leak into the mic anyway.")
            .font(.caption).foregroundStyle(.secondary)

        Toggle("Lower other audio while dictating", isOn: $settings.duckOtherAudio)
        Text("Dips playback while you hold the key and brings it back when you let "
             + "go. Your volume is left alone if you change it yourself mid-sentence. "
             + "With echo cancellation on, macOS handles the dip — turning this off "
             + "asks for as little as macOS allows rather than none at all.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private enum HotkeySlot {
    case primary, secondary, undo

    /// Short Form labels — "Primary/Secondary push-to-talk" overflowed the
    /// fixed label column (520-wide Settings window) and crushed the key name.
    var label: String {
        switch self {
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        case .undo: return "Undo last"
        }
    }
}

/// The "record shortcut" capture control (W4-T2 Feature B): click Set →
/// "Press a key…" → the next physical key becomes that slot's push-to-talk key
/// (any modifier or regular key; Escape cancels). A quick menu beside it keeps
/// the five named presets one click away. Secondary may be cleared (None).
///
/// The key NAME sits outside the button on purpose — putting "Right Control"
/// inside a bordered button in a Form column truncated it to look like
/// "Control" while the binding still worked (keycode was fine).
private struct HotkeyRecorderField: View {
    let slot: HotkeySlot
    @EnvironmentObject private var settings: OLIVSettings
    @State private var recorder: HotkeyRecorder?
    @State private var isCapturing = false

    var body: some View {
        LabeledContent(slot.label) {
            HStack(spacing: 8) {
                Text(isCapturing ? "Press a key…" : displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCapturing ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(displayName)

                Button(isCapturing ? "Cancel" : "Set") {
                    toggleCapture()
                }
                .buttonStyle(.bordered)
                .help(captureHelp)

                Menu {
                    if slot == .secondary || slot == .undo {
                        Button("None") { clearOptionalSlot() }
                        Divider()
                    }
                    ForEach(HotkeyKey.all) { key in
                        Button(key.displayName) { chooseKey(key) }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .frame(width: 42)
                .help((slot == .secondary || slot == .undo)
                      ? "Pick a preset, or None to clear"
                      : "Pick a preset key")
            }
        }
        .id(slot.label)
    }

    private var displayName: String {
        switch slot {
        case .primary: return settings.hotkeyChord.displayName
        case .secondary: return settings.hotkeySecondaryChord?.displayName ?? "None"
        case .undo: return settings.undoHotkeyChord?.displayName ?? "None"
        }
    }

    private var captureHelp: String {
        if isCapturing {
            return "Hold modifiers, then press the main key (e.g. Control+Option+F17). Or press/release a single modifier. Esc cancels."
        }
        switch slot {
        case .primary:
            return "Click Set, then press the shortcut you want to hold to dictate."
        case .secondary:
            return "Optional second shortcut — hold either binding to dictate."
        case .undo:
            return "Click Set, then press the shortcut that undoes the last paste."
        }
    }

    private func toggleCapture() {
        if isCapturing { cancelCapture(); return }
        let rec = HotkeyRecorder(
            onCapture: { chord in choose(chord); finish() },
            onCancel: { finish() })
        recorder = rec
        isCapturing = true
        rec.start()
    }

    private func cancelCapture() { recorder?.stop(); finish() }

    private func finish() {
        recorder = nil
        isCapturing = false
    }

    private func choose(_ chord: HotkeyChord) {
        switch slot {
        case .primary: settings.hotkeyID = chord.id
        case .secondary: settings.hotkeySecondaryID = chord.id
        case .undo: settings.undoHotkeyID = chord.id
        }
    }

    private func chooseKey(_ key: HotkeyKey) {
        choose(HotkeyChord(key: key))
    }

    private func clearOptionalSlot() {
        switch slot {
        case .secondary: settings.hotkeySecondaryID = ""
        case .undo: settings.undoHotkeyID = ""
        case .primary: break
        }
    }
}

// MARK: - Cleanup

private struct CleanupSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var newBundleID = ""

    var body: some View {
        SettingsPane {
            Toggle("Cleanup (dictionary → gate → LLM → guardrails)", isOn: $settings.cleanupEnabled)
            Text("When off, every app gets the raw transcript. The list below keeps "
                 + "specific apps verbatim even while cleanup is on.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("Remove filler words", isOn: $settings.removeFillers)
            Text("Strips standalone hesitations (อืม, เอ่อ, อ่า, um, uh, er, hmm) "
                 + "before cleanup runs. On by default.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("Spoken formatting commands", isOn: $settings.formatCommands)
            Text("Say “ขึ้นบรรทัดใหม่ / new line”, “ย่อหน้าใหม่ / new paragraph”, or "
                 + "“bullet point” to insert a line break. Off by default — a command "
                 + "phrase can also be real text.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("Format numbers & repeated words", isOn: $settings.thaiFormat)
            Text("Collapses repeated words to ๆ (มากมาก → มากๆ) and writes spoken numbers "
                 + "from ten up as digits (สี่สิบห้า → 45, สองจุดห้า → 2.5). Small counts "
                 + "stay words. On by default.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("Verbatim apps (cleanup bypassed)").font(.headline)

            SettingsListBox(minHeight: 90) {
                if settings.verbatimApps.isEmpty {
                    Text("No apps — cleanup applies everywhere.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                } else {
                    ForEach(Array(settings.verbatimApps.sorted().enumerated()), id: \.element) { index, bundleID in
                        if index > 0 { Divider() }
                        HStack {
                            Text(bundleID).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                settings.removeVerbatimApp(bundleID)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
            }

            HStack {
                TextField("Bundle id (e.g. com.apple.dt.Xcode)", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Choose App…", action: addViaPanel)
            }
        }
    }

    private func addTyped() {
        settings.addVerbatimApp(newBundleID)
        newBundleID = ""
    }

    /// Pick an app in /Applications and derive its bundle id via Bundle(url:).
    private func addViaPanel() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bid = Bundle(url: url)?.bundleIdentifier {
            settings.addVerbatimApp(bid)
        }
    }
}

// MARK: - Replacements

private struct ReplacementsSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var newSpoken = ""
    @State private var newReplacement = ""

    var body: some View {
        SettingsPane {
            Text("Replacements (snippets)").font(.headline)
            Text("When you say the spoken phrase, OLIV types the replacement — "
                 + "e.g. “อีเมลของผม” → your real email. Applied after cleanup, "
                 + "longest phrase first, never inside a real Thai word.")
                .font(.caption).foregroundStyle(.secondary)

            SettingsListBox(minHeight: 120) {
                if settings.replacements.isEmpty {
                    Text("No replacements yet.").foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                } else {
                    ForEach(Array(settings.replacements.keys.sorted().enumerated()), id: \.element) { index, spoken in
                        if index > 0 { Divider() }
                        HStack(spacing: 8) {
                            Text(spoken)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(settings.replacements[spoken] ?? "")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Button {
                                settings.removeReplacement(spoken)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
            }

            HStack {
                TextField("Spoken phrase", text: $newSpoken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Replacement", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(newSpoken.trimmingCharacters(in: .whitespaces).isEmpty
                              || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addTyped() {
        settings.setReplacement(spoken: newSpoken, replacement: newReplacement)
        newSpoken = ""
        newReplacement = ""
    }
}

// MARK: - Vocabulary

/// B3 custom vocabulary: user terms (names, jargon, product names, acronyms)
/// that bias RECOGNITION toward them — the fix for words STT hears wrong, which
/// Replacements (a text rewrite of what STT already produced) can't do. Terms
/// are sent as a Whisper initial_prompt on every dictate.
private struct VocabularySettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var newTerm = ""

    var body: some View {
        SettingsPane {
            Text("Vocabulary").font(.headline)
            Text("Names, jargon, product names, or acronyms OLIV keeps mishearing. "
                 + "Unlike Replacements, these steer the transcription itself — so a "
                 + "term is spelled the way you want from the start. Applies to every "
                 + "dictation.")
                .font(.caption).foregroundStyle(.secondary)

            SettingsListBox(minHeight: 150) {
                if settings.vocabulary.isEmpty {
                    Text("No terms yet.").foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                } else {
                    ForEach(Array(settings.vocabulary.enumerated()), id: \.element) { index, term in
                        if index > 0 { Divider() }
                        HStack {
                            Text(term)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Button {
                                settings.removeVocabularyTerm(term)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
            }

            HStack {
                TextField("Term (e.g. Grafana, คูเบอร์เนติส, OLIV)", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addTyped() {
        settings.addVocabularyTerm(newTerm)
        newTerm = ""
    }
}

// MARK: - Models

private struct ModelsSettingsView: View {
    @EnvironmentObject private var models: ModelState

    /// Overall download progress = mean of per-repo percent across the
    /// required repos (a repo with no line yet counts as 0) — the same
    /// computation OnboardingView uses for its bar.
    private var overallProgress: Double {
        let repos = models.repos.map(\.repo)
        guard !repos.isEmpty else { return 0 }
        let sum = repos.reduce(0) { $0 + (models.progressByRepo[$1] ?? 0) }
        return Double(sum) / Double(repos.count * 100)
    }

    var body: some View {
        SettingsPane {
            HStack {
                Text("Storage").font(.headline)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: models.storagePath)
                }
                .disabled(!FileManager.default.fileExists(atPath: models.storagePath))
            }
            Text(models.storagePath)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            ForEach(models.repos) { info in
                HStack {
                    Image(systemName: info.present ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(info.present ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.displayName)
                        Text(info.repo).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if models.isDownloading, let pct = models.progressByRepo[info.repo] {
                        Text("\(pct)%").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text(info.sizeText).foregroundStyle(.secondary)
                    }
                }
            }

            if models.isDownloading {
                // Determinate overall bar (mean per-repo percent, the same
                // computation onboarding uses) — an indeterminate barber pole
                // reads as "stuck" over a multi-GB fetch.
                ProgressView(value: overallProgress)
                    .progressViewStyle(.linear)
            }
            if let err = models.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button {
                    models.download()
                } label: {
                    Label(models.allPresent ? "Re-download" : "Download", systemImage: "square.and.arrow.down")
                }
                .disabled(models.isDownloading)

                Button("Re-check") { models.recheck() }
                    .disabled(models.isDownloading)
            }
        }
    }
}
