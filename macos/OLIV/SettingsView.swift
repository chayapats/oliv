import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, audio, engines, cleanup, dictionary, cloud, models
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Keyboard shortcuts"
        case .audio: return "Audio & microphone"
        case .engines: return "Dictation engine"
        case .cleanup: return "Text cleanup"
        case .dictionary: return "Dictionary"
        case .cloud: return "Cloud services"
        case .models: return "Models & storage"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "A few small preferences. A smoother everyday workflow."
        case .shortcuts: return "Your voice is a shortcut. Make it feel natural."
        case .audio: return "Choose how OLIV hears you and handles other audio."
        case .engines: return "Choose the engine that turns your speech into text."
        case .cleanup: return "Turn what you say into text that’s ready to use."
        case .dictionary: return "Teach OLIV your words, and how to fix what it mishears."
        case .cloud: return "Connect a remote engine when you want to use one."
        case .models: return "Manage the models that make on-device dictation possible."
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .shortcuts: return "keyboard"
        case .audio: return "mic"
        case .engines: return "waveform"
        case .cleanup: return "wand.and.stars"
        case .dictionary: return "book.closed"
        case .cloud: return "cloud"
        case .models: return "internaldrive"
        }
    }
    var group: String {
        switch self {
        case .general, .shortcuts, .audio: return "EVERYDAY"
        case .engines, .cleanup, .dictionary: return "DICTATION"
        case .cloud, .models: return "SYSTEM"
        }
    }
    private var keywords: String {
        switch self {
        case .general: return "launch login startup recording indicator hud waveform history recent transcripts privacy"
        case .shortcuts: return "push to talk hotkey key primary secondary undo record chord binding"
        case .audio: return "microphone input device bluetooth airpods echo cancellation speaker music volume lower duck"
        case .engines: return "stt recognition transcription local on device offline typhoon whisper pathumma groq api download"
        case .cleanup: return "fillers um uh thai numbers repeated words formatting commands new line paragraph verbatim apps bundle"
        case .dictionary: return "dictionary vocabulary replacements custom words terms names jargon acronyms spelling recognition snippets phrase corrections starred sync"
        case .cloud: return "groq oliv api remote server url key keychain connection timeout credentials"
        case .models: return "download storage disk space finder weights gemma typhoon whisper pathumma offline"
        }
    }
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            "\(title) \(keywords)".localizedStandardContains(String($0))
        }
    }
}

/// Navigation is local to this window. Preferences retain their production bindings.
struct SettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @EnvironmentObject private var appState: AppState
    @State private var selectedPage: SettingsPage = .general
    @State private var search = ""

    init(page: SettingsPage = .general) {
        _selectedPage = State(initialValue: page)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(selectedPage.title).font(.system(size: 27, weight: .bold))
                    Text(selectedPage.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 25)
                Divider()
                pageContent.id(selectedPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(SettingsStyle.accent)
                    Text("Changes apply automatically").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 11)).padding(.horizontal, 28).padding(.vertical, 12)
            }
            .background(SettingsStyle.canvas)
        }
        .frame(minWidth: 900, minHeight: 640)
        .tint(SettingsStyle.accent)
        .onChange(of: search) { _, query in
            if !selectedPage.matches(query), let first = SettingsPage.allCases.first(where: { $0.matches(query) }) {
                selectedPage = first
            }
        }
        .onAppear(perform: openRequestedPage)
        .onChange(of: appState.requestedSettingsPage) { _, _ in openRequestedPage() }
    }

    /// Switch to a page another surface asked for (the menu), once.
    private func openRequestedPage() {
        guard let page = appState.requestedSettingsPage else { return }
        selectedPage = page
        search = ""
        appState.requestedSettingsPage = nil
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 38, height: 38).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OLIV").font(.system(size: 17, weight: .bold))
                    Text("Settings").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 18)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a setting", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Find a setting")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12)).padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 16).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(["EVERYDAY", "DICTATION", "SYSTEM"], id: \.self) { group in
                        let pages = SettingsPage.allCases.filter { $0.group == group && $0.matches(search) }
                        if !pages.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group).font(.system(size: 9, weight: .semibold)).tracking(1.3)
                                    .foregroundStyle(.secondary).padding(.leading, 12).padding(.bottom, 5)
                                ForEach(pages) { page in
                                    Button { selectedPage = page } label: {
                                        HStack(spacing: 11) {
                                            Image(systemName: page.icon).font(.system(size: 14)).frame(width: 20)
                                            Text(page.title).font(.system(size: 12, weight: selectedPage == page ? .semibold : .regular))
                                            Spacer(minLength: 0)
                                        }
                                        .foregroundStyle(selectedPage == page ? SettingsStyle.accent : Color.primary.opacity(0.8))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .contentShape(RoundedRectangle(cornerRadius: 9))
                                        .background(selectedPage == page ? SettingsStyle.accent.opacity(0.12) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 9))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selectedPage == page ? .isSelected : [])
                                }
                            }
                        }
                    }
                    if !SettingsPage.allCases.contains(where: { $0.matches(search) }) {
                        Text("No settings found.\nTry “microphone” or “shortcut”.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Spacer(minLength: 12)
            Divider().padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 7) {
                let execution = DictationExecution(engineID: settings.engineID)
                Label(execution.label, systemImage: execution.systemImage)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(SettingsStyle.accent)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 224).background(.regularMaterial)
    }

    @ViewBuilder private var pageContent: some View {
        switch selectedPage {
        case .general: GeneralSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .audio: AudioSettingsView()
        case .engines: EngineSettingsView(onOpenCloud: { selectedPage = .cloud })
        case .cleanup: CleanupSettingsView()
        case .dictionary: DictionarySettingsView()
        case .cloud: CloudSettingsView(onOpenEngines: { selectedPage = .engines })
        case .models: ModelsSettingsView()
        }
    }
}
