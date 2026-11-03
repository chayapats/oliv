// Persisted voice-editing settings (Command mode #23, translation #24).
// Kept out of OLIVSettings so the feature stays self-contained; same
// UserDefaults "oliv." namespace and the same live-apply contract: every
// change is written at once and announced through `onChange`.
//
// Both features are OFF by default.

import Foundation

@MainActor
final class VoiceEditSettings: ObservableObject {
    static let shared = VoiceEditSettings()

    enum Key {
        static let commandEnabled = "oliv.commandMode.enabled"
        static let commandHotkey = "oliv.commandMode.hotkey"          // HotkeyChord.id
        static let translateSecondary = "oliv.translation.secondary"  // Bool
        static let translationApps = "oliv.translation.apps"          // [String] lowercased bundle ids
    }

    /// Right Command: a modifier most people never hold alone, and distinct
    /// from the Right Option push-to-talk default.
    static let defaultCommandChordID = HotkeyKey.rightCommand.id

    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    @Published var commandEnabled: Bool {
        didSet { defaults.set(commandEnabled, forKey: Key.commandEnabled); onChange?() }
    }
    @Published var commandHotkeyID: String {
        didSet { defaults.set(commandHotkeyID, forKey: Key.commandHotkey); onChange?() }
    }
    @Published var translateWithSecondary: Bool {
        didSet { defaults.set(translateWithSecondary, forKey: Key.translateSecondary); onChange?() }
    }
    @Published var translationApps: Set<String> {
        didSet { defaults.set(translationApps.sorted(), forKey: Key.translationApps); onChange?() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        commandEnabled = defaults.bool(forKey: Key.commandEnabled)
        commandHotkeyID = defaults.string(forKey: Key.commandHotkey) ?? Self.defaultCommandChordID
        translateWithSecondary = defaults.bool(forKey: Key.translateSecondary)
        let apps = defaults.array(forKey: Key.translationApps) as? [String] ?? []
        translationApps = Set(apps.map { $0.lowercased() })
    }

    var commandChord: HotkeyChord? { HotkeyChord.resolveOptional(commandHotkeyID) }

    /// What the controller applies. Command mode needs a shortcut to exist.
    var configuration: VoiceEditConfiguration {
        VoiceEditConfiguration(commandChord: commandEnabled ? commandChord : nil,
                               translateWithSecondary: translateWithSecondary,
                               translationApps: translationApps)
    }

    func addTranslationApp(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return }
        translationApps.insert(id)
    }

    func removeTranslationApp(_ bundleID: String) {
        translationApps.remove(bundleID.lowercased())
    }
}
