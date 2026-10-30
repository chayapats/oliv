import SwiftUI

struct CleanTextSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var text: String {
        get { model.cleanupDraft }
        nonmutating set { model.cleanupDraft = newValue }
    }
    @FocusState private var editorIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "A second pass")
                        Text("A little clarity.")
                            .font(.system(.largeTitle, design: .serif))
                        Text("Tidy existing text with the same vocabulary, replacements, and formatting you use for voice.")
                            .font(.subheadline)
                            .foregroundStyle(OlivTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    OlivCard(padding: 17) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Your text")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                PasteButton(payloadType: String.self) { strings in
                                    text = strings.joined(separator: "\n")
                                }
                                .labelStyle(.titleAndIcon)
                                .tint(OlivTheme.olive)
                                .accessibilityIdentifier("pasteTextButton")
                            }

                            ZStack(alignment: .topLeading) {
                                if text.isEmpty {
                                    Text("Paste or write something here.\nลองวางข้อความภาษาไทย หรือ English")
                                        .font(.body)
                                        .foregroundStyle(OlivTheme.secondary.opacity(0.8))
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $model.cleanupDraft)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 220)
                                    .focused($editorIsFocused)
                                    .accessibilityLabel("Text to clean")
                                    .accessibilityIdentifier("cleanupTextEditor")
                            }
                            OlivDivider()
                            Text("\(text.count.formatted()) characters")
                                .font(.caption)
                                .foregroundStyle(OlivTheme.secondary)
                        }
                    }

                    Button {
                        editorIsFocused = false
                        let submittedText = text
                        dismiss()
                        Task { await model.cleanText(submittedText) }
                    } label: {
                        Label("Clean text", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(OlivPrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy || !model.isConfigured)
                    .accessibilityIdentifier("submitCleanupButton")

                    Text(model.isConfigured ? "This text will be sent to your configured Oliv server when you tap Clean text." : "Connect your Oliv server in Settings before cleaning text.")
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .olivScreen()
            .navigationTitle("Clean text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Done") { editorIsFocused = false }
                        .accessibilityIdentifier("cleanupKeyboardDoneButton")
                }
            }
        }
    }
}
