// Persisted user settings (W3-T4) — the Swift home for the knobs Wave-1/2 kept
// in oliv.toml (app/config.py). Backed by UserDefaults under the "oliv."
// namespace; every change is mirrored to disk immediately and announced via
// `onChange` so the live app can re-apply engine / cleanup / hotkey / verbatim
// without a relaunch (the live-apply DoD).
//
// Only the knobs the macOS app actually drives live here — hotkey, STT engine,
// global cleanup, and the per-app verbatim list. Launch-at-login is NOT stored
// (its source of truth is SMAppService — see LaunchAtLogin), and model storage
// is derived from SidecarClient.modelsHome(), not a preference.
//
// Per-app model simplification (documented): Wave-2's `[cleanup_apps]` was an
// on/off table keyed by bundle id. Because the global switch already carries
// "on", the only per-app signal worth persisting is "off", so the table
// collapses to a Set<String> of lowercased bundle ids meaning "verbatim in
// these apps". `DictationController.resolveCleanup` ports the precedence.

import Foundation

@MainActor
final class OLIVSettings: ObservableObject {
    /// The app-wide store (UserDefaults.standard). Tests build their own with a
    /// throwaway suite via `init(defaults:)`.
    static let shared = OLIVSettings()

    enum Key {
        static let hotkey = "oliv.hotkey"                 // HotkeyKey.id
        static let engine = "oliv.engine"                 // STT engine id
        static let cleanupEnabled = "oliv.cleanupEnabled" // global cleanup switch
        static let verbatimApps = "oliv.verbatimApps"     // [String] lowercased bundle ids
        static let groqEnabled = "oliv.groqCloudEnabled"  // opt-in cloud fallback toggle
        static let replacements = "oliv.replacements"     // [String:String] spoken -> replacement
        static let removeFillers = "oliv.removeFillers"   // W4-T1 filler-word toggle
        static let showRecordingIndicator = "oliv.showRecordingIndicator" // W4-T2 HUD toggle
        static let vocabulary = "oliv.vocabulary"         // B3 custom-vocabulary term list [String]
        static let formatCommands = "oliv.formatCommands" // B4 spoken formatting-command toggle
        static let historyEnabled = "oliv.historyEnabled" // 0.1.5 recent-transcripts toggle
        // NOTE: the Groq API key is NOT a UserDefaults key — it's a secret and
        // lives in the Keychain (KeychainStore), never on disk in the clear.
    }

    /// The STT engines offered in Settings. The local ones are the shippable
    /// on-device engines (`typhoon-turbo-mlx` is the Thai-first default); `groq` is the
    /// opt-in CLOUD tier, surfaced in the picker ONLY when the fallback toggle is
    /// on AND a key is present (see `availableEngines`). Each maps 1:1 to a
    /// sidecar engine id.
    struct Engine: Identifiable, Equatable {
        let id: String          // sidecar engine id
        let displayName: String
        /// The HF repo this engine's weights load from (the sidecar backend's
        /// default repo — see app/stt/mlx_whisper.py), nil for cloud engines.
        /// Lets Settings tell "not downloaded" BEFORE the first dictate fails
        /// under the sidecar's HF_HUB_OFFLINE default.
        let repo: String?
        var name: String { id }
        static let typhoon = Engine(id: "typhoon-turbo-mlx", displayName: "Thai-first (default) — Typhoon Whisper Turbo MLX",
                                    repo: RequiredModels.stt)
        static let pathumma = Engine(id: "pathumma-mlx", displayName: "Pathumma MLX (legacy)",
                                     repo: "kinoppy555/Pathumma-whisper-th-large-v3-mlx")
        static let mlxLarge = Engine(id: "mlx-large-v3", displayName: "English-heavy — Whisper large-v3 MLX",
                                     repo: "mlx-community/whisper-large-v3-mlx")
        static let groq = Engine(id: "groq-large-v3", displayName: "Groq large-v3 (cloud)", repo: nil)
        /// The always-available LOCAL engines; `typhoon-turbo-mlx` is the shipped
        /// default (the benchmarked STT — half Pathumma's size, better on unseen jargon).
        static let local: [Engine] = [typhoon, pathumma, mlxLarge]
        static let all: [Engine] = [typhoon, pathumma, mlxLarge, groq]
    }

    /// The engines shown in the picker for a given cloud-fallback state: the
    /// local pair always, plus the cloud engine ONLY when the opt-in toggle is on
    /// AND a key is present (cloud strictly opt-in). Pure + static so the picker
    /// gating is unit-testable without a live store.
    static func availableEngines(groqEnabled: Bool, groqKeyPresent: Bool) -> [Engine] {
        var list = Engine.local
        if groqEnabled && groqKeyPresent { list.append(.groq) }
        return list
    }

