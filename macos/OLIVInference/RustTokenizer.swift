import Foundation

final class RustTokenizer: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    init(directory: URL) throws {
        guard let handle = directory.appendingPathComponent("tokenizer.json").path.withCString({ oliv_tokenizer_open($0) }) else { throw RuntimeError.invalidModel }
        self.handle = handle
    }
    deinit { oliv_tokenizer_close(handle) }
    func encode(_ text: String, special: Bool) -> [Int] {
        // Keep a valid pointer for empty text too: models may add BOS tokens.
        let bytes = Array(text.utf8) + [0]
        var count = 0
        return bytes.withUnsafeBufferPointer { buffer in
            guard let tokens = oliv_tokenizer_encode(handle, buffer.baseAddress!, buffer.count - 1, special, &count) else { return [] }
            defer { oliv_tokenizer_free_tokens(tokens, count) }
            return UnsafeBufferPointer(start: tokens, count: count).map(Int.init)
        }
    }
    func decode(_ tokens: [Int], skipSpecial: Bool) -> String {
        guard !tokens.isEmpty, tokens.allSatisfy({ $0 >= 0 && $0 <= Int(UInt32.max) }) else { return "" }
        let ids = tokens.map(UInt32.init)
        var count = 0
        return ids.withUnsafeBufferPointer { buffer in
            guard let bytes = oliv_tokenizer_decode(handle, buffer.baseAddress!, buffer.count, skipSpecial, &count) else { return "" }
            defer { oliv_tokenizer_free_bytes(bytes, count) }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
    }
}
