import SwiftUI
import OlivCore

/// The personal Dictionary: vocabulary words and "say this, write that"
/// corrections in one list, synced with the OLIV server and other devices.
struct DictionaryView: View {
    @Bindable var model: AppModel
    @State private var newWord = ""
    @State private var newHeard = ""
    @State private var addError: String?
    @State private var search = ""
    @State private var editing: DictionaryEntry?
    @FocusState private var fieldIsFocused: Bool

    private var shown: [DictionaryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.dictionary.entries }
        return model.dictionary.entries.filter {
            $0.word.localizedCaseInsensitiveContains(query) || ($0.correction?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                addCard
                listCard
                if !olderLines.isEmpty { olderCard }
                syncFooter
            }
            .padding(22)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.syncDictionary() }
        .scrollDismissesKeyboard(.interactively)
        .olivScreen()
        .navigationTitle("Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { entry in
            NavigationStack { DictionaryEntryEditor(model: model, entry: entry) }
                .presentationDetents([.medium])
        }
    }

    private var addCard: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Add a word",
                               caption: "Names, products and terms OLIV should spell your way. Add what you say, or what OLIV mishears, to replace it with your word.")
                TextField("Word, e.g. Grafana or บางแค", text: $newWord)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($fieldIsFocused)
                    .olivField()
                    .accessibilityIdentifier("dictionaryWordField")
                HStack(spacing: 10) {
                    Image(systemName: "arrow.turn.up.left")
                        .foregroundStyle(OlivTheme.secondary)
                        .accessibilityHidden(true)
                    TextField("When I say (optional), e.g. กราฟาน่า", text: $newHeard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldIsFocused)
                        .olivField()
                        .accessibilityLabel("Spoken phrase to replace, optional")
                        .accessibilityIdentifier("dictionaryHeardField")
                }
                if let addError {
                    Text(addError).font(.caption).foregroundStyle(.red)
                }
                Button {
                    addError = model.saveDictionaryEntry(word: newWord, correction: newHeard)
                    if addError == nil { newWord = ""; newHeard = ""; fieldIsFocused = false }
                } label: {
                    Label("Add to Dictionary", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(OlivSecondaryButtonStyle())
                .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("dictionaryAddButton")
            }
        }
    }

    private var listCard: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Your words · \(model.dictionary.entries.count)",
                               caption: "Starred words reach recognition first. Tap a word to edit it.")
                // A search in progress keeps its field, or it couldn't be cleared.
                if model.dictionary.entries.count > 8 || !search.isEmpty {
                    TextField("Search", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .olivField()
                        .accessibilityIdentifier("dictionarySearchField")
                }
                if shown.isEmpty {
                    Text(model.dictionary.entries.isEmpty ? "No words yet. Start with your name or a project." : "No matches.")
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.secondary)
                }
                ForEach(shown) { entry in
                    row(entry)
                    if entry.id != shown.last?.id { OlivDivider() }
                }
            }
        }
    }

    private var olderLines: [(id: String, text: String, remove: () -> Void)] {
        model.dictionary.olderVocabulary.map { line in
            (id: "line-" + line, text: line, remove: { model.removeOlderVocabulary(line) })
        } + model.dictionary.olderRules.map { rule in
            (id: "rule-" + rule.spoken, text: "\(rule.spoken) → \(rule.written)",
             remove: { model.removeOlderRule(spoken: rule.spoken) })
        }
    }

    private var olderCard: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Older rules · \(olderLines.count)",
                               caption: "A Dictionary word can't hold these, like rules that write only symbols. They keep working on this iPhone.")
                ForEach(olderLines, id: \.id) { line in
                    HStack(spacing: 12) {
                        Text(verbatim: line.text)
                            .font(.subheadline)
                            .foregroundStyle(OlivTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: line.remove) {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Remove \(line.text)")
                    }
                }
            }
        }
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button { editing = entry } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.word)
                        .font(.body.weight(.medium))
                        .foregroundStyle(entry.enabled ? OlivTheme.ink : OlivTheme.secondary)
                    Text(entry.correction.map { String(localized: "When you say “\($0)”") } ?? String(localized: "Recognition hint"))
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit")
            Button {
                model.setDictionaryEntry(entry.id, starred: !entry.starred)
            } label: {
                Image(systemName: entry.starred ? "star.fill" : "star")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(entry.starred ? "Unstar \(entry.word)" : "Star \(entry.word)")
            Toggle("Use \(entry.word)", isOn: Binding(
                get: { entry.enabled },
                set: { model.setDictionaryEntry(entry.id, enabled: $0) }))
                .labelsHidden()
        }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.removeDictionaryEntries([entry.id])
            }
        }
    }

    private var syncFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(syncText, systemImage: syncIcon)
                .font(.caption)
            if !model.dictionaryRejectedWords.isEmpty {
                Text("Not synced (already there or Dictionary full): \(model.dictionaryRejectedWords.joined(separator: ", "))")
                    .font(.caption)
            }
        }
        .foregroundStyle(OlivTheme.secondary)
        .padding(.horizontal, 5)
    }

    private var syncText: String {
        switch model.dictionarySyncStatus {
        case .localOnly: String(localized: "Saved on this iPhone. Connect your OLIV server to share it with your other devices.")
        case .syncing: String(localized: "Syncing…")
        case .synced: String(localized: "Synced with your other devices. Pull down to refresh.")
        case .waiting: String(localized: "Saved here; changes sync when the server is reachable.")
        case .unsupported: String(localized: "Your OLIV server doesn’t sync dictionaries yet. Your words still apply to every dictation.")
        case .failed(let message): message
        }
    }

    private var syncIcon: String {
        switch model.dictionarySyncStatus {
        case .localOnly: "iphone"
        case .syncing: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.icloud"
        case .waiting: "icloud.slash"
        case .unsupported: "info.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// Edit or delete one entry.
private struct DictionaryEntryEditor: View {
    @Bindable var model: AppModel
    let entry: DictionaryEntry
    @State private var word: String
    @State private var heard: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, entry: DictionaryEntry) {
        self.model = model
        self.entry = entry
        _word = State(initialValue: entry.word)
        _heard = State(initialValue: entry.correction ?? "")
    }

    var body: some View {
        Form {
            TextField("Word", text: $word)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("When I say (optional)", text: $heard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let error { Text(error).foregroundStyle(.red) }
            Button("Delete", role: .destructive) {
                model.removeDictionaryEntries([entry.id])
                dismiss()
            }
        }
        .navigationTitle("Edit word")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    error = model.saveDictionaryEntry(id: entry.id, word: word, correction: heard)
                    if error == nil { dismiss() }
                }
            }
        }
    }
}
