// Developer-only LaBSE scoring; never linked or copied into OLIV.app.
import Foundation
import Darwin
import MLX
import MLXNN
import MLXEmbedders

enum RuntimeError: Error { case invalidModel, invalidRequest }

@main
struct SemanticMain {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw RuntimeError.invalidRequest }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let configuration = try JSONDecoder().decode(BertConfiguration.self,
            from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        let model = BertModel(configuration)
        let weights = try loadArrays(url: directory.appendingPathComponent("model.safetensors"))
        try model.update(parameters: ModuleParameters.unflattened(model.sanitize(weights: weights)), verify: [.all])
        model.train(false); eval(model)
        let tokenizer = try RustTokenizer(directory: directory)
        let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        signal(SIGPIPE, SIG_IGN)
        let parent = getppid()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { if getppid() != parent { _exit(0) } }
        watchdog.resume()
        defer { watchdog.cancel() }
        var cache = [String: [Float]]()
        func embed(_ text: String) throws -> [Float] {
            if let embedding = cache[text] { return embedding }
            var tokens = tokenizer.encode(text.isEmpty ? " " : text, special: true)
            guard !tokens.isEmpty else { throw RuntimeError.invalidRequest }
            if tokens.count > 256 { tokens = Array(tokens.prefix(255)) + [tokens.last!] }
            let ids = MLXArray(tokens).expandedDimensions(axis: 0)
            let result = model(ids, tokenTypeIds: MLXArray.zeros(ids.shape, type: Int32.self),
                attentionMask: MLXArray.ones(ids.shape, type: Int32.self))
            guard let pooled = result.pooledOutput else { throw RuntimeError.invalidModel }
            let normalized = pooled / maximum(sqrt(sum(pooled * pooled, axis: -1, keepDims: true)), MLXArray(Float(1e-12)))
            eval(normalized)
            let values = normalized.asArray(Float.self)
            // Bounded cache for large local evaluation sets.
            if cache.count >= 4096 { cache.removeAll(keepingCapacity: true) }
            cache[text] = values
            Memory.clearCache()
            return values
        }
        // POSIX read returns a request while stdin stays open.
        var pending = Data()
        while true {
            if let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end); pending.removeSubrange(...end)
                var reply: [String: Any] = [:]
                let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                do {
                    guard request["cmd"] as? String == "similarity",
                        let texts = request["texts"] as? [String], texts.count == 2 else { throw RuntimeError.invalidRequest }
                    let a = try embed(texts[0]), b = try embed(texts[1])
                    guard a.count == b.count else { throw RuntimeError.invalidModel }
                    let similarity = zip(a, b).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                    reply = ["ok": true, "similarity": Double(similarity)]
                } catch { reply = ["ok": false, "error": "Native semantic scoring failed"] }
                reply["id"] = request["id"] ?? NSNull()
                try output.write(contentsOf: JSONSerialization.data(withJSONObject: reply) + Data([10]))
            } else {
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 2 * 1024 * 1024 else { throw RuntimeError.invalidRequest }
            }
        }
    }
}
