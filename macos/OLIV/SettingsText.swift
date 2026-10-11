import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CleanupSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var newBundleID = ""
    @State private var appError: String?

    var body: some View {
        SettingsPane {
            SettingsCard(title: "Polish your transcript", icon: "wand.and.stars", subtitle: "Keep the meaning. Make the text easier to read.") {
                SettingsToggle(title: "Enable text cleanup", detail: "Correct recognized words and clean up the transcript. Turn off to use the raw transcript in every app.",
                               isOn: $settings.cleanupEnabled)
                Divider()
                SettingsToggle(title: "Remove filler words", detail: "Remove standalone hesitations such as อืม, เอ่อ, um, uh and hmm before cleanup.",
                               isOn: $settings.removeFillers)
                Divider()
                SettingsToggle(title: "Format Thai numbers & repeated words", detail: "Write spoken numbers as digits and shorten repeated words: สี่สิบห้า → 45, มากมาก → มากๆ. Small counts stay as words. Applies when cleanup is enabled.",
                               isOn: $settings.thaiFormat)
            }
            SettingsCard(title: "Spoken formatting", icon: "text.alignleft", subtitle: "Control the structure of your text with your voice.") {
                SettingsToggle(title: "Enable formatting commands", detail: "Say a command to insert a line break, paragraph or bullet. Leave off if you want these phrases transcribed as text.",
                               isOn: $settings.formatCommands)
                    .disabled(settings.usesOLIVAPI)
                HStack(spacing: 8) {
                    commandExample("New line", "ขึ้นบรรทัดใหม่")
                    commandExample("New paragraph", "ย่อหน้าใหม่")
                    commandExample("Bullet point", "bullet point")
                }
                if settings.usesOLIVAPI {
                    SettingsNotice(text: "OLIV API doesn’t support spoken formatting yet. Your preference is kept for local engines.",
                                   icon: "info.circle", warning: true)
                }
            }
            SettingsCard(title: "Keep these apps verbatim", icon: "app.badge", subtitle: "Bypass cleanup in selected apps, such as terminals or code editors.") {
                if settings.verbatimApps.isEmpty {
                    SettingsEmptyState(icon: "app", title: "No app exceptions", detail: "When cleanup is enabled, it applies everywhere. Add an app to keep its transcripts raw.")
                } else {
                    ForEach(settings.verbatimApps.sorted(), id: \.self) { bundleID in
                        HStack(spacing: 10) {
                            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                            if let url {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 30, height: 30)
                            } else {
                                Image(systemName: "app").font(.system(size: 22)).foregroundStyle(.secondary)
                                    .frame(width: 30, height: 30)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url?.deletingPathExtension().lastPathComponent ?? bundleID)
                                    .font(.system(size: 13, weight: .medium))
                                Text(bundleID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            SettingsRemoveButton(item: bundleID) { settings.removeVerbatimApp(bundleID) }
                        }
                        if bundleID != settings.verbatimApps.sorted().last { Divider() }
                    }
                }
                Button(action: addViaPanel) { Label("Choose an app…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                DisclosureGroup("Add by bundle identifier") {
                    HStack {
                        TextField("com.apple.dt.Xcode", text: $newBundleID)
                            .textFieldStyle(.roundedBorder).onSubmit(addTyped)
                            .accessibilityLabel("App bundle identifier")
                        Button("Add", action: addTyped).disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 12))
                if let appError { SettingsNotice(text: appError, warning: true) }
            }
        }
    }

    private func commandExample(_ title: String, _ phrase: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(phrase).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
    private func addTyped() {
        guard !newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        settings.addVerbatimApp(newBundleID)
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
            appError = "This app has no bundle identifier. Choose another app or enter its identifier manually."
            return
        }
        settings.addVerbatimApp(id)
        appError = nil
    }
}

