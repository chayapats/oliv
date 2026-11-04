import Foundation
import CoreML
import WhisperKit

@main
struct ANEWhisper {
    enum Failure: Error { case usage(String) }

    final class CleanupProxy {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var pending = Data()
        init(_ executable: String) throws {
            process.executableURL = URL(fileURLWithPath: executable)
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        func request(_ body: [String: Any]) throws -> [String: Any] {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: body) + Data([10]))
            while true {
                if let end = pending.firstIndex(of: 10) {
                    let line = pending[..<end]
                    pending.removeSubrange(...end)
                    guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw Failure.usage("Invalid cleanup reply")
                    }
                    return value
                }
                let bytes = output.fileHandleForReading.availableData
                guard !bytes.isEmpty, pending.count + bytes.count <= 2 * 1024 * 1024 else {
                    throw Failure.usage("Cleanup process stopped or reply exceeded 2 MiB")
                }
                pending.append(bytes)
            }
        }
        deinit {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
    }

    static func worker() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["OLIV_COREML_MODEL_DIR"], let tokenizer = env["OLIV_COREML_TOKENIZER_DIR"] else {
            throw Failure.usage("Worker needs OLIV_COREML_MODEL_DIR and OLIV_COREML_TOKENIZER_DIR")
        }
        var kit: WhisperKit?
        var cleanup: CleanupProxy?
        while let line = readLine() {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw Failure.usage("Invalid request")
            }
            var reply: [String: Any] = ["id": request["id"] ?? NSNull()]
            do {
                switch request["cmd"] as? String {
                case "ping": reply["ok"] = true
                case "stt_load", "stt":
                    if kit == nil {
                        let compute = env["OLIV_COREML_COMPUTE"] ?? "ane"
                        guard ["ane", "gpu"].contains(compute) else { throw Failure.usage("Worker compute must be ane or gpu") }
                        let units: MLComputeUnits = compute == "gpu" ? .cpuAndGPU : .cpuAndNeuralEngine
                        kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder,
                            tokenizerFolder: URL(fileURLWithPath: tokenizer),
                            computeOptions: ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: units, textDecoderCompute: units),
                            verbose: false, prewarm: false, load: true, download: false))
                    }
                    reply["ok"] = true
                    if request["cmd"] as? String == "stt" {
                        if let prompt = request["initial_prompt"] as? String, !prompt.isEmpty {
                            throw Failure.usage("This benchmark does not implement prompted STT")
                        }
                        guard let encoded = request["pcm_b64"] as? String,
                              let data = Data(base64Encoded: encoded), !data.isEmpty,
                              data.count % 4 == 0, data.count <= 38_400_000 else {
                            throw Failure.usage("Invalid PCM")
                        }
                        let samples = data.withUnsafeBytes { bytes in
                            stride(from: 0, to: bytes.count, by: 4).map {
                                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                            }
                        }
                        guard samples.allSatisfy(\.isFinite) else { throw Failure.usage("Nonfinite PCM") }
                        let language = request["language"] as? String
                        let options = DecodingOptions(verbose: false, language: language,
                            temperature: 0, temperatureFallbackCount: 5,
                            detectLanguage: language == nil, skipSpecialTokens: true,
                            withoutTimestamps: false, wordTimestamps: false, concurrentWorkerCount: 1)
                        let results = try await kit!.transcribe(audioArray: samples, decodeOptions: options)
                        reply["text"] = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        let segments = results.flatMap(\.segments)
                        reply["avg_logprob"] = segments.isEmpty ? -10 : segments.reduce(Float(0)) { $0 + $1.avgLogprob } / Float(segments.count)
                        reply["language"] = results.first?.language ?? ""
                    }
                case "generate", "llm_warm":
                    if cleanup == nil {
                        guard let executable = env["OLIV_COREML_CLEANUP_EXECUTABLE"] else {
                            throw Failure.usage("No cleanup executable configured")
                        }
                        cleanup = try CleanupProxy(executable)
                    }
                    reply = try cleanup!.request(request)
                default: throw Failure.usage("Unsupported benchmark request")
                }
            } catch {
                reply["ok"] = false
                reply["code"] = "coreml_inference_failed"
                reply["error"] = String(describing: error)
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) + Data([10]))
        }
    }

    static func write(_ value: [String: Any], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(2)
        }
    }

    static func run() async throws {
        if ProcessInfo.processInfo.environment["OLIV_COREML_MODEL_DIR"] != nil {
            try await worker()
            return
        }
        let argv = Array(CommandLine.arguments.dropFirst())
        var args: [String: String] = [:]
        let accepted: Set<String> = ["model-dir", "tokenizer-dir", "manifest", "audio-root", "out", "compute", "limit", "label", "language", "preview", "prepare"]
        var i = 0
        while i < argv.count {
            guard argv[i].hasPrefix("--"), i + 1 < argv.count else {
                throw Failure.usage("--model-dir PATH --manifest PATH --out PATH [--audio-root PATH] [--compute ane|gpu|cpu] [--limit N]")
            }
            let key = String(argv[i].dropFirst(2))
            guard accepted.contains(key), args[key] == nil else { throw Failure.usage("Unknown or duplicate argument: \(argv[i])") }
            args[key] = argv[i + 1]
            i += 2
        }
        for key in ["preview", "prepare"] {
            if let value = args[key], !["yes", "no"].contains(value) { throw Failure.usage("--\(key) must be yes or no") }
        }
        guard let model = args["model-dir"], let manifest = args["manifest"], let out = args["out"] else {
            throw Failure.usage("--model-dir, --manifest and --out are required")
        }
        let compute = args["compute"] ?? "ane"
        let units: MLComputeUnits
        switch compute {
        case "ane": units = .cpuAndNeuralEngine
        case "gpu": units = .cpuAndGPU
        case "cpu": units = .cpuOnly
        default: throw Failure.usage("--compute must be ane, gpu or cpu")
        }
        let manifestURL = URL(fileURLWithPath: manifest)
        let root = URL(fileURLWithPath: args["audio-root"] ?? manifestURL.deletingLastPathComponent().path)
        var seen = Set<String>()
        var rows = try String(contentsOf: manifestURL, encoding: .utf8).split(separator: "\n").compactMap { line -> [String: Any]? in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return nil }
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, row["path"] is String, seen.insert(id).inserted else {
                throw Failure.usage("Manifest has a missing id/path or duplicate id")
            }
            return row
        }
        if let value = args["limit"] {
            guard let limit = Int(value), limit > 0 else { throw Failure.usage("--limit must be positive") }
            rows = Array(rows.prefix(limit))
        }
        guard !rows.isEmpty else { throw Failure.usage("Empty manifest") }
        func audioPath(_ row: [String: Any]) -> String {
            let path = row["path"] as! String
            return path.hasPrefix("/") ? path : root.appendingPathComponent(path).path
        }
        for row in rows where !FileManager.default.fileExists(atPath: audioPath(row)) {
            throw Failure.usage("Missing audio file for \(row["id"]!)")
        }
        let loadStart = Date()
        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: model,
            tokenizerFolder: args["tokenizer-dir"].map { URL(fileURLWithPath: $0) },
            computeOptions: ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: units, textDecoderCompute: units),
            verbose: false, prewarm: true, load: true, download: false))
        let loadSeconds = Date().timeIntervalSince(loadStart)
        if args["prepare"] == "yes" {
            try write(["model_dir": model, "compute": compute, "load_s": loadSeconds], to: out)
            print("Prepared \(compute) model in \(loadSeconds) seconds")
            return
        }
        let options = DecodingOptions(verbose: false, language: args["language"],
            temperature: 0, temperatureFallbackCount: 5,
            detectLanguage: args["language"] == nil, skipSpecialTokens: true,
            withoutTimestamps: false, wordTimestamps: false, concurrentWorkerCount: 1)
        let warmStart = Date()
        _ = try? await kit.transcribe(audioPath: audioPath(rows[0]), decodeOptions: options)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        var clips: [[String: Any]] = []
        let runStart = Date()
        for (index, row) in rows.enumerated() {
            let id = row["id"] as! String
            var clip = row
            clip["bucket"] = String(id.prefix { !$0.isNumber })
            let start = Date()
            do {
                var results: [TranscriptionResult]
                if args["preview"] == "yes" {
                    let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath(row))
                    let duration = Double(audio.count) / 16000
                    var onset = 0.0
                    for offset in stride(from: 0, to: audio.count, by: 320) {
                        let frame = audio[offset..<min(offset + 320, audio.count)]
                        if sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)) > 0.01 {
                            onset = Double(offset) / 16000
                            break
                        }
                    }
                    var events: [[String: Any]] = []
                    var next = 0.5
                    while next < duration {
                        let delay = next - Date().timeIntervalSince(start)
                        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                        let available = min(audio.count, max(1, Int(Date().timeIntervalSince(start) * 16000)))
                        let partial = try await kit.transcribe(audioArray: Array(audio.prefix(available)), decodeOptions: options)
                        let text = partial.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        events.append(["audio_s": Double(available) / 16000,
                                       "wall_s": Date().timeIntervalSince(start), "text": text])
                        next = Date().timeIntervalSince(start) + 0.3
                    }
                    let delay = duration - Date().timeIntervalSince(start)
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
                    clip["release_to_final_s"] = max(0, Date().timeIntervalSince(start) - duration)
                    clip["speech_onset_s"] = onset
                    clip["preview_events"] = events
                    if let first = events.first(where: { !($0["text"] as! String).isEmpty }) {
                        clip["first_text_from_speech_s"] = max(0, (first["wall_s"] as! Double) - onset)
                    }
                } else {
                    results = try await kit.transcribe(audioPath: audioPath(row), decodeOptions: options)
                }
                let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                clip["raw"] = text
                clip["final"] = text
                clip["language"] = results.first?.language
            } catch {
                clip["raw"] = ""
                clip["final"] = ""
                clip["error"] = String(describing: error)
            }
            clip["latency_s"] = Date().timeIntervalSince(start)
            clips.append(clip)
            // Checkpoint atomically so an interrupted experiment retains evidence.
            try write(["label": args["label"] ?? "Typhoon Core ML \(compute)",
                "engine": "typhoon-coreml", "runtime": "WhisperKit", "cleanup_model": NSNull(),
                "model_dir": model, "compute": compute, "manifest": manifestURL.path,
                "load_s": loadSeconds, "warmup_s": warmSeconds,
                "wall_s": Date().timeIntervalSince(runStart), "clips": clips,
                "complete": clips.count == rows.count], to: out)
            if (index + 1) % 25 == 0 || index + 1 == rows.count {
                print("Transcribed \(index + 1)/\(rows.count)")
            }
        }
    }
}
