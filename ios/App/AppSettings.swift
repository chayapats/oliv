import Foundation
import OlivCore

struct AppSettings: Codable, Equatable {
    /// The URL prefilled in Settings. Source builds have none: the user enters
    /// the URL of their own (or their operator's) OLIV server with the API key.
    /// An operator's release build can bake one in (`OLIVDefaultAPIURL`).
    static let defaultServerURL = defaultServerURL(from: Bundle.main.infoDictionary)
    static func defaultServerURL(from info: [String: Any]?) -> String {
        (info?["OLIVDefaultAPIURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var serverURL = AppSettings.defaultServerURL
    var allowsInsecureHTTP = false
    var cleanup = true
    var removeFillers = true
    var thaiFormat = true
    var autoCopy = true
    var keepHistory = true
    var stopAfterSilence = false
    /// Missing in older saved settings. Action-button dictation now finishes
    /// automatically; foreground captures keep their separate pause preference.
    var actionButtonAutoFinish: Bool?
    var automaticActionButtonFinish: Bool {
        get { actionButtonAutoFinish ?? true }
        set { actionButtonAutoFinish = newValue }
    }
    /// Binds a saved endpoint to its Keychain value without storing the token.
    var credentialBinding: String?
    /// Optional so settings written before the public API migration still decode.
    var requiresNewAPIKey: Bool?
    /// Set while this iPhone uses a free-trial key. The server enforces the date.
    var trialExpiresAt: Date?
    /// Nil on a new install and for anyone who connected before first-run setup
    /// existed. AppModel's init tells those two apart.
    var finishedSetup: Bool?

    /// Request options. A server with dictionary sync applies the synced
    /// Dictionary itself; older servers get it as vocabulary/replacements.
    func options(dictionary: DictionaryBook) -> OlivOptions {
        OlivOptions(cleanup: cleanup, removeFillers: removeFillers, thaiFormat: thaiFormat,
                    vocabulary: dictionary.requestVocabulary, replacements: dictionary.requestReplacements)
    }
}

/// The pre-Dictionary vocabulary and replacement settings, read once from an
/// older settings.json to seed the Dictionary.
struct LegacyDictionarySettings: Decodable {
    var vocabularyText: String?
    var replacements: [ReplacementRule]?
}

/// Where the Dictionary stands with the server, for Settings.
enum DictionarySyncStatus: Equatable {
    /// Not connected yet: the Dictionary lives on this iPhone.
    case localOnly
    case syncing
    case synced
    /// Changes are saved here and wait for the server.
    case waiting
    /// The server predates dictionary sync.
    case unsupported
    case failed(String)
}

enum CapturePhase: String {
    case idle, preparing, recording, processing, result, failed
}

enum AppCaptureError: LocalizedError {
    case setupRequired, microphoneDenied, needsForeground, unavailable, tooShort
    var errorDescription: String? {
        switch self {
        case .setupRequired: String(localized: "Connect your OLIV server and save its access token in Settings first.")
        case .microphoneDenied: String(localized: "Microphone access is off. Enable OLIV in iPhone Settings → Privacy & Security → Microphone.")
        case .needsForeground: String(localized: "Open OLIV once to allow the microphone and Live Activities, then try again.")
        case .unavailable: String(localized: "The microphone could not start. Check whether a call or another recording is using it.")
        case .tooShort: String(localized: "That recording was too short. Tap record and speak for at least a moment.")
        }
    }
}