struct ReplacementsSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var newSpoken = ""
    @State private var newReplacement = ""
    @State private var editingSpoken: String?

    var body: some View {
        SettingsPane {
            SettingsNotice(text: "For example, say “อีเมลของผม” to insert your email address. Replacements run after transcription and cleanup; the longest matching phrase is applied first.", icon: "text.quote")
            SettingsCard(title: editingSpoken == nil ? "Add a replacement" : "Edit replacement", icon: "plus.circle", subtitle: "A phrase you say, and the exact text OLIV should type.") {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("When I say").font(.system(size: 12, weight: .medium))
                        TextField("e.g. my email", text: $newSpoken).textFieldStyle(.roundedBorder)
                            .onSubmit(save).accessibilityLabel("Spoken phrase")
                    }
                    Image(systemName: "arrow.right").foregroundStyle(SettingsStyle.accent).padding(.top, 28)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Type this").font(.system(size: 12, weight: .medium))
                        TextField("e.g. hello@example.com", text: $newReplacement).textFieldStyle(.roundedBorder)
                            .onSubmit(save).accessibilityLabel("Replacement text")
                    }
                }
                HStack {
                    if trimmedSpoken != editingSpoken, settings.replacements[trimmedSpoken] != nil {
                        Text("This phrase already exists and will be updated.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if editingSpoken != nil { Button("Cancel", action: clearDraft) }
                    Button(editingSpoken != nil ? "Save changes" : (settings.replacements[trimmedSpoken] != nil ? "Update replacement" : "Add replacement"), action: save)
                        .buttonStyle(.borderedProminent).disabled(!canSave)
                }
            }
            SettingsCard(title: "Your replacements · \(settings.replacements.count)", icon: "arrow.left.arrow.right") {
                if settings.replacements.isEmpty {
                    SettingsEmptyState(icon: "text.badge.plus", title: "Less speaking, more doing", detail: "Create shortcuts for emails, links, addresses or phrases you use often.")
                } else {
                    HStack {
                        Text("SPOKEN PHRASE").frame(maxWidth: .infinity, alignment: .leading)
                        Text("REPLACEMENT").frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 64)
                    }
                    .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    ForEach(settings.replacements.keys.sorted(), id: \.self) { spoken in
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            Text(spoken).frame(maxWidth: .infinity, alignment: .leading)
                            Text(settings.replacements[spoken] ?? "").frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Button {
                                editingSpoken = spoken
                                newSpoken = spoken
                                newReplacement = settings.replacements[spoken] ?? ""
                            } label: { Image(systemName: "pencil").frame(width: 26, height: 26) }
                            .buttonStyle(.borderless).help("Edit replacement").accessibilityLabel("Edit \(spoken)")
                            SettingsRemoveButton(item: spoken) {
                                settings.removeReplacement(spoken)
                                if editingSpoken == spoken { clearDraft() }
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }
    private var trimmedSpoken: String { newSpoken.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedSpoken.isEmpty && !newReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func save() {
        guard canSave else { return }
        if let original = editingSpoken, original != trimmedSpoken { settings.removeReplacement(original) }
        settings.setReplacement(spoken: newSpoken, replacement: newReplacement)
        clearDraft()
    }
    private func clearDraft() {
        newSpoken = ""
        newReplacement = ""
        editingSpoken = nil
    }
}

struct VocabularySettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var newTerm = ""

    var body: some View {
        SettingsPane {
            SettingsNotice(text: "Vocabulary guides recognition from the start. Add names, technical terms or acronyms OLIV mishears. Use Replacements for phrases that should expand into different text.", icon: "character.book.closed")
            SettingsCard(title: "Teach OLIV a word", icon: "plus.circle", subtitle: "Use the spelling you want to see in your transcript.") {
                HStack(spacing: 10) {
                    TextField("e.g. Grafana, Kubernetes, ชยพัฒน์", text: $newTerm)
                        .textFieldStyle(.roundedBorder).onSubmit(addTyped).accessibilityLabel("Vocabulary term")
                    Button("Add word", action: addTyped).buttonStyle(.borderedProminent)
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Custom vocabulary applies to every dictation.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            SettingsCard(title: "Your vocabulary · \(settings.vocabulary.count)", icon: "character.book.closed") {
                if settings.vocabulary.isEmpty {
                    SettingsEmptyState(icon: "character.cursor.ibeam", title: "Make it your vocabulary", detail: "Start with your name, a project, or a word you often have to correct.")
                } else {
                    ForEach(Array(settings.vocabulary.enumerated()), id: \.element) { index, term in
                        if index > 0 { Divider() }
                        HStack {
                            Text(term).font(.system(size: 13)).textSelection(.enabled)
                            Spacer()
                            SettingsRemoveButton(item: term) { settings.removeVocabularyTerm(term) }
                        }
                    }
                }
            }
        }
    }
    private func addTyped() {
        guard !newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        settings.addVocabularyTerm(newTerm)
        newTerm = ""
    }
}