    /// The weights repo `engineID` still needs on this machine: nil when the
    /// engine is ready, is cloud (no local weights), or is unknown. Drives the
    /// picker's "not downloaded" state + download prompt. `isPresent` is
    /// injected so the decision unit-tests without touching disk.
    static func missingRepo(for engineID: String, isPresent: (String) -> Bool) -> String? {
        guard let engine = Engine.all.first(where: { $0.id == engineID }),
              let repo = engine.repo, !isPresent(repo) else { return nil }
        return repo
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStoring

    /// Push-to-talk key id (HotkeyKey.id). Default "right_option".
    @Published var hotkeyID: String {
        didSet { defaults.set(hotkeyID, forKey: Key.hotkey); onChange?() }
    }

    /// STT engine id handed to the sidecar per dictate.
    @Published var engineID: String {
        didSet { defaults.set(engineID, forKey: Key.engine); onChange?() }
    }

    /// Global cleanup switch (Wave-2 `cleanup_enabled`).
    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled); onChange?() }
    }

    /// W4-T1 Feature B: strip filler words (อืม/เอ่อ/um/uh/…) before cleanup.
    /// Default ON. Sent per-dictate; the sidecar's protocol default is OFF, so
    /// this client-side default is what turns it on for real utterances.
    @Published var removeFillers: Bool {
        didSet { defaults.set(removeFillers, forKey: Key.removeFillers); onChange?() }
    }

    /// W4-T2 Feature A: show the floating recording HUD (waveform pill) while
    /// dictating. Default ON; live-applied to the DictationController.
    @Published var showRecordingIndicator: Bool {
        didSet { defaults.set(showRecordingIndicator, forKey: Key.showRecordingIndicator); onChange?() }
    }

    /// B3 custom vocabulary: user terms (names / jargon / product names) sent
    /// per-dictate as a Whisper initial_prompt to bias RECOGNITION toward them —
    /// distinct from `replacements`, which only rewrites text STT already
    /// produced. Ordered, de-duplicated; an empty list is omitted from the wire.
    @Published var vocabulary: [String] {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary); onChange?() }
    }

    /// B4: convert spoken formatting commands (new line / paragraph / bullet)
    /// into real line breaks. Default OFF — higher false-positive risk than
    /// fillers (a command phrase can be genuine content), so it is opt-in. Sent
    /// per-dictate; live-applied.
    @Published var formatCommands: Bool {
        didSet { defaults.set(formatCommands, forKey: Key.formatCommands); onChange?() }
    }

    /// 0.1.5: keep the last few transcripts in the menu's "Recent…" submenu.
    /// Default ON. The retained entries live ONLY in memory (TranscriptLog);
    /// this toggle gates recording, and the coordinator clears what's retained
    /// the moment it flips off.
    @Published var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled); onChange?() }
    }

    /// W4-T1 Feature A: user replacements/snippets — spoken phrase -> replacement
    /// (e.g. "อีเมลของผม" -> the user's real email). Persisted as a [String:String]
    /// dict; sent per-dictate (an empty dict is omitted from the request). The
    /// sidecar applies it via the same boundary-guarded apply_dictionary pass.
    @Published var replacements: [String: String] {
        didSet { defaults.set(replacements, forKey: Key.replacements); onChange?() }
    }

    /// Lowercased bundle ids kept VERBATIM (cleanup bypassed) — the collapsed
    /// `[cleanup_apps]` "off" set. Always stored/compared lowercased.
    @Published var verbatimApps: Set<String> {
        didSet {
            defaults.set(verbatimApps.sorted(), forKey: Key.verbatimApps)
            onChange?()
        }
    }

    /// Opt-in Groq cloud fallback toggle (W3-T4). Default OFF — OLIV is
    /// privacy-first/local-by-default, so the cloud tier is only ever reached
    /// after the user turns this on. Turning it off (or clearing the key) reverts
    /// a currently-selected groq engine back to the local default.
    @Published var groqCloudEnabled: Bool {
        didSet {
            defaults.set(groqCloudEnabled, forKey: Key.groqEnabled)
            reconcileEngineSelection()   // may revert engineID (fires its own onChange)
            onChange?()
        }
    }

    /// The Groq API key, backed by the Keychain (NOT UserDefaults — it's a
    /// secret). Empty == no key. Editing it re-writes the keychain, reconciles the
    /// engine selection (a cleared key hides the cloud engine), and announces the
    /// change so the coordinator respawns the sidecar with the new spawn env.
    @Published var groqAPIKey: String {
        didSet {
            keychain.setGroqAPIKey(groqAPIKey)
            reconcileEngineSelection()
            onChange?()
        }
    }

    /// Fired after ANY change (property observers don't run during init, so the
    /// initial load never spuriously re-applies). The app wires this to push the
    /// new values into the live DictationController.
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, keychain: KeychainStoring = KeychainStore.shared) {
        self.defaults = defaults
        self.keychain = keychain
        hotkeyID = defaults.string(forKey: Key.hotkey) ?? HotkeyKey.default.id
        engineID = defaults.string(forKey: Key.engine) ?? SidecarClient.defaultEngine
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true
        removeFillers = defaults.object(forKey: Key.removeFillers) as? Bool ?? true
        showRecordingIndicator = defaults.object(forKey: Key.showRecordingIndicator) as? Bool ?? true
        replacements = defaults.dictionary(forKey: Key.replacements) as? [String: String] ?? [:]
        vocabulary = defaults.array(forKey: Key.vocabulary) as? [String] ?? []
        formatCommands = defaults.object(forKey: Key.formatCommands) as? Bool ?? false
        historyEnabled = defaults.object(forKey: Key.historyEnabled) as? Bool ?? true
        let stored = defaults.array(forKey: Key.verbatimApps) as? [String] ?? []
        verbatimApps = Set(stored.map { $0.lowercased() })
        groqCloudEnabled = defaults.object(forKey: Key.groqEnabled) as? Bool ?? false
        groqAPIKey = keychain.groqAPIKey() ?? ""
        // Defend the picker invariant on load: if a persisted engineID is no
        // longer offered (e.g. a stored groq selection whose key/toggle is now
        // gone), fall back to the local default. onChange is still nil here, so
        // this never spuriously re-applies at startup.
        reconcileEngineSelection()
    }

    // MARK: Convenience

    /// The resolved HotkeyKey for the stored id (falls back to the default for a
    /// legacy/unknown id).
    var hotkeyKey: HotkeyKey { HotkeyKey.resolve(hotkeyID) }

    /// The engines the picker should offer given the CURRENT cloud-fallback
    /// state — drives the SwiftUI Picker's ForEach (recomputes when the toggle or
    /// key changes because both are @Published).
    var availableEngines: [Engine] {
        Self.availableEngines(groqEnabled: groqCloudEnabled,
                              groqKeyPresent: !groqAPIKey.isEmpty)
    }

    /// The GROQ_API_KEY to hand the sidecar's spawn env, or nil when the cloud
    /// fallback is off / no key is set — so a local-only session never leaks the
    /// key into the child. Read by the coordinator on every live-apply.
    var groqKeyForSidecar: String? {
        (groqCloudEnabled && !groqAPIKey.isEmpty) ? groqAPIKey : nil
    }

    /// If the currently-selected engine is no longer offered (the user turned the
    /// cloud toggle off, or cleared the key, while `groq` was selected), fall the
    /// selection back to the local default. No-op otherwise. Called from the
    /// toggle/key observers.
    private func reconcileEngineSelection() {
        let offered = availableEngines
        if !offered.contains(where: { $0.id == engineID }) {
            engineID = Engine.typhoon.id   // reverts to the shipped default + fires onChange
        }
    }

    /// Add a bundle id to the verbatim set (lowercased). Ignores blank input.
    func addVerbatimApp(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return }
        verbatimApps.insert(id)
    }

    /// Remove a bundle id from the verbatim set (case-insensitive).
    func removeVerbatimApp(_ bundleID: String) {
        verbatimApps.remove(bundleID.lowercased())
    }

    /// Add/update a user replacement (W4-T1). The spoken phrase is trimmed;
    /// blank spoken OR blank replacement is ignored (a snippet needs both). An
    /// existing spoken phrase is overwritten (a dict keyed by spoken phrase).
    func setReplacement(spoken: String, replacement: String) {
        let key = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        replacements[key] = replacement
    }

    /// Remove a user replacement by its exact spoken phrase.
    func removeReplacement(_ spoken: String) {
        replacements.removeValue(forKey: spoken)
    }

    /// Add a custom-vocabulary term (B3). Trimmed; blank input ignored; a term
    /// already present (case-insensitively) is not duplicated. Appends so the
    /// user's ordering is preserved.
    func addVocabularyTerm(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard !vocabulary.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        vocabulary.append(t)
    }

    /// Remove a custom-vocabulary term by its exact value.
    func removeVocabularyTerm(_ term: String) {
        vocabulary.removeAll { $0 == term }
    }
}
