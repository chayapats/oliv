import Foundation

/// These options map directly to the OLIV server API. Thai and English are recognized in
/// the same utterance by the server; no invented language selector is sent.
public struct OlivOptions: Codable, Equatable, Sendable {
    public var cleanup: Bool
    public var removeFillers: Bool
    public var thaiFormat: Bool
    public var vocabulary: [String]
    /// Ordering matters: the server applies rules sequentially.
    public var replacements: [ReplacementRule]

    public init(cleanup: Bool = true, removeFillers: Bool = true, thaiFormat: Bool = true,
                vocabulary: [String] = [], replacements: [ReplacementRule] = []) {
        self.cleanup = cleanup
        self.removeFillers = removeFillers
        self.thaiFormat = thaiFormat
        self.vocabulary = vocabulary
        self.replacements = replacements
    }

    public func validate() throws {
        var sources = Set<String>()
        for rule in replacements {
            guard !rule.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OlivError.invalidOptions("Replacement rules need a spoken phrase.")
            }
            guard sources.insert(rule.spoken).inserted else {
                throw OlivError.invalidOptions("Each spoken phrase can have only one replacement rule.")
            }
        }
    }
}

public struct ReplacementRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var spoken: String
    public var written: String

    public init(id: UUID = UUID(), spoken: String, written: String) {
        self.id = id
        self.spoken = spoken
        self.written = written
    }
}

public struct DictationReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var raw: String
    public var finalText: String
    public var noSpeech: Bool
    public var sttRedecoded: Bool
    public var tSTT: TimeInterval
    public var tCleanup: TimeInterval
    public var llmRan: Bool
    public var gateReason: String
    public var guardrailFlag: String
    public var cleanupError: String?
    public var dictionaryHits: Int
    public var vocabularyCorrections: Int
    public var fillersRemoved: Int
    public var replacementsFired: Int
    public var thaiFormatFired: Int

    /// An empty successful result is a no-speech outcome, including filler-only speech.
    public var hasText: Bool {
        !noSpeech && !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(ok: Bool = true, raw: String = "", finalText: String = "", noSpeech: Bool = false,
                sttRedecoded: Bool = false, tSTT: TimeInterval = 0, tCleanup: TimeInterval = 0,
                llmRan: Bool = false, gateReason: String = "", guardrailFlag: String = "",
                cleanupError: String? = nil, dictionaryHits: Int = 0, vocabularyCorrections: Int = 0,
                fillersRemoved: Int = 0, replacementsFired: Int = 0, thaiFormatFired: Int = 0) {
        self.ok = ok
        self.raw = raw
        self.finalText = finalText
        self.noSpeech = noSpeech
        self.sttRedecoded = sttRedecoded
        self.tSTT = tSTT
        self.tCleanup = tCleanup
        self.llmRan = llmRan
        self.gateReason = gateReason
        self.guardrailFlag = guardrailFlag
        self.cleanupError = cleanupError
        self.dictionaryHits = dictionaryHits
        self.vocabularyCorrections = vocabularyCorrections
        self.fillersRemoved = fillersRemoved
        self.replacementsFired = replacementsFired
        self.thaiFormatFired = thaiFormatFired
    }

    enum CodingKeys: String, CodingKey {
        case ok, raw
        case finalText = "final", noSpeech = "no_speech", sttRedecoded = "stt_redecoded"
        case tSTT = "t_stt", tCleanup = "t_cleanup", llmRan = "llm_ran"
        case gateReason = "gate_reason", guardrailFlag = "guardrail_flag", cleanupError = "cleanup_error"
        case dictionaryHits = "dict_hits", vocabularyCorrections = "vocab_fired"
        case fillersRemoved = "fillers_removed", replacementsFired = "replacements_fired"
        case thaiFormatFired = "thai_format_fired"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `ok` is required: an unrelated JSON response must never become success.
        ok = try c.decode(Bool.self, forKey: .ok)
        noSpeech = c.contains(.noSpeech) ? try c.decode(Bool.self, forKey: .noSpeech) : false
        if ok {
            // Public API metadata/raw may be omitted. Only an explicit no-speech
            // result may omit final; present null or wrong types remain invalid.
            raw = c.contains(.raw) ? try c.decode(String.self, forKey: .raw) : ""
            finalText = noSpeech && !c.contains(.finalText) ? "" : try c.decode(String.self, forKey: .finalText)
        } else {
            raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
            finalText = try c.decodeIfPresent(String.self, forKey: .finalText) ?? ""
        }
        sttRedecoded = try c.decodeIfPresent(Bool.self, forKey: .sttRedecoded) ?? false
        tSTT = try c.decodeIfPresent(Double.self, forKey: .tSTT) ?? 0
        tCleanup = try c.decodeIfPresent(Double.self, forKey: .tCleanup) ?? 0
        llmRan = try c.decodeIfPresent(Bool.self, forKey: .llmRan) ?? false
        gateReason = try c.decodeIfPresent(String.self, forKey: .gateReason) ?? ""
        guardrailFlag = try c.decodeIfPresent(String.self, forKey: .guardrailFlag) ?? ""
        cleanupError = try c.decodeIfPresent(String.self, forKey: .cleanupError)
        dictionaryHits = try c.decodeIfPresent(Int.self, forKey: .dictionaryHits) ?? 0
        vocabularyCorrections = try c.decodeIfPresent(Int.self, forKey: .vocabularyCorrections) ?? 0
        fillersRemoved = try c.decodeIfPresent(Int.self, forKey: .fillersRemoved) ?? 0
        replacementsFired = try c.decodeIfPresent(Int.self, forKey: .replacementsFired) ?? 0
        thaiFormatFired = try c.decodeIfPresent(Int.self, forKey: .thaiFormatFired) ?? 0
    }
}

