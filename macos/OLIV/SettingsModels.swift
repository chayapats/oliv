import AppKit
import SwiftUI

struct ModelsSettingsView: View {
    @EnvironmentObject private var models: ModelState
    @EnvironmentObject private var settings: OLIVSettings
    @State private var optionalModels: [RepoInfo] = []

    var body: some View {
        SettingsPane {
            SettingsCard(title: "Model storage", icon: "internaldrive", subtitle: "Downloaded once. Available offline on this Mac.") {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(totalSize).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        Text("Used by OLIV models").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: models.storagePath)
                    } label: { Label("Show in Finder", systemImage: "folder") }
                    .disabled(!FileManager.default.fileExists(atPath: models.storagePath))
                }
                Text(models.storagePath).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                if settings.usesOLIVAPI {
                    SettingsNotice(text: "You’re using OLIV API. Local models are optional until you switch to an on-device engine.", icon: "cloud")
                }
            }
            SettingsCard(title: "Core models", icon: "square.stack.3d.up", subtitle: "The default Thai–English engine and its text cleanup model.") {
                ForEach(Array(models.repos.enumerated()), id: \.element.id) { index, info in
                    if index > 0 { Divider() }
                    modelRow(info, name: info.repo == RequiredModels.stt ? "Typhoon Whisper Turbo" : "Gemma E2B",
                             detail: info.repo == RequiredModels.stt ? "Thai–English speech recognition" : "Text cleanup")
                }
                Divider()
                HStack {
                    Button {
                        models.download()
                    } label: {
                        Label(models.allPresent ? "Re-download core models" : "Download core models", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent).disabled(models.isDownloading)
                    Spacer()
                    Button("Refresh status", action: refresh).disabled(models.isDownloading)
                }
            }
            SettingsCard(title: "Alternative engines", icon: "waveform", subtitle: "Only download these if you want to use a different local engine.") {
                ForEach(Array(optionalModels.enumerated()), id: \.element.id) { index, info in
                    if index > 0 { Divider() }
                    let engine = OLIVSettings.Engine.local.first { $0.repo == info.repo }
                    modelRow(info, name: engine?.settingsName ?? info.displayName,
                             detail: engine?.settingsDetail ?? "Speech recognition")
                }
            }
            if models.isDownloading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Downloading models. You can keep using Settings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let error = models.lastError {
                SettingsNotice(text: error, icon: "exclamationmark.triangle", warning: true)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: models.isDownloading) { _, downloading in if !downloading { refresh() } }
    }

    private func modelRow(_ info: RepoInfo, name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: info.present ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 20)).foregroundStyle(info.present ? SettingsStyle.accent : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        if OLIVSettings.Engine.all.first(where: { $0.id == settings.engineID })?.repo == info.repo {
                            SettingsBadge(text: "SELECTED", active: true)
                        }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(info.sizeText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Button(info.present ? "Re-download" : "Download") { models.download([info.repo]) }
                    .disabled(models.isDownloading)
            }
            if models.isDownloading, let pct = models.progressByRepo[info.repo] {
                HStack(spacing: 10) {
                    ProgressView(value: Double(pct), total: 100).progressViewStyle(.linear)
                    Text("\(pct)%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
    private var totalSize: String {
        ByteCountFormatter.string(fromByteCount: (models.repos + optionalModels).reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }
    private func refresh() {
        models.recheck()
        optionalModels = OLIVSettings.Engine.local.compactMap { engine in
            guard let repo = engine.repo, !RequiredModels.all.contains(repo) else { return nil }
            return models.info(for: repo)
        }
    }
}
