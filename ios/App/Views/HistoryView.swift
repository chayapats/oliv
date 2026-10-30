import SwiftUI
import OlivCore

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var selectedEntry: HistoryEntry?
    @State private var confirmsClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow(text: "A place for your words")
                    Text("Your history.")
                        .font(.system(.largeTitle, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text(model.settings.keepHistory ? "Saved on this iPhone, ready when you need it." : "Saving new history is paused in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.secondary)
                }

                if model.history.isEmpty {
                    EmptyState(symbol: "text.book.closed", title: "A fresh page.", description: "Your finished dictations and cleaned text will appear here.")
                    if !model.settings.keepHistory {
                        Button("Review history settings") { model.selectedTab = 2 }
                            .buttonStyle(OlivSecondaryButtonStyle())
                            .frame(maxWidth: .infinity)
                    }
                } else if filteredEntries.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matching words.", description: "Try another word or phrase from your transcript.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        ForEach(filteredEntries) { entry in
                            Button {
                                selectedEntry = entry
                            } label: {
                                HistorySummaryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("historyEntry_\(entry.id)")
                            .contextMenu {
                                Button("Copy text", systemImage: "doc.on.doc") { model.copy(entry) }
                                ShareLink(item: entry.finalText) {
                                    Label("Share text", systemImage: "square.and.arrow.up")
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteHistory(entry) }
                                    .disabled(model.isBusy)
                            }
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .olivScreen()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find your words")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: exportText) {
                        Label("Export all text", systemImage: "square.and.arrow.up")
                    }
                    Button("Delete all history", systemImage: "trash", role: .destructive) { confirmsClear = true }
                        .disabled(model.isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(model.history.isEmpty)
                .accessibilityLabel("History options")
                .accessibilityIdentifier("historyOptionsButton")
            }
        }
        .sheet(item: $selectedEntry) { entry in
            HistoryDetailView(originalEntry: entry, model: model)
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Delete all history", role: .destructive) { model.clearHistory() }
        } message: {
            Text("All saved transcripts will be removed from this iPhone. This cannot be undone.")
        }
    }

    private var filteredEntries: [HistoryEntry] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return model.history }
        return model.history.filter { $0.finalText.localizedCaseInsensitiveContains(search) || $0.raw.localizedCaseInsensitiveContains(search) }
    }

    private var exportText: String {
        model.history.map { entry in
            "\(entry.createdAt.formatted(date: .complete, time: .shortened))\n\n\(entry.finalText)"
        }.joined(separator: "\n\n—\n\n")
    }
}

struct HistorySummaryRow: View {
    let entry: HistoryEntry

    var body: some View {
        OlivCard(padding: 19) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: entry.source == .cleanup ? "text.alignleft" : "waveform")
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer(minLength: 3)
                    if entry.copied {
                        Image(systemName: "checkmark.circle")
                            .accessibilityLabel("Copied")
                    }
                }
                .font(.caption)
                .foregroundStyle(OlivTheme.secondary)
                Text(entry.reply.hasText ? entry.finalText : "No text detected")
                    .font(.body)
                    .lineSpacing(4)
                    .lineLimit(3)
                    .foregroundStyle(OlivTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(entry.source == .cleanup ? "Text cleanup" : "\(Int(entry.audioDuration.rounded())) sec of voice")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.caption2)
                .foregroundStyle(OlivTheme.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryDetailView: View {
    let originalEntry: HistoryEntry
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    private var entry: HistoryEntry {
        model.history.first { $0.id == originalEntry.id } ?? originalEntry
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.secondary)
                    ResultCard(entry: entry, model: model)
                }
                .padding(22)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .olivScreen()
            .navigationTitle("Your words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { confirmsDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete transcript")
                    .accessibilityIdentifier("deleteTranscriptButton")
                    .disabled(model.isBusy)
                }
            }
            .confirmationDialog("Delete this transcript?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete transcript", role: .destructive) {
                    model.deleteHistory(entry)
                    dismiss()
                }
                .accessibilityIdentifier("confirmDeleteTranscriptButton")
            }
        }
    }
}

