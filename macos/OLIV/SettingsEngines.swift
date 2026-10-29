import SwiftUI

struct EngineSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @EnvironmentObject private var models: ModelState
    var onOpenCloud: () -> Void
    @State private var enginePresence: [String: Bool] = [:]

    var body: some View {
        SettingsPane {
            let execution = DictationExecution(engineID: settings.engineID)
            SettingsNotice(text: execution.detail, icon: execution.systemImage)
            SettingsCard(title: "On-device engines", icon: "desktopcomputer", subtitle: "Audio is processed on this Mac. Works offline after downloading models.") {
                VStack(spacing: 10) {
                    ForEach(OLIVSettings.Engine.local) { engine in
                        engineOption(engine)
                    }
                }
                if let repo = missingEngineRepo {
                    SettingsNotice(text: "Download this engine’s model before dictating. It isn’t on your Mac yet.",
                                   icon: "exclamationmark.triangle", warning: true)
                    HStack {
                        Button { models.download([repo]) } label: {
                            Label("Download selected model", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(.borderedProminent).disabled(models.isDownloading)
                        if models.isDownloading {
                            if let pct = models.progressByRepo[repo] {
                                ProgressView(value: Double(pct), total: 100).frame(maxWidth: .infinity)
                                Text("\(pct)%").font(.caption).monospacedDigit()
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    if let error = models.lastError {
                        SettingsNotice(text: error, icon: "exclamationmark.triangle", warning: true)
                    }
                }
            }
            SettingsCard(title: "Cloud engines", icon: "cloud", subtitle: "Audio is uploaded only when you select a cloud engine.") {
                let remote = settings.availableEngines.filter { $0.repo == nil }
                if remote.isEmpty {
                    Text("Connect OLIV API or Groq in Cloud services to make a remote engine available here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(remote) { engine in engineOption(engine) }
                }
                Button(action: onOpenCloud) {
                    Label("Manage cloud services", systemImage: "arrow.up.right")
                }
            }
        }
        .onAppear(perform: refreshEnginePresence)
        .onChange(of: models.isDownloading) { _, downloading in if !downloading { refreshEnginePresence() } }
        .onChange(of: models.repos.map { "\($0.repo):\($0.present)" }) { refreshEnginePresence() }
    }

    private func engineOption(_ engine: OLIVSettings.Engine) -> some View {
        let selected = settings.engineID == engine.id
        return Button { settings.engineID = engine.id } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18)).foregroundStyle(selected ? SettingsStyle.accent : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(engine.settingsName).font(.system(size: 13, weight: .semibold))
                        if engine == .typhoon { SettingsBadge(text: "DEFAULT", active: true) }
                    }
                    Text(engine.settingsDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let repo = engine.repo {
                        Text(enginePresence[repo] == true ? "Downloaded" : "Download required")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(selected ? SettingsStyle.accent.opacity(0.06) : Color.primary.opacity(0.015),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? SettingsStyle.accent.opacity(0.5) : SettingsStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(engine.settingsName). \(engine.settingsDetail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var missingEngineRepo: String? {
        OLIVSettings.missingRepo(for: settings.engineID) { enginePresence[$0] ?? false }
    }
    private func refreshEnginePresence() {
        enginePresence = Dictionary(uniqueKeysWithValues: OLIVSettings.Engine.local.compactMap { engine in
            engine.repo.map { ($0, ModelState.diskInfo($0).present) }
        })
    }
}

struct CloudSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    var onOpenEngines: () -> Void

    var body: some View {
        SettingsPane {
            SettingsNotice(text: "Enabling a service makes its engine available. Select it in Dictation engine to use it. API keys are stored in macOS Keychain.", icon: "lock.shield")
            OLIVAPISettingsSection(onOpenEngines: onOpenEngines)
            SettingsCard(title: "Groq", icon: "bolt", subtitle: "Cloud-hosted Whisper large-v3, with fallback to your local engine.") {
                SettingsToggle(title: "Enable Groq", detail: "Allow Groq to appear as a dictation engine after adding your API key.",
                               isOn: $settings.groqCloudEnabled)
                if settings.groqCloudEnabled {
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        Text("API key").font(.system(size: 12, weight: .medium))
                        SecureField("Enter your Groq API key", text: $settings.groqAPIKey)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Groq API key")
                    }
                    Text("Audio is sent to Groq only while the Groq engine is selected. Local models are still needed for cleanup and fallback.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if settings.groqKeyForSidecar != nil {
                        HStack {
                            SettingsBadge(text: settings.engineID == OLIVSettings.Engine.groq.id ? "IN USE" : "CONFIGURED", active: true)
                            Spacer()
                            Button("Choose dictation engine", action: onOpenEngines)
                        }
                    }
                }
            }
        }
    }
}

private struct OLIVAPISettingsSection: View {
    @EnvironmentObject private var settings: OLIVSettings
    var onOpenEngines: () -> Void
    @State private var checking = false
    @State private var connectionStatus: String?
    @State private var connectionFailed = false

    var body: some View {
        SettingsCard(title: "OLIV API", icon: "network", subtitle: "Server transcription and cleanup. No local models required.") {
            SettingsToggle(title: "Enable OLIV API", detail: "Connect to an OLIV server using your individual API key.",
                           isOn: $settings.olivAPIEnabled)
            if settings.olivAPIEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("Server URL").font(.system(size: 12, weight: .medium))
                    TextField("https://oliv.example.com", text: $settings.olivAPIURL)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("OLIV API server URL")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Individual API key").font(.system(size: 12, weight: .medium))
                    SecureField("Enter a key with dictate access", text: $settings.olivAPIKey)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("OLIV API key")
                }
                HStack {
                    Text("Request timeout").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(settings.olivAPITimeout) seconds", value: $settings.olivAPITimeout, in: 10...180, step: 10)
                        .fixedSize().accessibilityLabel("Request timeout: \(settings.olivAPITimeout) seconds")
                }
                if let error = settings.olivAPIConfigurationError {
                    SettingsNotice(text: error, icon: "exclamationmark.triangle", warning: true)
                }
                HStack(spacing: 10) {
                    Button("Check connection", action: checkConnection)
                        .disabled(checking || settings.olivAPIConfiguration == nil)
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    if settings.olivAPIConfiguration != nil {
                        SettingsBadge(text: settings.usesOLIVAPI ? "IN USE" : "CONFIGURED", active: true)
                        Button("Choose engine", action: onOpenEngines)
                    }
                }
                if let status = connectionStatus {
                    SettingsNotice(text: status, icon: connectionFailed ? "exclamationmark.triangle" : "checkmark.circle", warning: connectionFailed)
                }
                DisclosureGroup("Limits & connection details") {
                    Text("Audio is sent to your configured server only when OLIV API is selected. Recordings are limited to 2 minutes. Failed requests aren’t resent automatically or saved for retry; rate limits may require a wait. Spoken formatting commands aren’t supported yet. Check connection tests server reachability, not your key or model readiness.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                }
                .font(.system(size: 12))
            }
        }
        .onChange(of: settings.olivAPIConfiguration) { connectionStatus = nil }
    }

    private func checkConnection() {
        guard let configuration = settings.olivAPIConfiguration else { return }
        checking = true
        connectionStatus = nil
        Task { @MainActor in
            let status: String
            let failed: Bool
            do {
                try await OLIVAPIClient(configuration: configuration).health()
                status = "Server reachable. Your API key and model readiness haven’t been checked."
                failed = false
            } catch {
                status = (error as? OLIVAPIError)?.errorDescription ?? "Could not check the API connection."
                failed = true
            }
            if settings.olivAPIConfiguration == configuration {
                connectionStatus = status
                connectionFailed = failed
            }
            checking = false
        }
    }
}
