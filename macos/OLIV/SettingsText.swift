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

// MARK: Dictionary

/// A saved CSV payload for the Dictionary export sheet.
struct DictionaryCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String = "") { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// The Dictionary page: vocabulary words and misspelling corrections in one
/// searchable list, with enable/star toggles, edit/delete, bulk delete, CSV
/// import/export, sync status, and the auto-learn inbox.
struct DictionarySettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sync: DictionarySync
    @State private var search = ""
    @State private var newWord = ""
    @State private var newCorrection = ""
    @State private var wantsCorrection = false
    /// A near-miss found after adding a word, asked about right away.
    @State private var pendingSuggestion: AutoLearnCandidate?
    @State private var editingID: String?
    @State private var editWord = ""
    @State private var editCorrection = ""
    @State private var editWantsCorrection = false
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument = DictionaryCSVDocument()
    @State private var importMessage: String?
    @State private var importWarning = false

    private var filtered: [DictionaryEntry] { settings.dictionarySearch(search) }

    var body: some View {
        SettingsPane {
            if !settings.autoLearnCandidates.isEmpty { suggestionsCard }

            SettingsNotice(text: "Vocabulary words bias recognition from the start — add names, jargon or spellings OLIV mishears. Turn on “Correct a misspelling” when you say one thing and want different text typed. Starred words are sent to recognition first.",
                           icon: "book.closed")

            SettingsCard(title: "Add word", icon: "plus.circle",
                         subtitle: "Use the spelling you want to see in your transcript.") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Word").font(.system(size: 12, weight: .medium))
                    TextField("e.g. Grafana, ชยพัฒน์", text: $newWord)
                        .textFieldStyle(.roundedBorder).onSubmit(addEntry)
                        .accessibilityLabel("Word")
                }
                Toggle("Correct a misspelling", isOn: $wantsCorrection)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityLabel("Correct a misspelling")
                if wantsCorrection {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("When I say / STT hears").font(.system(size: 12, weight: .medium))
                        TextField("e.g. grafannah", text: $newCorrection)
                            .textFieldStyle(.roundedBorder).onSubmit(addEntry)
                            .accessibilityLabel("Misspelling")
                    }
                }
                if newWord.count > DictionaryEntry.warnFieldLength
                    || newCorrection.count > DictionaryEntry.warnFieldLength {
                    Text("Long, but it will still save (up to \(DictionaryEntry.maxFieldLength) characters).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    if wantsCorrection, !trimmedCorrection.isEmpty,
                       settings.dictionaryEntries.contains(where: {
                           $0.correction.map(DictionaryEntry.trimmed) == trimmedCorrection
                               && DictionaryEntry.dedupeKey(for: $0.word) != DictionaryEntry.dedupeKey(for: trimmedWord)
                       }) {
                        Text("This misspelling already corrects another word.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add word", action: addEntry)
                        .buttonStyle(.borderedProminent).disabled(!canAdd)
                }
                syncStatus
            }

            SettingsCard(title: "Your dictionary · \(settings.dictionaryEntries.count)", icon: "book.closed") {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search words or misspellings", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search dictionary")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                    }
                }
                HStack {
                    Button(selectMode ? "Done" : "Select") {
                        selectMode.toggle()
                        if !selectMode { selection.removeAll() }
                    }
                    .font(.system(size: 12))
                    if selectMode {
                        Button("Select all") { selection = Set(filtered.map(\.id)) }
                            .font(.system(size: 12)).disabled(filtered.isEmpty)
                        Spacer()
                        Button("Delete selected (\(selection.count))") { deleteSelected() }
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .disabled(selection.isEmpty)
                    } else {
                        Spacer()
                        Text("\(filtered.count) shown")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if filtered.isEmpty {
                    SettingsEmptyState(
                        icon: "character.cursor.ibeam",
                        title: settings.dictionaryEntries.isEmpty ? "Make it your vocabulary" : "No matches",
                        detail: settings.dictionaryEntries.isEmpty
                            ? "Start with your name, a project, or a word you often have to correct."
                            : "Try a different search.")
                } else {
                    ForEach(filtered) { entry in
                        if entry.id != filtered.first?.id { Divider() }
                        dictionaryRow(entry)
                    }
                }
            }

            SettingsCard(title: "Import & export", icon: "arrow.up.arrow.down") {
                HStack(spacing: 10) {
                    Button("Import CSV…") { showImporter = true }
                        .buttonStyle(.bordered)
                    Button("Export CSV") { exportEntries() }
                        .buttonStyle(.bordered)
                        .disabled(settings.dictionaryEntries.isEmpty)
                }
                Text("CSV format: word,correction — one per line, up to \(DictionaryEntry.maxCSVRows) rows and 3MB. Rows without a correction become vocabulary words.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let message = importMessage {
                    SettingsNotice(text: message, icon: importWarning ? "exclamationmark.triangle" : "info.circle",
                                   warning: importWarning)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText],
                          allowsMultipleSelection: false, onCompletion: importCSV)
            .fileExporter(isPresented: $showExporter, document: exportDocument,
                          contentType: .commaSeparatedText,
                          defaultFilename: "oliv-dictionary.csv") { result in
                if case let .failure(error) = result {
                    importMessage = "Export failed: \(error.localizedDescription)"
                    importWarning = true
                }
            }

            SettingsCard(title: "Auto-learn", icon: "sparkles",
                         subtitle: "Let OLIV notice words you correct often.") {
                SettingsToggle(title: "Suggest words from my corrections",
                               detail: "When you undo a dictation and say it again within 30 seconds, OLIV suggests the difference (a notice appears, and it waits at the top of this page and in the OLIV menu). Nothing is added until you approve it.",
                               isOn: $settings.dictionaryAutoLearn)
            }

        }
        .onAppear { sync.refresh() }
        .alert(pendingSuggestion.map { "Fix “\($0.correction ?? "")” too?" } ?? "",
               isPresented: Binding(get: { pendingSuggestion != nil }, set: { if !$0 { pendingSuggestion = nil } }),
               presenting: pendingSuggestion) { candidate in
            Button("Add correction") {
                settings.addDictionaryEntry(word: candidate.word, correction: candidate.correction, source: .autoLearn)
            }
            Button("Later") { settings.proposeAutoLearnCandidates([candidate], explicit: true) }
            Button("No thanks", role: .cancel) {}
        } message: { candidate in
            Text("Your recent dictation had “\(candidate.correction ?? "")”. OLIV can type “\(candidate.word)” whenever it hears that.")
        }
    }

    @ViewBuilder
    private func dictionaryRow(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if selectMode {
                    Toggle("", isOn: selectionBinding(for: entry.id))
                        .toggleStyle(.checkbox).controlSize(.small)
                        .labelsHidden().accessibilityLabel("Select \(entry.word)")
                }
                Toggle("", isOn: enabledBinding(for: entry))
                    .toggleStyle(.switch).controlSize(.small)
                    .labelsHidden().accessibilityLabel("Enable \(entry.word)")
                    .help(entry.enabled ? "Enabled" : "Disabled")
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.word).font(.system(size: 13, weight: .medium))
                        .textSelection(.enabled)
                        .foregroundStyle(entry.enabled ? .primary : .secondary)
                    if let correction = entry.correction, !correction.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.up.left").font(.system(size: 10))
                            Text(correction).font(.system(size: 12))
                        }
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    } else {
                        Text("Vocabulary only").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    settings.setDictionaryEntryStarred(id: entry.id, starred: !entry.starred)
                } label: {
                    Image(systemName: entry.starred ? "star.fill" : "star")
                        .foregroundStyle(entry.starred ? SettingsStyle.accent : .secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help(entry.starred ? "Unstar \(entry.word)" : "Star \(entry.word) — sent to recognition first")
                .accessibilityLabel(entry.starred ? "Unstar \(entry.word)" : "Star \(entry.word)")
                if !selectMode {
                    Button { startEdit(entry) } label: {
                        Image(systemName: "pencil").frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless).help("Edit \(entry.word)")
                    .accessibilityLabel("Edit \(entry.word)")
                    SettingsRemoveButton(item: entry.word) {
                        settings.removeDictionaryEntry(entry.id)
                        selection.remove(entry.id)
                        if editingID == entry.id { cancelEdit() }
                    }
                }
            }
            .font(.system(size: 12))
            if editingID == entry.id {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Word", text: $editWord).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Edit word")
                    Toggle("Correct a misspelling", isOn: $editWantsCorrection)
                        .font(.system(size: 12))
                    if editWantsCorrection {
                        TextField("Misspelling", text: $editCorrection).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Edit misspelling")
                    }
                    HStack {
                        Spacer()
                        Button("Cancel", action: cancelEdit)
                        Button("Save changes", action: saveEdit)
                            .buttonStyle(.borderedProminent).disabled(!canSaveEdit)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Suggestions waiting for approval, shown first and highlighted so they
    /// are not missed.
    private var suggestionsCard: some View {
        SettingsCard(title: "Suggestions for your dictionary · \(settings.autoLearnCandidates.count)",
                     icon: "sparkles",
                     subtitle: "Words OLIV noticed you fixing. Nothing changes until you approve.",
                     highlighted: true) {
            ForEach(settings.autoLearnCandidates) { candidate in
                if candidate.id != settings.autoLearnCandidates.first?.id { Divider() }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let correction = candidate.correction, !correction.isEmpty {
                            Text("“\(correction)” → “\(candidate.word)”").font(.system(size: 13, weight: .medium))
                                .textSelection(.enabled)
                        } else {
                            Text(candidate.word).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                        }
                        Text(candidate.reason == AutoLearnCandidate.reasonUndoRedictate
                             ? "You undid this and said it again"
                             : "Found in your recent dictation after you added the word")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Approve") { settings.approveCandidate(candidate.id) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityLabel("Approve \(candidate.word)")
                    Button { settings.dismissCandidate(candidate.id) } label: {
                        Image(systemName: "xmark").frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Dismiss \(candidate.word)")
                    .accessibilityLabel("Dismiss \(candidate.word)")
                }
                .font(.system(size: 12))
            }
            if settings.autoLearnCandidates.count > 1 {
                HStack {
                    Spacer()
                    Button("Dismiss all") { settings.clearCandidates() }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Where the dictionary lives and whether it is up to date.
    @ViewBuilder
    private var syncStatus: some View {
        let (text, icon, warning): (String, String, Bool) = {
            switch sync.status {
            case .localOnly: return ("Saved on this Mac. Add an OLIV API key to share it with your other devices.", "desktopcomputer", false)
            case .syncing: return ("Syncing with the OLIV server…", "arrow.triangle.2.circlepath", false)
            case .synced: return ("Synced with your other devices.", "checkmark.icloud", false)
            case .waiting: return ("Changes saved here; they will sync when the server is reachable.", "icloud.slash", false)
            case .unsupported: return ("This OLIV server doesn't sync dictionaries yet. Words still apply to every dictation.", "info.circle", false)
            case .failed(let message): return (message, "exclamationmark.triangle", true)
            }
        }()
        SettingsNotice(text: text, icon: icon, warning: warning)
        if !sync.rejectedWords.isEmpty {
            SettingsNotice(text: "Not synced (duplicate or dictionary full): \(sync.rejectedWords.joined(separator: ", "))",
                           icon: "exclamationmark.triangle", warning: true)
        }
    }

    private var trimmedWord: String { DictionaryEntry.trimmed(newWord) }
    private var trimmedCorrection: String { DictionaryEntry.trimmed(newCorrection) }

    private var canAdd: Bool {
        if wantsCorrection, trimmedCorrection.isEmpty { return false }
        let corr: String? = wantsCorrection ? newCorrection : nil
        guard let pair = DictionaryEntry.normalized(word: newWord, correction: corr) else {
            return false
        }
        let key = DictionaryEntry(word: pair.word, correction: pair.correction).dedupeKey()
        return !settings.dictionaryEntries.contains { $0.dedupeKey() == key }
    }

    private func addEntry() {
        guard canAdd else { return }
        let wordOnly = !wantsCorrection
            || newCorrection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        settings.addDictionaryEntry(word: newWord,
                                    correction: wantsCorrection ? newCorrection : nil)
        if wordOnly { suggestCorrectionForNewWord(newWord) }
        newWord = ""
        newCorrection = ""
    }

    /// The user just added a word-only entry: if a recent transcript shows
    /// what STT actually heard, ask right away whether to add that correction.
    /// Explicit user action — allowed even with auto-learn off; history off
    /// means no transcripts to scan.
    private func suggestCorrectionForNewWord(_ word: String) {
        let recents = appState.transcripts.entries.map(\.text)
        guard let candidate = AutoLearn.proposeCorrectionForNewWord(word: word, recentTexts: recents),
              candidate.correction != nil else { return }
        pendingSuggestion = candidate
    }

    private func enabledBinding(for entry: DictionaryEntry) -> Binding<Bool> {
        Binding(get: { entry.enabled },
                set: { settings.setDictionaryEntryEnabled(id: entry.id, enabled: $0) })
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(get: { selection.contains(id) }, set: {
            if $0 { selection.insert(id) } else { selection.remove(id) }
        })
    }

    private func startEdit(_ entry: DictionaryEntry) {
        editingID = entry.id
        editWord = entry.word
        if let correction = entry.correction, !correction.isEmpty {
            editWantsCorrection = true
            editCorrection = correction
        } else {
            editWantsCorrection = false
            editCorrection = ""
        }
    }

    private func cancelEdit() {
        editingID = nil
        editWord = ""
        editCorrection = ""
        editWantsCorrection = false
    }

    private var canSaveEdit: Bool {
        guard editingID != nil else { return false }
        if editWantsCorrection, DictionaryEntry.trimmed(editCorrection).isEmpty { return false }
        let corr: String? = editWantsCorrection ? editCorrection : nil
        guard let pair = DictionaryEntry.normalized(word: editWord, correction: corr) else {
            return false
        }
        let key = DictionaryEntry(word: pair.word, correction: pair.correction).dedupeKey()
        return !settings.dictionaryEntries.contains {
            $0.id != editingID && $0.dedupeKey() == key
        }
    }

    private func saveEdit() {
        guard let id = editingID, canSaveEdit else { return }
        settings.updateDictionaryEntry(id: id, word: editWord,
                                       correction: editWantsCorrection ? editCorrection : nil)
        cancelEdit()
    }

    private func deleteSelected() {
        settings.removeDictionaryEntries(selection)
        selection.removeAll()
        selectMode = false
    }

    private func exportEntries() {
        exportDocument = DictionaryCSVDocument(text: settings.exportDictionaryCSV())
        importMessage = nil
        showExporter = true
    }

    private func importCSV(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= DictionaryEntry.maxCSVBytes else {
                    throw DictionaryEntry.CSVError.tooLarge(limit: DictionaryEntry.maxCSVBytes)
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    importMessage = "Could not read that file as text (expected UTF-8 CSV)."
                    importWarning = true
                    return
                }
                let (imported, skipped) = try settings.importDictionaryCSV(text)
                importWarning = false
                if imported == 0 {
                    importMessage = skipped == 0
                        ? "Nothing to import — the file has no word rows."
                        : "No new words — \(skipped) row\(skipped == 1 ? " was" : "s were") skipped (invalid or already in your dictionary)."
                } else if skipped == 0 {
                    importMessage = "Imported \(imported) word\(imported == 1 ? "" : "s")."
                } else {
                    importMessage = "Imported \(imported) word\(imported == 1 ? "" : "s"); \(skipped) row\(skipped == 1 ? " was" : "s were") skipped (invalid or duplicate)."
                }
            } catch let error as DictionaryEntry.CSVError {
                importWarning = true
                switch error {
                case .empty:
                    importMessage = "That file is empty — nothing to import."
                case .badHeader:
                    importMessage = "Wrong format — the first line must be “word,correction”."
                case let .tooManyRows(limit):
                    importMessage = "Too many rows — the limit is \(limit) per import."
                case .tooLarge:
                    importMessage = "That file is over 3MB — split it and try again."
                }
            } catch {
                importWarning = true
                importMessage = "Import failed: \(error.localizedDescription)"
            }
        case let .failure(error):
            importWarning = true
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
