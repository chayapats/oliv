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
import CoreGraphics

@MainActor
final class OLIVSettings: ObservableObject {
    /// The app-wide store (UserDefaults.standard). Tests build their own with a
    /// throwaway suite via `init(defaults:)`.
    static let shared = OLIVSettings()

    enum Key {
        static let hotkey = "oliv.hotkey"                 // HotkeyKey.id (primary)
        static let hotkeySecondary = "oliv.hotkeySecondary" // HotkeyKey.id or "" = none
        static let undoHotkey = "oliv.undoHotkey"         // undo-last-paste binding; "" = off
        static let engine = "oliv.engine"                 // STT engine id
        static let cleanupEnabled = "oliv.cleanupEnabled" // global cleanup switch
        static let verbatimApps = "oliv.verbatimApps"     // [String] lowercased bundle ids
        static let groqEnabled = "oliv.groqCloudEnabled"  // opt-in cloud fallback toggle
        static let apiEnabled = "oliv.api.enabled"
        static let apiURL = "oliv.api.url"
        static let apiTimeout = "oliv.api.timeout"
        static let legacyReplacements = "oliv.replacements" // pre-Dictionary [String:String]; migrated once, then removed
        static let removeFillers = "oliv.removeFillers"   // W4-T1 filler-word toggle
        static let showRecordingIndicator = "oliv.showRecordingIndicator" // W4-T2 HUD toggle
        static let legacyVocabulary = "oliv.vocabulary"   // pre-Dictionary [String]; migrated once, then removed
        static let legacyDictionaryBackup = "oliv.legacyDictionaryBackup" // JSON copy of both, kept for recovery
        static let dictionaryEntries = "oliv.dictionaryEntries" // Dictionary JSON [DictionaryEntry]
        static let legacySnippets = "oliv.legacySnippets"  // [String:String] 0.2.0 replacements a Dictionary entry cannot hold
        static let dictionaryAutoLearn = "oliv.dictionaryAutoLearn" // undo→redictate suggestions toggle
        static let autoLearnCandidates = "oliv.autoLearnCandidates" // inbox JSON [AutoLearnCandidate]
        static let formatCommands = "oliv.formatCommands" // B4 spoken formatting-command toggle
        static let thaiFormat = "oliv.thaiFormat"         // Thai number/reduplication post-pass toggle
        static let historyEnabled = "oliv.historyEnabled" // 0.1.5 recent-transcripts toggle
        static let micDevice = "oliv.micDevice"           // MicSelection sentinel or a device UID
        static let echoCancellation = "oliv.echoCancellation" // 0.1.10 AEC toggle
        static let duckOtherAudio = "oliv.duckOtherAudio"     // 0.1.10 ducking toggle
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
        static let olivAPI = Engine(id: OLIVAPIClient.engineID, displayName: "OLIV API (remote)", repo: nil)
        /// The always-available LOCAL engines; `typhoon-turbo-mlx` is the shipped
        /// default (the benchmarked STT — half Pathumma's size, better on unseen jargon).
        static let local: [Engine] = [typhoon, pathumma, mlxLarge]
        static let all: [Engine] = [typhoon, pathumma, mlxLarge, groq, olivAPI]
    }

