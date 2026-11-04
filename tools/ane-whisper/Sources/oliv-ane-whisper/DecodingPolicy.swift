import Foundation
import WhisperKit

/// Controlled ablation of the production MLX decoder's suppression and retry
/// settings. It does not claim identical sampling or timestamp implementation.
struct DecodingPolicy {
    let name: String
    private let suppressed: [Int]

    init(name: String, generationConfig: String?) throws {
        guard ["whisperkit", "mlx-controls"].contains(name) else {
            throw ANEWhisper.Failure.usage("Decoding profile must be whisperkit or mlx-controls")
        }
        self.name = name
        if name == "mlx-controls" {
            guard let generationConfig,
                  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: generationConfig))) as? [String: Any],
                  let ids = object["suppress_tokens"] as? [Int], !ids.isEmpty,
                  ids.allSatisfy({ $0 >= 0 }) else {
                throw ANEWhisper.Failure.usage("mlx-controls requires a generation config with explicit nonnegative suppress_tokens")
            }
            suppressed = ids
        } else {
            suppressed = []
        }
    }

    var filters: [any LogitsFiltering]? {
        // WhisperKit's options path removes special-token IDs. The explicit
        // filter retains the production generation config's special suppressions.
        suppressed.isEmpty ? nil : [SuppressTokensFilter(suppressTokens: suppressed)]
    }

    func options(language: String?) -> DecodingOptions {
        var options = DecodingOptions(verbose: false, language: language,
            temperature: 0, temperatureFallbackCount: 5,
            detectLanguage: language == nil, skipSpecialTokens: true,
            withoutTimestamps: false, wordTimestamps: false, concurrentWorkerCount: 1)
        if name == "mlx-controls" {
            options.sampleLength = 224
            options.maxInitialTimestamp = 1.0
            options.suppressBlank = true
            options.firstTokenLogProbThreshold = nil
        }
        return options
    }
}
