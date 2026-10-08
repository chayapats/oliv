import Foundation
@preconcurrency import AVFoundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon

// Only this helper links MLX. The UI and Rust ping do not initialise Metal.
enum RuntimeError: Error { case invalidRequest, invalidModel, missingModel, invalidLanguage, invalidAudio }

actor ModelRuntime {
    static let repositories = [
        "typhoon-turbo-mlx": "chayapats/typhoon-whisper-turbo-mlx",
        "pathumma-mlx": "kinoppy555/Pathumma-whisper-th-large-v3-mlx",
        "mlx-large-v3": "mlx-community/whisper-large-v3-mlx",
    ]
    static let cleanupRepository = "mlx-community/gemma-4-e2b-it-4bit"
    private var whisper: WhisperModel?
    private var engine: String?
    private var cleanup: Task<ModelContainer, Error>?
    private let cache = HubCache.default

    private func snapshot(_ repository: String) throws -> URL {
        guard let repo = Repo.ID(rawValue: repository),
              let config = cache.cachedFilePath(repo: repo, kind: .model, revision: "main", filename: "config.json")
        else { throw RuntimeError.missingModel }
        let directory = config.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.contains(where: { ["safetensors", "npz"].contains($0.pathExtension) }),
              files.filter({ ["safetensors", "npz"].contains($0.pathExtension) }).allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
        else { throw RuntimeError.missingModel }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any],
                  let mapping = object["weight_map"] as? [String: String], !mapping.isEmpty,
                  Set(mapping.values).allSatisfy({ filename in
                      guard !filename.contains("/"), filename.hasSuffix(".safetensors") else { return false }
                      let url = directory.appendingPathComponent(filename)
                      guard FileManager.default.fileExists(atPath: url.path) else { return false }
                      return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { $0 > 0 } ?? false
                  }) else { throw RuntimeError.missingModel }
        } else if repository == Self.cleanupRepository && !files.contains(where: { $0.lastPathComponent == "model.safetensors" }) {
            // A partial sharded Gemma download is not a complete cached model.
            throw RuntimeError.missingModel
        }
        return directory
    }

    private func loadWhisper(_ selected: String) async throws -> WhisperModel {
        if engine == selected, let whisper { return whisper }
        guard let repo = Self.repositories[selected] else { throw RuntimeError.invalidModel }
        // Release the previous STT weights before loading another multi-GB model.
        whisper = nil; engine = nil; Memory.clearCache()
        let resources = ProcessInfo.processInfo.environment["OLIV_WHISPER_TOKENIZER"]
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("whisper-tokenizer").path
        let loaded = try await WhisperModel.fromDirectory(try snapshot(repo), tokenizerDirectory: URL(fileURLWithPath: resources))
        whisper = loaded; engine = selected
        return loaded
    }

    private func cleanupModel() async throws -> ModelContainer {
        if let cleanup { return try await cleanup.value }
        let directory = try snapshot(Self.cleanupRepository)
        let task = Task {
            try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        }
        cleanup = task
        do { return try await task.value }
        catch { cleanup = nil; throw error }
    }

    private func generate(_ content: String) async throws -> String {
        let model = try await cleanupModel()
        let input = try await model.prepare(input: UserInput(prompt: content, additionalContext: ["enable_thinking": false]))
        let stream = try await model.generate(input: input, parameters: GenerateParameters(maxTokens: 200, temperature: 0))
        var text = ""
        for await event in stream { if case .chunk(let chunk) = event { text += chunk } }
        Memory.clearCache()
        return text
    }

    func handle(_ request: [String: Any]) async throws -> [String: Any] {
        guard let cmd = request["cmd"] as? String else { throw RuntimeError.invalidRequest }
        let selected = request["engine"] as? String ?? "typhoon-turbo-mlx"
        switch cmd {
        case "ping": return ["ok": true, "runtime": "native-mlx"]
        case "stt_load":
            _ = try await loadWhisper(selected)
            return ["ok": true]
        case "stt":
            let samples = try Self.audio(request)
            let model = try await loadWhisper(selected)
            let result = try model.transcribe(samples, language: request["language"] as? String,
                initialPrompt: request["initial_prompt"] as? String, fallback: selected != "mlx-large-v3")
            return ["ok": true, "text": result.text, "avg_logprob": result.avgLogprob, "language": result.language]
        case "generate":
            guard let content = request["content"] as? String else { throw RuntimeError.invalidRequest }
            return ["ok": true, "generation": try await generate(content)]
        case "tokenize":
            guard let content = request["content"] as? String else { throw RuntimeError.invalidRequest }
            let model = try await cleanupModel()
            let input = try await model.prepare(input: UserInput(prompt: content, additionalContext: ["enable_thinking": false]))
            return ["ok": true, "tokens": input.text.tokens.asArray(Int.self)]
        case "llm_warm":
            let content = request["content"] as? String ?? "hello"
            if request["background"] as? Bool == true {
                // Actor serialisation + the stored load task keep publication safe.
                Task { _ = try? await self.generate(content) }
                return ["ok": true, "cleanup_warming": true]
            }
            _ = try await generate(content)
            return ["ok": true, "cleanup_warming": false]
        case "download":
            guard let repos = request["repos"] as? [String], repos.count <= 4,
                  repos.allSatisfy({ Set(Self.repositories.values).union([Self.cleanupRepository]).contains($0) })
            else { throw RuntimeError.invalidRequest }
            var downloaded = [String]()
            for repository in repos {
                if (try? snapshot(repository)) != nil {
                    downloaded.append(repository)
                    emit(["id": request["id"] ?? NSNull(), "event": "progress", "repo": repository, "pct": 100])
                    continue
                }
                do {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 120
                    configuration.timeoutIntervalForResource = 24 * 3600
                    let client = HubClient(session: URLSession(configuration: configuration), host: URL(string: "https://huggingface.co")!, cache: cache)
                    let id = request["id"] ?? NSNull()
                    _ = try await client.downloadSnapshot(of: Repo.ID(rawValue: repository)!, matching: ["*.json", "*.safetensors", "*.npz", "*.model", "*.txt", "LICENSE*"], progressHandler: { progress in
                        emit(["id": id, "event": "progress", "repo": repository, "pct": Int(min(1, max(0, progress.fractionCompleted)) * 100)])
                    })
                    _ = try snapshot(repository)
                    downloaded.append(repository)
                } catch {
                    return ["ok": false, "downloaded": downloaded, "failed_repo": repository, "error": "Model download failed; check network and available disk space"]
                }
            }
            return ["ok": true, "downloaded": downloaded]
        default: throw RuntimeError.invalidRequest
        }
    }

    static func audio(_ request: [String: Any]) throws -> [Float] {
        let samples: [Float]
        if let encoded = request["pcm_b64"] as? String, let bytes = Data(base64Encoded: encoded), bytes.count % 4 == 0, bytes.count <= 38_400_000 {
            samples = bytes.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
            }
        } else if let filename = request["wav_path"] as? String {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: filename))
            guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= 600,
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { throw RuntimeError.invalidAudio }
            try file.read(into: input)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            guard let converter = AVAudioConverter(from: input.format, to: format),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32))
            else { throw RuntimeError.invalidAudio }
            var supplied = false, error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            if let error { throw error }
            guard let channel = output.floatChannelData?[0] else { throw RuntimeError.invalidAudio }
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        } else { throw RuntimeError.invalidAudio }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw RuntimeError.invalidAudio }
        return samples
    }
}