public struct ServerHealth: Codable, Equatable, Sendable {
    public let ok: Bool
    /// Public health is liveness only. Missing legacy model details are unknown,
    /// not false, and must not be treated as a failed model-readiness check.
    public let whisper: Bool?
    public let gemma: Bool?
    public let version: String?
    public let prompt: String?
    public let llmTimeout: TimeInterval?
    public var ready: Bool { ok && whisper == true && gemma == true }

    enum CodingKeys: String, CodingKey {
        case ok, whisper, gemma, version, prompt
        case llmTimeout = "llm_timeout"
    }
}

public enum OlivForbiddenReason: Equatable, Sendable {
    case missingScope
    case edgePolicy
    case unknown
}

/// Safe error descriptions deliberately omit server bodies, transcripts, URLs,
/// and bearer tokens. Underlying URL errors can contain sensitive endpoints.
public enum OlivError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidOptions(String)
    case invalidAudio(String)
    case requestTooLarge
    case responseTooLarge
    case invalidResponse
    case unauthorized
    case forbidden(reason: OlivForbiddenReason)
    case rateLimited(retryAfter: Date)
    case serviceUnavailable(statusCode: Int, retryAfter: Date?)
    case server(statusCode: Int)
    case timedOut
    case networkUnavailable
    case transport
    case missingRecording
    case corruptedStore

    public var retryAfter: Date? {
        switch self {
        case .rateLimited(let date): return date
        case .serviceUnavailable(_, let date): return date
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidOptions(let message), .invalidAudio(let message):
            return message
        case .requestTooLarge: return "This recording or its vocabulary exceeds the server's request limit."
        case .responseTooLarge: return "The server returned more data than expected."
        case .invalidResponse: return "The server returned an unreadable response. Check that the endpoint is an OLIV server."
        case .unauthorized: return "The API key is invalid, expired or revoked. Update it in Settings and retry."
        case .forbidden(.missingScope): return "This API key does not permit this operation. Ask the administrator for the required dictate or clean scope."
        case .forbidden(.edgePolicy): return "Cloudflare denied this request. Contact the administrator with your OLIV app version."
        case .forbidden(.unknown): return "Access was denied. Ask the administrator to check the API key scopes and public API access policy."
        case .rateLimited(let date):
            return "The API is busy or its quota was reached. Try again after \(date.formatted(date: .abbreviated, time: .standard)). Your recording is preserved."
        case .serviceUnavailable(let statusCode, let date):
            let retry = date.map { " Try again after \($0.formatted(date: .abbreviated, time: .standard))." } ?? ""
            return "OLIV is temporarily unavailable (HTTP \(statusCode)).\(retry) Your recording is preserved for retry."
        case .server(let statusCode): return "OLIV could not complete the request (HTTP \(statusCode)). Your recording can be retried."
        case .timedOut: return "The server took too long to respond. Your recording can be retried."
        case .networkUnavailable: return "The server could not be reached. Check your internet connection and retry."
        case .transport: return "The connection to OLIV failed. Your recording can be retried."
        case .missingRecording: return "This saved recording is no longer available."
        case .corruptedStore: return "Saved OLIV data could not be read. Existing data has been preserved."
        }
    }
}