    /// Local engines are always offered; remote engines require explicit opt-in
    /// and configuration. Pure + static so the picker
    /// gating is unit-testable without a live store.
    static func availableEngines(groqEnabled: Bool, groqKeyPresent: Bool,
                                 apiEnabled: Bool = false, apiConfigured: Bool = false) -> [Engine] {
        var list = Engine.local
        if groqEnabled && groqKeyPresent { list.append(.groq) }
        if apiEnabled && apiConfigured { list.append(.olivAPI) }
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

    /// Primary push-to-talk binding id (HotkeyChord.id — a single HotkeyKey.id
    /// or a `chord:…` multi-key id). Default "right_option".
    @Published var hotkeyID: String {
        didSet { defaults.set(hotkeyID, forKey: Key.hotkey); onChange?() }
    }

    /// Secondary push-to-talk binding id, or "" when unset. Either binding
    /// (chord) holds to record; release fires when no binding is fully held.
    /// Empty by default (primary only).
    @Published var hotkeySecondaryID: String {
        didSet { defaults.set(hotkeySecondaryID, forKey: Key.hotkeySecondary); onChange?() }
    }

    /// Undo-last-dictation binding id. Default Control+Shift+Z; "" disables.
    /// A momentary press synthesizes Cmd+Z after a successful auto-paste.
    @Published var undoHotkeyID: String {
        didSet { defaults.set(undoHotkeyID, forKey: Key.undoHotkey); onChange?() }
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

    /// Which mic to dictate from: a `MicSelection` sentinel or a device UID.
    ///
    /// Defaults to the BUILT-IN mic rather than the system default, because macOS
    /// silently promotes a paired Bluetooth headset to default input — and
    /// dictating through a Bluetooth mic eats the first ~1 s of the utterance while
    /// its link comes up AND drops that headset's own playback from 48 kHz stereo
    /// to a 24 kHz mono call profile. Both measured; see AudioDevices. Users who
    /// want the headset mic can pick it — they just shouldn't get it by accident.
    @Published var micDevice: String {
        didSet { defaults.set(micDevice, forKey: Key.micDevice); onChange?() }
    }

    /// 0.1.10: run the capture through Apple's voice-processing unit, which
    /// subtracts what the Mac is PLAYING from what the mic HEARS. Default ON —
    /// music over the laptop speakers is otherwise recorded along with the
    /// speech, and STT does not merely lose accuracy on it, it INVENTS sentences
    /// out of it. Skipped automatically on Bluetooth (see AudioCapture); off
    /// pins the pre-0.1.10 capture path.
    @Published var echoCancellation: Bool {
        didSet { defaults.set(echoCancellation, forKey: Key.echoCancellation); onChange?() }
    }

    /// 0.1.10: fade the system output down while the key is held and back up on
    /// release. Default ON. The half of the speaker-bleed problem the canceller
    /// can't model — and the only one that also works when the sound is coming
    /// from an external speaker the AEC has no reference for.
    @Published var duckOtherAudio: Bool {
        didSet { defaults.set(duckOtherAudio, forKey: Key.duckOtherAudio); onChange?() }
    }

    /// The personal Dictionary: vocabulary words and misspelling corrections
    /// (the old separate Vocabulary/Replacements lists were migrated into it).
    /// Persisted as JSON under `oliv.dictionaryEntries`; every user edit is
    /// reported to `onDictionaryEdit` so `DictionarySync` can send it on.
    @Published var dictionaryEntries: [DictionaryEntry] {
        didSet {
            // The sync outbox first: if the app dies in between, relaunch
            // replays the queued edit instead of letting the server copy
            // overwrite a saved-but-unqueued one.
            if !applyingServerDictionary { onDictionaryEdit?(oldValue, dictionaryEntries) }
            persistDictionaryEntries()
            onChange?()
        }
    }

    /// 0.2.0 replacements that a Dictionary entry cannot hold exactly (long
    /// snippets, symbol-only output, meaningful surrounding whitespace). They
    /// keep working as the legacy replacement table — spoken phrase → exact
    /// output — on this Mac only, and can be removed from the Dictionary page.
    @Published var legacySnippets: [String: String] {
        didSet { defaults.set(legacySnippets, forKey: Key.legacySnippets); onChange?() }
    }

    func removeLegacySnippet(spoken: String) {
        legacySnippets.removeValue(forKey: spoken)
    }

    /// (old, new) after each user edit of `dictionaryEntries`; not called for
    /// lists that came from the server.
    var onDictionaryEdit: (([DictionaryEntry], [DictionaryEntry]) -> Void)?
    private var applyingServerDictionary = false

    /// Auto-learn (Wispr `auto_learn` parity). Default OFF. When on, undoing a
    /// dictation and saying it again within 30 s stages the difference in the
    /// inbox below; nothing is learned until the user approves it.
    @Published var dictionaryAutoLearn: Bool {
        didSet { defaults.set(dictionaryAutoLearn, forKey: Key.dictionaryAutoLearn); onChange?() }
    }

    /// Auto-learn candidate inbox (proposal + approval only — nothing here is
    /// applied until the user approves it). Newest first, capped at
    /// `autoLearnCap` (oldest dropped). Persisted as JSON under
    /// `oliv.autoLearnCandidates`.
    @Published var autoLearnCandidates: [AutoLearnCandidate] {
        didSet { persistAutoLearnCandidates(); onChange?() }
    }

    /// Inbox ceiling: the newest 50 proposals are kept.
    static let autoLearnCap = 50

    /// B4: convert spoken formatting commands (new line / paragraph / bullet)
    /// into real line breaks. Default OFF — higher false-positive risk than
    /// fillers (a command phrase can be genuine content), so it is opt-in. Sent
    /// per-dictate; live-applied.
    @Published var formatCommands: Bool {
        didSet { defaults.set(formatCommands, forKey: Key.formatCommands); onChange?() }
    }

    /// Thai formatting post-pass: collapse repeated words to ๆ (มากมาก → มากๆ)
    /// and write spoken numbers from ten up as Arabic digits (สี่สิบห้า → 45,
    /// สองจุดห้า → 2.5). Default ON. A deterministic pass that runs on the final
    /// cleaned text on BOTH the LLM and gate-skip paths; sent per-dictate and
    /// gated on effective cleanup (verbatim/cleanup-off dictation gets raw text).
    @Published var thaiFormat: Bool {
        didSet { defaults.set(thaiFormat, forKey: Key.thaiFormat); onChange?() }
    }

    /// 0.1.5: keep the last few transcripts in the menu's "Recent…" submenu.
    /// Default ON. The retained entries live ONLY in memory (TranscriptLog);
    /// this toggle gates recording, and the coordinator clears what's retained
    /// the moment it flips off.
    @Published var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled); onChange?() }
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

