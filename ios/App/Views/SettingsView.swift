import SwiftUI
import OlivCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @FocusState private var fieldIsFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow(text: "Make it yours")
                    Text("A natural fit.")
                        .font(.system(.largeTitle, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text("Your server. Your vocabulary. Your way of writing.")
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.secondary)
                }

                serverCard
                quickAccessCard
                NavigationLink {
                    KeyboardSetupView()
                } label: {
                    Label("OLIV Keyboard", systemImage: "keyboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(OlivSecondaryButtonStyle())
                .accessibilityIdentifier("keyboardSetupButton")
                writingCard
                vocabularyCard
                replacementCard
                preferencesCard

                VStack(alignment: .leading, spacing: 8) {
                    Label("Built around your Oliv server", systemImage: "leaf")
                        .font(.caption.weight(.semibold))
                    Text("Recordings are sent only to the server you configure. Failed recordings stay on this iPhone for retry. Finished audio is removed after processing; text history is optional.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(OlivTheme.secondary)
                .padding(.horizontal, 5)
                .padding(.bottom, 12)
            }
            .padding(22)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .olivScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                fieldIsFocused = false
                model.saveSettings()
            } label: {
                if dynamicTypeSize.isAccessibilitySize {
                    Text("Save")
                } else {
                    Label("Save settings", systemImage: "checkmark")
                }
            }
            .buttonStyle(OlivPrimaryButtonStyle())
            .disabled(model.isBusy)
            .accessibilityLabel("Save settings")
            .accessibilityIdentifier("saveSettingsButton")
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .background(OlivTheme.background.opacity(0.97))
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { fieldIsFocused = false }
            }
        }
    }

    private var serverCard: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(title: "Your connection", caption: "Connect to your OLIV server.")
                    Spacer(minLength: 0)
                    Image(systemName: "network")
                        .font(.title2.weight(.light))
                        .foregroundStyle(OlivTheme.olive)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Server URL")
                        .font(.caption.weight(.semibold))
                    TextField("https://oliv.example.com", text: $model.settings.serverURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldIsFocused)
                        .olivField()
                        .accessibilityIdentifier("serverURLField")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("API token")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if model.hasToken {
                            Label("Saved securely", systemImage: "checkmark.shield")
                                .font(.caption2)
                                .foregroundStyle(OlivTheme.secondary)
                        }
                    }
                    SecureField(model.hasToken ? "Leave blank to keep saved key" : "Enter your individual API key", text: $model.tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldIsFocused)
                        .olivField()
                        .privacySensitive()
                        .accessibilityIdentifier("tokenField")
                    Text("Stored in iOS Keychain on this iPhone. Use a key for this device with dictate permission; clean permission is needed for existing text.")
                        .font(.caption2)
                        .foregroundStyle(OlivTheme.secondary)
                }

                OlivDivider()

                Toggle(isOn: $model.settings.allowsInsecureHTTP) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Allow private HTTP")
                            .font(.subheadline.weight(.medium))
                        Text("For a trusted local network or private VPN. Prefer HTTPS whenever available.")
                            .font(.caption)
                            .foregroundStyle(OlivTheme.secondary)
                    }
                }
                .accessibilityIdentifier("allowHTTPSettingsToggle")

                if model.settings.allowsInsecureHTTP {
                    Text("HTTP does not encrypt traffic between Oliv and your server. This option is limited to private network addresses.")
                        .font(.caption)
                        .foregroundStyle(OlivTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    fieldIsFocused = false
                    Task { await model.checkConnection() }
                } label: {
                    HStack(spacing: 9) {
                        if model.isCheckingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(model.isCheckingConnection ? "Checking server…" : "Test connection")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(OlivSecondaryButtonStyle())
                .disabled(model.isCheckingConnection || model.isBusy)
                .accessibilityIdentifier("testConnectionButton")

                Text("Checks API availability only. Your key is verified when you dictate or clean text.")
                    .font(.caption2)
                    .foregroundStyle(OlivTheme.secondary)

                if let message = model.connectionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("connectionStatus")
                }
            }
            .disabled(model.isBusy)
        }
    }

    private var quickAccessCard: some View {
        NavigationLink {
            QuickAccessView()
        } label: {
            HStack(spacing: 15) {
                Image(systemName: "bolt.fill")
                    .font(.title3)
                    .foregroundStyle(OlivTheme.olive)
                    .frame(width: 48, height: 48)
                    .background(OlivTheme.inset, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("One gesture away")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OlivTheme.ink)
                    Text("Set up Action button, Back Tap, or controls.")
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OlivTheme.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("quickAccessSettingsLink")
    }

    private var writingCard: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 19) {
                SectionHeading(title: "Writing preferences", caption: "The same core controls as the other OLIV clients.")
                SettingsToggle(title: "Clean up wording", detail: "Refine punctuation and structure without changing your meaning.", isOn: $model.settings.cleanup)
                    .accessibilityIdentifier("cleanupSettingsToggle")
                OlivDivider()
                SettingsToggle(title: "Remove filler words", detail: "Trim hesitations such as “um” and “เอ่อ”.", isOn: $model.settings.removeFillers)
                    .accessibilityIdentifier("fillersSettingsToggle")
                OlivDivider()
                SettingsToggle(title: "Format Thai text", detail: "Apply the server’s Thai spacing and formatting rules.", isOn: $model.settings.thaiFormat)
                    .accessibilityIdentifier("thaiSettingsToggle")
            }
            .disabled(model.isBusy)
        }
    }

    private var vocabularyCard: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Words you use", caption: "Help Oliv recognize names, products, and specialist terms. One word or phrase per line.")
                ZStack(alignment: .topLeading) {
                    if model.settings.vocabularyText.isEmpty {
                        Text("Oliv\nชื่อเฉพาะ\nYour project name")
                            .font(.body)
                            .foregroundStyle(OlivTheme.secondary.opacity(0.8))
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.settings.vocabularyText)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($fieldIsFocused)
                        .frame(minHeight: 130)
                        .accessibilityLabel("Custom vocabulary, one phrase per line")
                        .accessibilityIdentifier("vocabularyField")
                }
                .olivField()
            }
            .disabled(model.isBusy)
        }
    }

    private var replacementCard: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "Say this. Write that.", caption: "Replace spoken phrases with the text you prefer. Rules run from top to bottom.")

                if model.settings.replacements.isEmpty {
                    HStack(alignment: .center, spacing: 10) {
                        Text("โอลิฟ")
                        Image(systemName: "arrow.right")
                            .font(.caption)
                        Text("Oliv")
                        Spacer(minLength: 0)
                        Text("Example")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .foregroundStyle(OlivTheme.secondary)
                    .padding(15)
                    .background(OlivTheme.background, in: RoundedRectangle(cornerRadius: 13))
                }

                ForEach($model.settings.replacements) { $rule in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("RULE \(ruleNumber(rule.id))")
                                .font(.caption2.weight(.semibold))
                                .tracking(1)
                                .foregroundStyle(OlivTheme.secondary)
                            Spacer()
                            Menu {
                                Button("Move up", systemImage: "arrow.up") { moveRule(rule.id, by: -1) }
                                    .disabled(rule.id == model.settings.replacements.first?.id)
                                Button("Move down", systemImage: "arrow.down") { moveRule(rule.id, by: 1) }
                                    .disabled(rule.id == model.settings.replacements.last?.id)
                                Button("Remove rule", systemImage: "trash", role: .destructive) {
                                    model.settings.replacements.removeAll { $0.id == rule.id }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Replacement rule \(ruleNumber(rule.id)) options")
                        }
                        TextField("Spoken phrase", text: $rule.spoken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($fieldIsFocused)
                            .olivField()
                            .accessibilityLabel("Spoken phrase")
                            .accessibilityIdentifier("replacementSpoken_\(ruleNumber(rule.id))")
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.turn.down.right")
                                .foregroundStyle(OlivTheme.secondary)
                                .accessibilityHidden(true)
                            TextField("Replacement text", text: $rule.written)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($fieldIsFocused)
                                .olivField()
                                .accessibilityLabel("Replacement text")
                                .accessibilityIdentifier("replacementWritten_\(ruleNumber(rule.id))")
                        }
                    }
                    if rule.id != model.settings.replacements.last?.id {
                        OlivDivider()
                    }
                }

                Button {
                    model.settings.replacements.append(ReplacementRule(spoken: "", written: ""))
                } label: {
                    Label("Add a replacement", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(OlivSecondaryButtonStyle())
                .accessibilityIdentifier("addReplacementButton")

                if !model.settings.replacements.isEmpty {
                    Text("An empty replacement removes the spoken phrase.")
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                }
            }
            .disabled(model.isBusy)
        }
    }

    private var preferencesCard: some View {
        OlivCard {
            VStack(alignment: .leading, spacing: 19) {
                SectionHeading(title: "The finishing touches")
                SettingsToggle(title: "Copy finished text", detail: "Copy automatically when Oliv is open. Use a shortcut’s Copy to Clipboard action for background capture.", isOn: $model.settings.autoCopy)
                    .accessibilityIdentifier("autoCopySettingsToggle")
                OlivDivider()
                SettingsToggle(title: "Keep text history", detail: "Save transcripts on this iPhone. Turning this off keeps existing history until you delete it.", isOn: $model.settings.keepHistory)
                    .accessibilityIdentifier("historySettingsToggle")
                OlivDivider()
                SettingsToggle(title: "Action button auto-finish", detail: "Toggle OLIV finishes after 1.5 seconds without detected speech. Invoke again to finish sooner. Turn off to stop manually.", isOn: $model.settings.automaticActionButtonFinish)
                    .accessibilityIdentifier("actionButtonAutoFinishToggle")
                OlivDivider()
                SettingsToggle(title: "Finish after a pause", detail: "For other recordings, finish after 1.5 seconds without detected speech following your voice. Keep off to stop manually.", isOn: $model.settings.stopAfterSilence)
                    .accessibilityIdentifier("silenceSettingsToggle")
            }
            .disabled(model.isBusy)
        }
    }

    private func ruleNumber(_ id: UUID) -> Int {
        (model.settings.replacements.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func moveRule(_ id: UUID, by offset: Int) {
        guard let index = model.settings.replacements.firstIndex(where: { $0.id == id }),
              model.settings.replacements.indices.contains(index + offset) else { return }
        model.settings.replacements.swapAt(index, index + offset)
    }
}

private struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OlivTheme.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(OlivTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 5)
        }
    }
}
