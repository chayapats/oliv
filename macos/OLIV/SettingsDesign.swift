import AppKit
import SwiftUI

/// Shared surfaces keep every settings page consistent in both macOS appearances.
enum SettingsStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.66, green: 0.76, blue: 0.40, alpha: 1)
            : NSColor(red: 0.32, green: 0.43, blue: 0.16, alpha: 1)
    })
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.105, green: 0.11, blue: 0.10, alpha: 1)
            : NSColor(red: 0.965, green: 0.967, blue: 0.958, alpha: 1)
    })
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.15, green: 0.155, blue: 0.145, alpha: 1)
            : .white
    })
    static let border = Color.primary.opacity(0.08)
}

struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20, content: content)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(28)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SettingsStyle.accent)
                    .frame(width: 36, height: 36)
                    .background(SettingsStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider().overlay(SettingsStyle.border)
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(SettingsStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(SettingsStyle.border))
    }
}

struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
    }
}

struct SettingsNotice: View {
    let text: String
    var icon = "info.circle"
    var warning = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14))
                .foregroundStyle(warning ? Color.orange : SettingsStyle.accent)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .background((warning ? Color.orange : SettingsStyle.accent).opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsBadge: View {
    let text: String
    var active = false

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? SettingsStyle.accent : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? SettingsStyle.accent.opacity(0.10) : Color.primary.opacity(0.05),
                        in: Capsule())
            .fixedSize()
    }
}

struct SettingsEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light))
                .foregroundStyle(SettingsStyle.accent)
                .frame(width: 60, height: 60)
                .background(SettingsStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 350)
        }
        .padding(.vertical, 24).frame(maxWidth: .infinity)
    }
}

struct SettingsRemoveButton: View {
    let item: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash").foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .help("Remove \(item)")
        .accessibilityLabel("Remove \(item)")
    }
}

extension OLIVSettings.Engine {
    var settingsName: String {
        switch id {
        case Self.typhoon.id: return "Typhoon Whisper Turbo"
        case Self.pathumma.id: return "Pathumma"
        case Self.mlxLarge.id: return "Whisper large-v3"
        case Self.groq.id: return "Groq"
        case Self.olivAPI.id: return "OLIV API"
        default: return displayName
        }
    }

    var settingsDetail: String {
        switch id {
        case Self.typhoon.id: return "Built for Thai and English, including mixed-language speech."
        case Self.pathumma.id: return "An alternative Thai model from earlier OLIV versions."
        case Self.mlxLarge.id: return "For dictation that is mostly in English."
        case Self.groq.id: return "Whisper large-v3 hosted by Groq, with local fallback."
        case Self.olivAPI.id: return "Transcription and cleanup on your configured OLIV server."
        default: return displayName
        }
    }
}