    @Published var olivAPIEnabled: Bool {
        didSet { defaults.set(olivAPIEnabled, forKey: Key.apiEnabled); reconcileEngineSelection(); onChange?() }
    }
    @Published var olivAPIURL: String {
        didSet { defaults.set(olivAPIURL, forKey: Key.apiURL); reconcileEngineSelection(); onChange?() }
    }
    @Published var olivAPITimeout: Int {
        didSet { defaults.set(olivAPITimeout, forKey: Key.apiTimeout); reconcileEngineSelection(); onChange?() }
    }
    @Published var olivAPIKey: String {
        didSet { keychain.set(olivAPIKey, forAccount: KeychainStore.olivAPIAccount); reconcileEngineSelection(); onChange?() }
    }

    var usesOLIVAPI: Bool { engineID == Engine.olivAPI.id }

    var olivAPIConfiguration: OLIVAPIConfiguration? {
        guard olivAPIEnabled else { return nil }
        return try? OLIVAPIConfiguration(url: olivAPIURL, apiKey: olivAPIKey, timeout: TimeInterval(olivAPITimeout))
    }

    var olivAPIConfigurationError: String? {
        guard olivAPIEnabled else { return nil }
        do {
            _ = try OLIVAPIConfiguration(url: olivAPIURL, apiKey: olivAPIKey, timeout: TimeInterval(olivAPITimeout))
            return nil
        } catch let error as OLIVAPIError { return error.errorDescription }
        catch { return "Check the API settings." }
    }

    /// Remote dictation has no local model prerequisites. Groq still uses local cleanup.
    var requiredModelRepos: [String] {
        if usesOLIVAPI { return [] }
        var repos: [String] = []
        if let repo = Engine.all.first(where: { $0.id == engineID })?.repo { repos.append(repo) }
        if cleanupEnabled { repos.append(RequiredModels.cleanup) }
        return repos
    }