struct ResultCard: View {
    let entry: HistoryEntry
    @Bindable var model: AppModel
    @State private var showsOriginal = false
    @State private var showsDetails = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 9) {
                    Image(systemName: entry.reply.hasText ? "checkmark.circle.fill" : "waveform.slash")
                        .foregroundStyle(OlivTheme.olive)
                    Eyebrow(text: entry.reply.hasText ? "Ready to use" : "Nothing to copy")
                    Spacer(minLength: 0)
                    if entry.copied {
                        Text("Copied")
                            .font(.caption)
                            .foregroundStyle(OlivTheme.secondary)
                    }
                }

                if entry.reply.hasText {
                    Picker("Transcript version", selection: $showsOriginal) {
                        Text("Finished").tag(false)
                        Text("Original").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("transcriptVersionPicker")

                    Text(showsOriginal ? entry.raw : entry.finalText)
                        .font(.system(.title3, design: .default))
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.vertical, 3)
                        .accessibilityIdentifier(showsOriginal ? "rawTranscript" : "cleanedTranscript")

                    if showsOriginal {
                        Text(entry.source == .cleanup ? "The text you submitted, before cleanup." : "The original transcription, before cleanup and formatting.")
                            .font(.caption)
                            .foregroundStyle(OlivTheme.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(entry.source == .cleanup ? "No text remained." : "No speech detected.")
                            .font(.title2.weight(.medium))
                        Text(entry.source == .cleanup ? "The server returned no finished text. Nothing was copied." : "Nothing was copied. Try another recording when you’re ready.")
                            .font(.subheadline)
                            .foregroundStyle(OlivTheme.secondary)
                    }
                    .accessibilityIdentifier("emptyResult")
                }

                if let error = entry.reply.cleanupError, !error.isEmpty {
                    Label {
                        Text("AI cleanup could not finish. Your words were preserved with OLIV’s deterministic cleanup.")
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(OlivTheme.warning)
                    .padding(12)
                    .background(OlivTheme.warm, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("cleanupWarning")
                }

                if entry.reply.hasText {
                    resultActions

                    Text("Paste into the app you’re using, with your usual keyboard.")
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                OlivDivider()

                DisclosureGroup(isExpanded: $showsDetails) {
                    VStack(spacing: 12) {
                        if entry.source != .cleanup {
                            detailRow("Recording", value: seconds(entry.audioDuration))
                            detailRow("Transcription", value: seconds(entry.reply.tSTT))
                        }
                        detailRow("Cleanup", value: seconds(entry.reply.tCleanup))
                        detailRow("Total processing", value: seconds(entry.totalDuration))
                        detailRow("Language model", value: entry.reply.llmRan ? "Used" : "Skipped")
                        if entry.reply.sttRedecoded { detailRow("Speech detection", value: "Decoded again") }
                        if entry.reply.dictionaryHits > 0 { detailRow("Dictionary matches", value: "\(entry.reply.dictionaryHits)") }
                        if entry.reply.vocabularyCorrections > 0 { detailRow("Vocabulary corrections", value: "\(entry.reply.vocabularyCorrections)") }
                        if entry.reply.fillersRemoved > 0 { detailRow("Fillers removed", value: "\(entry.reply.fillersRemoved)") }
                        if entry.reply.replacementsFired > 0 { detailRow("Replacements", value: "\(entry.reply.replacementsFired)") }
                        if entry.reply.thaiFormatFired > 0 { detailRow("Thai formatting", value: "\(entry.reply.thaiFormatFired)") }
                        if !entry.reply.gateReason.isEmpty { detailRow("Cleanup decision", value: entry.reply.gateReason) }
                        if !entry.reply.guardrailFlag.isEmpty { detailRow("Text protection", value: entry.reply.guardrailFlag) }
                    }
                    .padding(.top, 15)
                } label: {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Details")
                            Text(seconds(entry.totalDuration))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Processing details, \(seconds(entry.totalDuration))")
                    } else {
                        HStack(spacing: 6) {
                            Text("Processing details")
                            Spacer(minLength: 3)
                            Text(seconds(entry.totalDuration))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                    }
                }
                .accessibilityIdentifier("processingDetails")
            }
        }
    }

    private var resultActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button {
                model.copy(entry)
            } label: {
                if dynamicTypeSize.isAccessibilitySize {
                    Text(showsOriginal ? "Copy finished text" : "Copy text")
                } else {
                    Label(showsOriginal ? "Copy finished" : "Copy text", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(OlivPrimaryButtonStyle())
            .accessibilityIdentifier("copyResultButton")
            ShareLink(item: entry.finalText) {
                if dynamicTypeSize.isAccessibilitySize {
                    Text("Share text")
                        .frame(maxWidth: .infinity)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .frame(minHeight: 25)
                }
            }
            .buttonStyle(OlivSecondaryButtonStyle())
            .accessibilityLabel("Share finished text")
            .accessibilityIdentifier("shareResultButton")
        }
    }

    private func detailRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 15) {
            Text(label)
                .foregroundStyle(OlivTheme.secondary)
            Spacer(minLength: 0)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(OlivTheme.ink)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func seconds(_ duration: TimeInterval) -> String {
        String(format: "%.1f s", duration)
    }
}
