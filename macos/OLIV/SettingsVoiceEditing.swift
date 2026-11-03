import AppKit
import SwiftUI

/// Settings › Voice editing: Command mode (#23) and translation (#24).
struct VoiceEditingSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @EnvironmentObject private var models: ModelState
    @ObservedObject private var voice: VoiceEditSettings
    @State private var newBundleID = ""
    @State private var appError: String?

    init(voice: VoiceEditSettings = .shared) {
        _voice = ObservedObject(wrappedValue: voice)
    }

    var body: some View {
        SettingsPane {
            SettingsNotice(text: "Both features run on this Mac with the cleanup model, Gemma E2B. The text you select or dictate is rewritten locally and never uploaded for editing.",
                           icon: "lock.shield")
            if !models.arePresent([RequiredModels.cleanup]) {
                SettingsNotice(text: "Download the cleanup model in Models & storage to use Command mode or translation.",
                               icon: "arrow.down.circle", warning: true)
            }
            commandCard
            translationCard
        }
    }

    // MARK: Command mode

    private var commandCard: some View {
        SettingsCard(title: "Command mode", icon: "wand.and.stars",
                     subtitle: "Edit text that’s already there with your voice.") {
            SettingsToggle(title: "Edit selected text by voice",
                           detail: "Select text in any app, hold the Command mode shortcut and say what to change. OLIV replaces the selection, and your undo shortcut puts the original back.",
                           isOn: $voice.commandEnabled)
            CommandShortcutField(voice: voice)
                .disabled(!voice.commandEnabled)
            if bindings.commandPaused {
                SettingsNotice(text: "The Command mode shortcut overlaps push-to-talk or undo: one of them contains all the other’s keys, so pressing one would trigger both. Command mode is paused until you choose a shortcut that doesn’t overlap.", icon: "exclamationmark.triangle", warning: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                example("ทำให้สุภาพขึ้น", "More polite")
                example("สั้นลง", "Shorter")
                example("สรุปเป็น bullet", "Bullet summary")
                example("แก้คำผิด", "Fix typos")
                example("เขียนเป็นอีเมล", "Turn into an email")
                example("ทางการขึ้น", "More formal")
            }
            Text("With nothing selected, Command mode edits the text OLIV just pasted, in apps that let OLIV read it. If OLIV isn’t confident in an edit, your text stays as it was. Verbatim apps and password managers are never edited.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.usesOLIVAPI {
                SettingsNotice(text: "With the OLIV API engine, the server transcribes your instruction and the edit runs on this Mac. The OLIV server doesn’t offer Command mode yet.",
                               icon: "info.circle")
            }
        }
    }

    /// The shortcuts as the controller resolves them, to say which are paused.
    private var bindings: ShortcutBindings {
        VoiceEditPolicy.bindings(voice.configuration, pushToTalk: settings.activeChords,
                                 undo: settings.undoHotkeyChord)
    }

    // MARK: Translation

    private var translationCard: some View {
        SettingsCard(title: "Speak Thai, type English", icon: "globe",
                     subtitle: "พูดไทย แล้ว OLIV จะพิมพ์เป็นภาษาอังกฤษให้") {
            SettingsToggle(title: "Secondary shortcut types English",
                           detail: "Hold your secondary push-to-talk shortcut and speak Thai, with English mixed in as usual. OLIV pastes natural English. Your primary shortcut keeps typing what you say.",
                           isOn: $voice.translateWithSecondary)
            if voice.translateWithSecondary, settings.hotkeySecondaryChord == nil {
                SettingsNotice(text: "Set a secondary shortcut in Keyboard shortcuts to use translation.",
                               icon: "exclamationmark.triangle", warning: true)
            }
            if bindings.translationPaused {
                SettingsNotice(text: "The secondary shortcut overlaps the primary or undo shortcut: one of them contains all the other’s keys, so pressing it would start plain dictation first. Translation is paused, and the secondary shortcut types what you say, until you choose one that doesn’t overlap.", icon: "exclamationmark.triangle", warning: true)
            }
            SettingsNotice(text: "พูดไทยปนอังกฤษได้ตามปกติ OLIV จะแปลออกมาเป็นภาษาอังกฤษที่อ่านลื่นเป็นธรรมชาติ ส่วนชื่อคน ชื่อสินค้า และศัพท์โค้ดจะคงไว้ตามเดิม คำใน Dictionary ของคุณก็ยังใช้ได้เหมือนเดิม",
                           icon: "character.bubble")
            Text("The recording pill shows “Thai → English” whenever translation is on. Names, product names and code terms stay as they are, and your Dictionary still applies. If OLIV isn’t confident in a translation, it pastes what you said instead.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Always translate in these apps").font(.system(size: 13, weight: .medium))
            if voice.translationApps.isEmpty {
                Text("None. Add an app where you always write in English, such as your email or chat app.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(voice.translationApps.sorted(), id: \.self) { bundleID in
                    appRow(bundleID)
                }
            }
            HStack {
                Button(action: addViaPanel) { Label("Choose an app…", systemImage: "plus") }
                TextField("com.tinyspeck.slackmacgap", text: $newBundleID)
                    .textFieldStyle(.roundedBorder).onSubmit(addTyped)
                    .accessibilityLabel("App bundle identifier")
                Button("Add", action: addTyped)
                    .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let appError { SettingsNotice(text: appError, warning: true) }
            if settings.usesOLIVAPI {
                SettingsNotice(text: "With the OLIV API engine, the server transcribes your Thai and the translation runs on this Mac. The OLIV server doesn’t translate yet.",
                               icon: "info.circle")
            }
        }
    }

    private func appRow(_ bundleID: String) -> some View {
        HStack(spacing: 10) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 26, height: 26)
            } else {
                Image(systemName: "app").font(.system(size: 20)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.deletingPathExtension().lastPathComponent ?? bundleID)
                    .font(.system(size: 13, weight: .medium))
                Text(bundleID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if settings.verbatimApps.contains(bundleID) {
                SettingsBadge(text: "Verbatim: not translated")
            }
            SettingsRemoveButton(item: bundleID) { voice.removeTranslationApp(bundleID) }
        }
    }

    private func example(_ phrase: String, _ meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phrase).font(.system(size: 12, weight: .medium))
            Text(meaning).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func addTyped() {
        guard !newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        voice.addTranslationApp(newBundleID)
        newBundleID = ""
        appError = nil
    }

    private func addViaPanel() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add app"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            appError = "This app has no bundle identifier. Choose another app or enter its identifier."
            return
        }
        voice.addTranslationApp(id)
        appError = nil
    }
}

