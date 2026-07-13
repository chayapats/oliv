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
        .frame(width: 520, height: 410)
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
        Form {
            HotkeyRecorderField()
            Text("Hold to record; release to transcribe and paste.")
                .font(.caption).foregroundStyle(.secondary)
            // Inline (non-blocking) warning: a text-typing key will insert
            // characters wherever the cursor is while it's held down.
            if HotkeyKey.typesText(keyCode: settings.hotkeyKey.keyCode) {
                Text("This key types text — dictation will hold it down; a modifier "
                     + "or function key is recommended.")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            MicrophonePicker()

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

/// The "record shortcut" capture control (W4-T2 Feature B): click the field →
/// "Press a key…" → the next physical key becomes the push-to-talk key (any
/// modifier or regular key; Escape cancels). A quick menu beside it keeps the
/// five named presets one click away. The captured key persists as
/// `settings.hotkeyID` (a HotkeyKey.id) and live-applies via the store's onChange.
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

private struct HotkeyRecorderField: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var recorder: HotkeyRecorder?
    @State private var isCapturing = false

    var body: some View {
        HStack(spacing: 8) {
            Text("Push-to-talk key")
            Button(action: toggleCapture) {
                Text(isCapturing ? "Press a key…  (Esc to cancel)" : settings.hotkeyKey.displayName)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .help("Click, then press the key you want to hold to dictate.")

            Menu {
                ForEach(HotkeyKey.all) { key in
                    Button(key.displayName) { choose(key) }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .frame(width: 42)
            .help("Pick a preset key")
        }
    }

    private func toggleCapture() {
        if isCapturing { cancelCapture(); return }
        let rec = HotkeyRecorder(
            onCapture: { key in choose(key); finish() },
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

    private func choose(_ key: HotkeyKey) {
        settings.hotkeyID = key.id
    }
}

// MARK: - Cleanup

private struct CleanupSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var newBundleID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Text("Verbatim apps (cleanup bypassed)").font(.headline)

            List {
                if settings.verbatimApps.isEmpty {
                    Text("No apps — cleanup applies everywhere.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.verbatimApps.sorted(), id: \.self) { bundleID in
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
                    }
                }
            }
            .frame(minHeight: 90)

            HStack {
                TextField("Bundle id (e.g. com.apple.dt.Xcode)", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Choose App…", action: addViaPanel)
            }
        }
        .padding()
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Replacements (snippets)").font(.headline)
            Text("When you say the spoken phrase, OLIV types the replacement — "
                 + "e.g. “อีเมลของผม” → your real email. Applied after cleanup, "
                 + "longest phrase first, never inside a real Thai word.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                if settings.replacements.isEmpty {
                    Text("No replacements yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.replacements.keys.sorted(), id: \.self) { spoken in
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
                    }
                }
            }
            .frame(minHeight: 120)

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
        .padding()
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Vocabulary").font(.headline)
            Text("Names, jargon, product names, or acronyms OLIV keeps mishearing. "
                 + "Unlike Replacements, these steer the transcription itself — so a "
                 + "term is spelled the way you want from the start. Applies to every "
                 + "dictation.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                if settings.vocabulary.isEmpty {
                    Text("No terms yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.vocabulary, id: \.self) { term in
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
                    }
                }
            }
            .frame(minHeight: 150)

            HStack {
                TextField("Term (e.g. Grafana, คูเบอร์เนติส, OLIV)", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
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
        VStack(alignment: .leading, spacing: 12) {
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
        .padding()
    }
}
