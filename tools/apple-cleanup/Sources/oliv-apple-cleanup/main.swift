import Foundation
import FoundationModels

// Developer benchmark only. SystemLanguageModel is the on-device model;
// this tool never constructs a PrivateCloudComputeLanguageModel.
@main
struct AppleCleanup {
    static func emit(_ object: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes + Data([10]))
    }

    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let transformations = environment["OLIV_APPLE_TRANSFORM_GUARDRAILS"] == "1"
        let model = transformations
            ? SystemLanguageModel(guardrails: .permissiveContentTransformations)
            : SystemLanguageModel.default
        let instructions = try environment["OLIV_APPLE_CLEANUP_INSTRUCTIONS"].map {
            try String(contentsOfFile: $0, encoding: .utf8)
        }
        let trace: FileHandle? = try environment["OLIV_APPLE_CLEANUP_TRACE"].map { path in
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw ToolError.invalidRequest
                }
            }
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try file.seekToEnd()
            return file
        }
        defer { try? trace?.close() }
        if CommandLine.arguments.dropFirst().first == "status" {
            var status: [String: Any] = [
                "availability": String(describing: model.availability),
                "supported_languages": model.supportedLanguages.map { $0.minimalIdentifier }.sorted(),
                "supports_th_TH": model.supportsLocale(Locale(identifier: "th_TH")),
                "supports_en_US": model.supportsLocale(Locale(identifier: "en_US")),
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "guardrails": transformations ? "permissiveContentTransformations" : "default",
            ]
            if #available(macOS 27.0, *) { status["variant"] = model.variant.displayName }
            try emit(status)
            return
        }
        while let line = readLine() {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw ToolError.invalidRequest
            }
            var reply: [String: Any] = ["id": request["id"] ?? NSNull()]
            do {
                switch request["cmd"] as? String {
                case "ping":
                    reply["ok"] = true
                    reply["runtime"] = "apple-foundation-models-local"
                case "generate", "llm_warm":
                    guard case .available = model.availability else {
                        throw ToolError.unavailable(String(describing: model.availability))
                    }
                    guard let content = request["content"] as? String else { throw ToolError.invalidRequest }
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    let tokens = min(max(request["max_tokens"] as? Int ?? 200, 1), 1024)
                    let start = ContinuousClock.now
                    let response = try await session.respond(to: content,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: tokens))
                    let elapsed = start.duration(to: .now)
                    reply["ok"] = true
                    reply["generation"] = response.content
                    reply["generation_ms"] = Double(elapsed.components.seconds) * 1000
                        + Double(elapsed.components.attoseconds) / 1e15
                    // Foundation Models does not expose Gemma's stop reason.
                    reply["stop_reason"] = "unknown"
                default:
                    throw ToolError.invalidRequest
                }
            } catch {
                reply["ok"] = false
                reply["code"] = "apple_generation_failed"
                reply["error"] = String(describing: error)
            }
            if let trace {
                let row = try JSONSerialization.data(withJSONObject: ["request": request, "reply": reply], options: [.sortedKeys])
                try trace.write(contentsOf: row + Data([10]))
            }
            try emit(reply)
        }
    }

    enum ToolError: Error { case invalidRequest, unavailable(String) }
}