/// Record the Command mode shortcut (same capture rules as push-to-talk).
private struct CommandShortcutField: View {
    @ObservedObject var voice: VoiceEditSettings
    @State private var recorder: HotkeyRecorder?
    @State private var isCapturing = false

    var body: some View {
        HStack(spacing: 12) {
            Text("Shortcut").font(.system(size: 13, weight: .medium))
                .frame(width: 85, alignment: .leading)
            Text(isCapturing ? "Press a shortcut…" : (voice.commandChord?.displayName ?? "None"))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isCapturing ? SettingsStyle.accent : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsStyle.border))
            Button(isCapturing ? "Cancel" : "Record") { toggleCapture() }
                .help("Click Record, then press the shortcut you want to hold for Command mode.")
            Menu {
                ForEach(HotkeyKey.all) { key in
                    Button(key.displayName) { cancel(); voice.commandHotkeyID = HotkeyChord(key: key).id }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).frame(width: 22)
            .help("Choose a preset shortcut")
            .accessibilityLabel("Presets for Command mode")
        }
        .onDisappear { cancel() }
    }

    private func toggleCapture() {
        if isCapturing { cancel(); return }
        let rec = HotkeyRecorder(
            onCapture: { chord in voice.commandHotkeyID = chord.id; finish() },
            onCancel: { finish() })
        recorder = rec
        isCapturing = true
        rec.start()
    }

    private func cancel() { recorder?.stop(); finish() }

    private func finish() {
        recorder = nil
        isCapturing = false
    }
}
