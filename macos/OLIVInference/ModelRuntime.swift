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
    // Developer experiments only; the app's model/download UI remains Gemma.
    static let cleanupRepository = ProcessInfo.processInfo.environment["OLIV_CLEANUP_REPOSITORY"]
        ?? "mlx-community/gemma-4-e2b-it-4bit"
    private var whisper: WhisperModel?
    private var engine: String?
    private var cleanup: Task<ModelContainer, Error>?
    private var cleanupLoadEpoch: UInt64 = 0
    private var residency = CleanupResidency()
    private var cleanupIdleTask: Task<Void, Never>?
    private var cleanupWarmTask: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?
    // Evaluation may shorten the interval, or disable idle eviction with 0.
    // The shipping default keeps brief pauses warm and releases long idle RAM.
    private var cleanupIdleSeconds: Double = {
        guard let raw = ProcessInfo.processInfo.environment["OLIV_CLEANUP_IDLE_SECONDS"],
              let seconds = Double(raw), seconds.isFinite, seconds >= 0 else { return 30 }
        return min(seconds, 3600)
    }()
    private let cache = HubCache.default

    private func monitorMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.trimCleanup() }
        }
        memoryPressure = source
        source.resume()
    }

    private func beginCleanupUse() {
        cleanupIdleTask?.cancel()
        cleanupIdleTask = nil
        residency.begin()
    }

    private func endCleanupUse() {
        residency.end()
        scheduleCleanupEviction()
    }

    private func trimCleanup() {
        residency.requestEviction()
        scheduleCleanupEviction()
    }

    private func scheduleCleanupEviction() {
        guard residency.users == 0 else { return }
        cleanupIdleTask?.cancel()
        guard residency.evictionRequested || cleanupIdleSeconds > 0 else { return }
        let epoch = residency.epoch
        let delay = residency.evictionRequested ? 0 : cleanupIdleSeconds
        cleanupIdleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            // Run after the caller returns and releases its local model/stream.
            await self?.evictCleanup(epoch: epoch)
        }
    }

    private func evictCleanup(epoch: UInt64) {
        guard residency.canEvict(epoch: epoch) else { return }
        cleanup = nil
        residency.didEvict()
        cleanupIdleTask = nil
        Memory.clearCache()
    }

    private func prewarmCleanup() async throws {
        beginCleanupUse()
        defer { endCleanupUse() }
        _ = try await cleanupModel()
        Memory.clearCache()
    }

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
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["OLIV_CLEANUP_MODEL_DIRECTORY"] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else { directory = try snapshot(Self.cleanupRepository) }
        let task = Task {
            try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        }
        cleanupLoadEpoch &+= 1
        let epoch = cleanupLoadEpoch
        cleanup = task
        do { return try await task.value }
        catch {
            if cleanupLoadEpoch == epoch { cleanup = nil }
            throw error
        }
    }

    /// Cleanup replies are one sentence; voice-editing transforms (Command mode,
    /// translation) ask for more, up to this ceiling.
    static let maxGenerationTokens = 1024

    /// The answer and why generation stopped: "stop" when the model ended
    /// it, "length" when it was still writing at `maxTokens` (the text is cut
    /// off), "cancelled", or "unknown" when the stream gave no reason.
    private func generate(_ content: String, maxTokens: Int = 200) async throws -> (text: String, stopReason: String) {
        beginCleanupUse()
        defer { endCleanupUse() }
        let model = try await cleanupModel()
        let input = try await model.prepare(input: UserInput(prompt: content, additionalContext: ["enable_thinking": false]))
        let stream = try await model.generate(input: input, parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
        var text = "", stopReason = "unknown"
        for await event in stream {
            switch event {
            case .chunk(let chunk): text += chunk
            case .info(let info): stopReason = Self.name(info.stopReason)
            default: break
            }
        }
        Memory.clearCache()
        return (text, stopReason)
    }

    static func name(_ reason: GenerateStopReason) -> String {
        switch reason {
        case .stop: "stop"
        case .length: "length"
        case .cancelled: "cancelled"
        }
    }

    func handle(_ request: [String: Any]) async throws -> [String: Any] {
        guard let cmd = request["cmd"] as? String else { throw RuntimeError.invalidRequest }
        monitorMemoryPressure()
        let selected = request["engine"] as? String ?? "typhoon-turbo-mlx"
        switch cmd {
        case "ping": return ["ok": true, "runtime": "native-mlx"]
        case "stt_load":
            _ = try await loadWhisper(selected)
            return ["ok": true]
        case "stt":
            let parsing = ContinuousClock.now
            let samples = try Self.audio(request)
            if let seq = request["preview_seq"] as? Int {
                return preview(samples, engine: selected, seq: seq, request: request,
                               audioSeconds: Self.seconds(since: parsing))
            }
            let model = try await loadWhisper(selected)
            let result = try model.transcribe(samples, language: request["language"] as? String,
                initialPrompt: request["initial_prompt"] as? String, fallback: selected != "mlx-large-v3")
            return ["ok": true, "text": result.text, "avg_logprob": result.avgLogprob, "language": result.language]
        case "generate":
            guard let content = request["content"] as? String else { throw RuntimeError.invalidRequest }
            let maxTokens = min(max((request["max_tokens"] as? Int) ?? 200, 1), Self.maxGenerationTokens)
            // Voice editing refuses an answer that stopped for any reason but
            // "stop" (transform_generation in oliv-sidecar); cleanup ignores it.
            let generation = try await generate(content, maxTokens: maxTokens)
            return ["ok": true, "generation": generation.text, "stop_reason": generation.stopReason]
        case "tokenize":
            guard let content = request["content"] as? String else { throw RuntimeError.invalidRequest }
            beginCleanupUse()
            defer { endCleanupUse() }
            let model = try await cleanupModel()
            let input = try await model.prepare(input: UserInput(prompt: content, additionalContext: ["enable_thinking": false]))
            return ["ok": true, "tokens": input.text.tokens.asArray(Int.self)]
        case "llm_warm":
            let content = request["content"] as? String ?? "hello"
            if request["background"] as? Bool == true {
                // Deduplicate repeated presses while a background load is active.
                if cleanupWarmTask == nil {
                    let loadOnly = request["load_only"] as? Bool == true
                    cleanupWarmTask = Task {
                        if loadOnly { try? await self.prewarmCleanup() }
                        else { _ = try? await self.generate(content) }
                        self.cleanupWarmTask = nil
                    }
                }
                return ["ok": true, "cleanup_warming": true]
            }
            if request["load_only"] as? Bool == true { try await prewarmCleanup() }
            else { _ = try await generate(content) }
            return ["ok": true, "cleanup_warming": false]
        case "llm_trim":
            trimCleanup()
            return ["ok": true, "cleanup_busy": residency.users > 0]
        case "memory_policy":
            guard let seconds = request["cleanup_idle_seconds"] as? Double,
                  seconds.isFinite, (0...3600).contains(seconds) else { throw RuntimeError.invalidRequest }
            cleanupIdleSeconds = seconds
            cleanupIdleTask?.cancel()
            cleanupIdleTask = nil
            scheduleCleanupEviction()
            return ["ok": true, "cleanup_idle_seconds": cleanupIdleSeconds]
        case "memory_status":
            return ["ok": true, "cleanup_resident": cleanup != nil,
                    "cleanup_users": residency.users, "cleanup_idle_seconds": cleanupIdleSeconds,
                    "mlx_active_bytes": Memory.activeMemory, "mlx_cache_bytes": Memory.cacheMemory]
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

    /// Previews encode at least this much audio (seconds)…
    static let previewFloorSeconds = 10.0
    /// …or the audio plus this much silence, whichever is longer. Measured in
    /// #46: mid-sentence previews were about as close to the final as with
    /// the full 30 s window, at about 30% of the encoder's time; 6–8 s floors
    /// were faster but further off.
    static let previewTailSeconds = 2.0

    /// Live preview: greedy, no temperature fallback, no prompt, and only on
    /// the engine already in memory — a preview never loads a model. The
    /// encoder runs on the audio there is, not a 30 s window (PreviewEncode).
    /// A cancel (see PreviewCancellation) stops it between tokens.
    /// `preview_floor` / `preview_tail` override the window (evaluation only;
    /// a floor of 30 is the full window every final pass uses).
    private func preview(_ samples: [Float], engine selected: String, seq: Int, request: [String: Any],
                         audioSeconds: Double) -> [String: Any] {
        let cancellation = PreviewCancellation.shared
        guard engine == selected, let whisper else { return ["ok": true, "text": "", "skipped": "notLoaded"] }
        let encode = WhisperModel.PreviewEncode(
            floorSeconds: (request["preview_floor"] as? Double).map { min(30, max(0, $0)) } ?? Self.previewFloorSeconds,
            tailSeconds: (request["preview_tail"] as? Double).map { min(30, max(0, $0)) } ?? Self.previewTailSeconds)
        var reply: [String: Any] = ["ok": true]
        do {
            let result = try whisper.transcribe(samples, language: nil, initialPrompt: nil, fallback: false,
                                                shouldStop: { cancellation.isCancelled(seq) }, preview: encode)
            reply["text"] = result.text
        } catch {
            // Cancelled, or a decode failure: either way nothing to show, and
            // the helper (with its loaded models) must stay up for the release.
            if cancellation.isCancelled(seq) { Memory.clearCache() }
            reply["text"] = ""
            reply["skipped"] = cancellation.isCancelled(seq) ? "cancelled" : "failed"
        }
        // Where the time went; never any text.
        reply["timings"] = ["audio": audioSeconds, "mel": encode.melSeconds, "encode": encode.encodeSeconds,
                            "decode": encode.decodeSeconds, "frames": Double(encode.encodedFrames),
                            "tokens": Double(encode.tokens), "repeat": encode.stoppedRepeat ? 1 : 0,
                            "limit": encode.stoppedLimit ? 1 : 0]
        return reply
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
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