    init(defaults: UserDefaults = .standard, keychain: KeychainStoring = KeychainStore.shared) {
        self.defaults = defaults
        self.keychain = keychain
        hotkeyID = defaults.string(forKey: Key.hotkey) ?? HotkeyKey.default.id
        hotkeySecondaryID = defaults.string(forKey: Key.hotkeySecondary) ?? ""
        // Absent key → Control+Shift+Z. Explicit "" stays off. The brief F18
        // default shipped earlier migrates forward so existing installs pick up
        // the new binding without a manual reset. didSet does not run during
        // init, so migrations must write defaults explicitly (use a local id —
        // self.undoHotkeyID is not readable until all stored props are set).
        let defaultUndoID = HotkeyChord.defaultUndo.id
        if defaults.object(forKey: Key.undoHotkey) == nil {
            undoHotkeyID = defaultUndoID
            defaults.set(defaultUndoID, forKey: Key.undoHotkey)
        } else {
            let stored = defaults.string(forKey: Key.undoHotkey) ?? ""
            if stored == HotkeyChord.legacyDefaultUndoF18.id {
                undoHotkeyID = defaultUndoID
                defaults.set(defaultUndoID, forKey: Key.undoHotkey)
            } else {
                undoHotkeyID = stored
            }
        }
        engineID = defaults.string(forKey: Key.engine) ?? SidecarClient.defaultEngine
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true
        removeFillers = defaults.object(forKey: Key.removeFillers) as? Bool ?? true
        showRecordingIndicator = defaults.object(forKey: Key.showRecordingIndicator) as? Bool ?? true
        dictionaryAutoLearn = defaults.object(forKey: Key.dictionaryAutoLearn) as? Bool ?? false
        // `dictionaryEntries` is resolved below (see migration), after every
        // stored property has a value — Swift forbids any other order.
        dictionaryEntries = []
        autoLearnCandidates = []
        formatCommands = defaults.object(forKey: Key.formatCommands) as? Bool ?? false
        thaiFormat = defaults.object(forKey: Key.thaiFormat) as? Bool ?? true   // default ON
        historyEnabled = defaults.object(forKey: Key.historyEnabled) as? Bool ?? true
        micDevice = defaults.string(forKey: Key.micDevice) ?? MicSelection.builtIn
        echoCancellation = defaults.object(forKey: Key.echoCancellation) as? Bool ?? true
        duckOtherAudio = defaults.object(forKey: Key.duckOtherAudio) as? Bool ?? true
        let stored = defaults.array(forKey: Key.verbatimApps) as? [String] ?? []
        verbatimApps = Set(stored.map { $0.lowercased() })
        groqCloudEnabled = defaults.object(forKey: Key.groqEnabled) as? Bool ?? false
        groqAPIKey = keychain.groqAPIKey() ?? ""
        olivAPIEnabled = defaults.object(forKey: Key.apiEnabled) as? Bool ?? false
        olivAPIURL = defaults.string(forKey: Key.apiURL) ?? OLIVAPIConfiguration.defaultURL
        let apiTimeout = defaults.object(forKey: Key.apiTimeout) as? Int ?? 120
        olivAPITimeout = (10...180).contains(apiTimeout) ? apiTimeout : 120
        olivAPIKey = keychain.string(forAccount: KeychainStore.olivAPIAccount) ?? ""
        // Dictionary, resolved LAST: every stored property above has a value
        // now. didSet does not run during init, so persist explicitly.
        if let data = defaults.data(forKey: Key.dictionaryEntries),
           let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            dictionaryEntries = decoded
            legacySnippets = defaults.dictionary(forKey: Key.legacySnippets) as? [String: String] ?? [:]
        } else {
            let migrated = DictionaryEntry.migrate(
                vocabulary: defaults.array(forKey: Key.legacyVocabulary) as? [String] ?? [],
                replacements: defaults.dictionary(forKey: Key.legacyReplacements) as? [String: String] ?? [:])
            dictionaryEntries = migrated.entries
            legacySnippets = migrated.kept
            persistDictionaryEntries()
            defaults.set(migrated.kept, forKey: Key.legacySnippets)
        }
        retireLegacyDictionaryStores()
        // Auto-learn inbox: load persisted proposals (legacy installs have
        // none — the key is simply absent). Corrupt JSON resets to empty rather
        // than crashing; the migration above is untouched.
        if let data = defaults.data(forKey: Key.autoLearnCandidates),
           let decoded = try? JSONDecoder().decode([AutoLearnCandidate].self, from: data) {
            autoLearnCandidates = Array(decoded.prefix(Self.autoLearnCap))
        }
        // Defend the picker invariant on load: if a persisted engineID is no
        // longer offered (e.g. a stored groq selection whose key/toggle is now
        // gone), fall back to the local default. onChange is still nil here, so
        // this never spuriously re-applies at startup.
        reconcileEngineSelection()
    }

    // MARK: Convenience

    /// The resolved primary chord (falls back to Right Option for unknown ids).
    var hotkeyChord: HotkeyChord { HotkeyChord.resolve(hotkeyID) }

    /// First key of the primary chord — back-compat for callers that still
    /// expect a single HotkeyKey.
    var hotkeyKey: HotkeyKey { hotkeyChord.keys[0] }

    /// The resolved secondary chord, or nil when unset / blank.
    var hotkeySecondaryChord: HotkeyChord? {
        HotkeyChord.resolveOptional(hotkeySecondaryID)
    }

    /// First key of the secondary chord, or nil.
    var hotkeySecondaryKey: HotkeyKey? { hotkeySecondaryChord?.keys[0] }

    /// The resolved undo chord, or nil when unset / blank.
    var undoHotkeyChord: HotkeyChord? {
        HotkeyChord.resolveOptional(undoHotkeyID)
    }

    /// Chords the tap should listen for: primary, plus secondary when set and
    /// distinct. Shared by Settings live-apply and the diagnostics report.
    var activeChords: [HotkeyChord] {
        var list = [hotkeyChord]
        if let secondary = hotkeySecondaryChord, secondary != hotkeyChord {
            list.append(secondary)
        }
        return list
    }

    /// Flattened keys across active chords (typesText warning / diagnostics).
    var activeHotkeys: [HotkeyKey] {
        var seen = Set<CGKeyCode>()
        var keys: [HotkeyKey] = []
        for k in activeChords.flatMap(\.keys) where seen.insert(k.keyCode).inserted {
            keys.append(k)
        }
        return keys
    }

    /// The engines the picker should offer given the CURRENT cloud-fallback
    /// state — drives the SwiftUI Picker's ForEach (recomputes when the toggle or
    /// key changes because both are @Published).
    var availableEngines: [Engine] {
        Self.availableEngines(groqEnabled: groqCloudEnabled,
                              groqKeyPresent: !groqAPIKey.isEmpty,
                              apiEnabled: olivAPIEnabled, apiConfigured: olivAPIConfiguration != nil)
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

    // MARK: Dictionary

    private func persistDictionaryEntries() {
        defaults.set(try? JSONEncoder().encode(dictionaryEntries), forKey: Key.dictionaryEntries)
    }

    /// The pre-Dictionary vocabulary/replacements stores are folded into
    /// `dictionaryEntries` on first launch. Afterwards they must not linger:
    /// anything still reading them would resurrect entries the user deleted.
    /// A JSON copy is kept under `legacyDictionaryBackup` for manual recovery.
    private func retireLegacyDictionaryStores() {
        let vocabulary = defaults.array(forKey: Key.legacyVocabulary) as? [String]
        let replacements = defaults.dictionary(forKey: Key.legacyReplacements) as? [String: String]
        guard vocabulary != nil || replacements != nil else { return }
        if defaults.data(forKey: Key.legacyDictionaryBackup) == nil {
            let backup: [String: Any] = ["vocabulary": vocabulary ?? [], "replacements": replacements ?? [:]]
            defaults.set(try? JSONSerialization.data(withJSONObject: backup), forKey: Key.legacyDictionaryBackup)
        }
        defaults.removeObject(forKey: Key.legacyVocabulary)
        defaults.removeObject(forKey: Key.legacyReplacements)
    }

    /// Install the server's copy (from `DictionarySync`) without reporting it
    /// back as a user edit. Device-local usage counts are kept by id.
    func replaceDictionaryFromServer(_ entries: [DictionaryEntry]) {
        let usage = Dictionary(dictionaryEntries.map { ($0.id, $0.usageCount) }, uniquingKeysWith: { a, _ in a })
        let merged = entries.map { entry -> DictionaryEntry in
            var entry = entry
            entry.usageCount = usage[entry.id] ?? entry.usageCount
            return entry
        }
        guard merged != dictionaryEntries else { return }
        applyingServerDictionary = true
        defer { applyingServerDictionary = false }
        dictionaryEntries = merged
    }

    /// Case-insensitive substring search over word + correction. Empty query
    /// returns everything in stored order.
    func dictionarySearch(_ query: String) -> [DictionaryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return dictionaryEntries }
        return dictionaryEntries.filter {
            $0.word.localizedCaseInsensitiveContains(q)
                || ($0.correction?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Append a word (+ optional correction). Trims, validates, and dedupes;
    /// returns nil when invalid or already present. When a word-only entry for
    /// the same word exists and a correction is supplied, it is upgraded in
    /// place instead of duplicating.
    @discardableResult
    func addDictionaryEntry(word: String, correction: String?,
                            source: DictionarySource = .manual) -> DictionaryEntry? {
        guard let pair = DictionaryEntry.normalized(word: word, correction: correction) else {
            return nil
        }
        let candidate = DictionaryEntry(word: pair.word, correction: pair.correction, source: source)
        if dictionaryEntries.contains(where: { $0.dedupeKey() == candidate.dedupeKey() }) {
            return nil
        }
        if pair.correction != nil,
           let idx = dictionaryEntries.firstIndex(where: {
               $0.correction == nil
                   && DictionaryEntry.dedupeKey(for: $0.word) == DictionaryEntry.dedupeKey(for: pair.word)
           }) {
            dictionaryEntries[idx].correction = pair.correction
            return dictionaryEntries[idx]
        }
        dictionaryEntries.append(candidate)
        return candidate
    }

    /// Replace an entry's word/correction by id. Returns false when the id is
    /// unknown, the pair is invalid, or it would collide with another entry.
    @discardableResult
    func updateDictionaryEntry(id: String, word: String, correction: String?) -> Bool {
        guard let idx = dictionaryEntries.firstIndex(where: { $0.id == id }),
              let pair = DictionaryEntry.normalized(word: word, correction: correction) else {
            return false
        }
        let key = DictionaryEntry(word: pair.word, correction: pair.correction).dedupeKey()
        guard !dictionaryEntries.enumerated().contains(where: {
            $0.offset != idx && $0.element.dedupeKey() == key
        }) else { return false }
        dictionaryEntries[idx].word = pair.word
        dictionaryEntries[idx].correction = pair.correction
        return true
    }

    func removeDictionaryEntry(_ id: String) {
        dictionaryEntries.removeAll { $0.id == id }
    }

    func removeDictionaryEntries(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        dictionaryEntries.removeAll { ids.contains($0.id) }
    }

    func setDictionaryEntryEnabled(id: String, enabled: Bool) {
        guard let idx = dictionaryEntries.firstIndex(where: { $0.id == id }) else { return }
        dictionaryEntries[idx].enabled = enabled
    }

    func setDictionaryEntryStarred(id: String, starred: Bool) {
        guard let idx = dictionaryEntries.firstIndex(where: { $0.id == id }) else { return }
        dictionaryEntries[idx].starred = starred
    }

    /// Import `word,correction` CSV text: parses (≤1000 rows, ≤3MB enforced by
    /// the parser), dedupes against existing entries, appends the rest.
    /// - Returns: (imported, skipped) — skipped counts invalid + duplicate rows.
    @discardableResult
    func importDictionaryCSV(_ text: String) throws -> (imported: Int, skipped: Int) {
        let parsed = try DictionaryEntry.parseCSV(text)
        var seen = Set(dictionaryEntries.map { $0.dedupeKey() })
        var imported = 0
        var skipped = parsed.skipped
        for entry in parsed.entries {
            guard seen.insert(entry.dedupeKey()).inserted else { skipped += 1; continue }
            dictionaryEntries.append(entry)
            imported += 1
        }
        return (imported, skipped)
    }

    /// Export every entry (including disabled) to `word,correction` CSV.
    func exportDictionaryCSV() -> String {
        DictionaryEntry.serializeCSV(dictionaryEntries)
    }

    // MARK: Auto-learn inbox (proposal + approval only)

    private func persistAutoLearnCandidates() {
        defaults.set(try? JSONEncoder().encode(autoLearnCandidates), forKey: Key.autoLearnCandidates)
    }

    /// Stage background proposals (undo→redictate path). No-op unless the
    /// auto-learn toggle is ON and history retention is ON (history off means
    /// no transcript retention → no background candidates). Pass
    /// `explicit: true` for suggestions the user asked for (adding a word),
    /// which are always allowed. Dedupes against existing dictionary
    /// entries and within the inbox (repeat sightings bump `baseCount` instead
    /// of duplicating); the inbox keeps the newest `autoLearnCap` proposals.
    /// Returns the candidates that are new to the inbox (repeat sightings and
    /// words already in the dictionary are not), so callers can tell the user.
    @discardableResult
    func proposeAutoLearnCandidates(_ candidates: [AutoLearnCandidate], explicit: Bool = false) -> [AutoLearnCandidate] {
        guard explicit || (dictionaryAutoLearn && historyEnabled) else { return [] }
        let existing = Set(dictionaryEntries.map { $0.dedupeKey() })
        var added: [AutoLearnCandidate] = []
        for candidate in candidates {
            let key = candidate.dedupeKey()
            guard !existing.contains(key) else { continue }
            if let idx = autoLearnCandidates.firstIndex(where: { $0.dedupeKey() == key }) {
                autoLearnCandidates[idx].baseCount += candidate.baseCount
            } else {
                autoLearnCandidates.insert(candidate, at: 0)
                added.append(candidate)
            }
        }
        if autoLearnCandidates.count > Self.autoLearnCap {
            autoLearnCandidates = Array(autoLearnCandidates.prefix(Self.autoLearnCap))
        }
        return added
    }

    /// Approve a candidate: it becomes a real DictionaryEntry via the existing
    /// add path (source `.autoLearn`) and leaves the inbox. Returns the entry,
    /// or nil when the id is unknown or the pair is now a duplicate.
    @discardableResult
    func approveCandidate(_ id: UUID) -> DictionaryEntry? {
        guard let idx = autoLearnCandidates.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let candidate = autoLearnCandidates.remove(at: idx)
        return addDictionaryEntry(word: candidate.word, correction: candidate.correction,
                                  source: .autoLearn)
    }

    /// Dismiss a candidate without learning it.
    func dismissCandidate(_ id: UUID) {
        autoLearnCandidates.removeAll { $0.id == id }
    }

    /// Empty the inbox.
    func clearCandidates() {
        guard !autoLearnCandidates.isEmpty else { return }
        autoLearnCandidates.removeAll()
    }
}
