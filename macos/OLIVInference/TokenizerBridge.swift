import Foundation
import MLXLMCommon
import Tokenizers

struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory), rust: try RustTokenizer(directory: directory))
    }
}

// Same protocol adapter as Apple's MLXHuggingFace, without a build-time macro.
struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    let rust: RustTokenizer
    init(_ upstream: any Tokenizers.Tokenizer, rust: RustTokenizer) { self.upstream = upstream; self.rust = rust }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { rust.encode(text, special: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { rust.decode(tokenIds, skipSpecial: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        let tokens = try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        let rendered = rust.decode(tokens, skipSpecial: false)
        return rust.encode(rendered, special: false)
    }
}
