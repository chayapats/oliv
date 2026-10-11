import Foundation

/// Result shared by local and remote providers. Pipeline metadata is optional.
struct DictationResult {
    let raw: String
    let final: String
    let tSTT: Double
    let tCleanup: Double
    let llmRan: Bool
    let gateReason: String
    let guardrailFlag: String
    /// Server-side cleanup degrade reason (final == raw). nil when cleanup ran
    /// clean or was disabled. Informational only — NOT a client failure.
    let cleanupError: String?
    /// W4-T1 counts (informational): filler tokens stripped pre-cleanup, and
    /// user replacement snippets fired in the final pass. 0 when the feature was
    /// off / nothing matched. Defaulted so callers/tests that don't care (and
    /// older reply shapes) construct/decode unchanged.
    var fillersRemoved: Int = 0
    var replacementsFired: Int = 0
    /// B4 count (informational): spoken formatting commands (new line / paragraph
    /// / bullet) that fired. 0 when the feature was off / nothing matched.
    var formatCommandsFired: Int = 0
    /// Thai-format count (informational): reduplication collapses + converted
    /// number runs from the deterministic post-pass. 0 when the feature was off /
    /// nothing matched (also 0 decoded from an older sidecar that omits the key).
    var thaiFormatFired: Int = 0
    var noSpeech: Bool = false
    var sttRedecoded: Bool = false
    /// Actual engine that returned this result, including Groq's local fallback.
    var engineID: String? = nil

    var textToPaste: String { noSpeech ? "" : final }
}

/// Options resolved once for an utterance, independent of its transport.
struct DictationOptions {
    let cleanup: Bool
    var removeFillers = false
    var replacements: [String: String] = [:]
    var vocabulary: [String] = []
    var formatCommands = false
    var thaiFormat = false
}

protocol DictationProviding {
    func dictate(samples: [Float], options: DictationOptions) async throws -> DictationResult
}

/// Preserve the existing local/Groq pipeline and its cloud-to-local fallback.
struct SidecarDictationProvider: DictationProviding {
    let client: SidecarClient
    let engine: String

    func dictate(samples: [Float], options: DictationOptions) async throws -> DictationResult {
        guard let result = DictationController.dictateWithFallback(
            engine: engine, cleanup: options.cleanup,
            dictate: { engine, cleanup in
                try client.dictate(samples: samples, engine: engine, cleanup: cleanup,
                                   removeFillers: options.removeFillers,
                                   replacements: options.replacements,
                                   vocabulary: options.vocabulary,
                                   formatCommands: options.formatCommands,
                                   thaiFormat: options.thaiFormat)
            }) else { throw DictationProviderError.localFailure }
        return result
    }
}

enum DictationProviderError: Error {
    case localFailure
}
