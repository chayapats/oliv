import Foundation

// Optional actual-model integration. The intentionally wrong encoder must
// accept the usual input but return an invalid tensor shape (see CONVERSION).
// Uses a supplied public WAV; no microphone, settings, injection or text logs.
guard CommandLine.arguments.count == 4 else {
    fatalError("usage: swift scripts/test_hybrid_recovery.swift RUNTIME_DIR WRONG_ENCODER PUBLIC_WAV")
}
let runtime = CommandLine.arguments[1], wrong = CommandLine.arguments[2], audio = CommandLine.arguments[3]

final class Worker {
    let process = Process(), input = Pipe(), output = Pipe()
    let signal = DispatchSemaphore(value: 0), lock = NSLock()
    var buffer = Data(), frames = [Data](), nextID = 0

    init(encoder: String?, fallback: Bool) throws {
        process.executableURL = URL(fileURLWithPath: runtime).appendingPathComponent("oliv-inference")
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.standardError
        var environment = ProcessInfo.processInfo.environment
        environment["OLIV_WHISPER_ENCODER"] = "mlx"
        environment["OLIV_WHISPER_ANE_ENCODER"] = encoder
        environment["OLIV_WHISPER_ANE_FALLBACK"] = fallback ? "1" : nil
        environment["OLIV_ENCODER_CAPTURE_DIR"] = nil
        environment["OLIV_WHISPER_BENCHMARK_SEED"] = "2026"
        process.environment = environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.buffer.append(bytes)
            while let end = self.buffer.firstIndex(of: 10) {
                self.frames.append(self.buffer.prefix(upTo: end)); self.buffer.removeSubrange(...end)
                self.signal.signal()
            }
        }
        try process.run()
    }

    func request(_ command: String, _ fields: [String: Any] = [:], ok: Bool = true) throws -> [String: Any] {
        nextID += 1
        var body = fields; body["cmd"] = command; body["id"] = nextID
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: body) + Data([10]))
        guard signal.wait(timeout: .now() + 300) == .success else {
            process.terminate()
            throw NSError(domain: "HybridRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "Helper timeout in \(command)"])
        }
        lock.lock(); let frame = frames.removeFirst(); lock.unlock()
        let reply = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
        precondition(reply["id"] as? Int == nextID && reply["ok"] as? Bool == ok, "Unexpected \(command) result")
        return reply
    }

    func close() throws {
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        precondition(process.terminationStatus == 0)
    }

    deinit {
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
    }
}

func check(_ reply: [String: Any], backend: String, fallback: Bool, text: String? = nil) {
    precondition(reply["encoder_backend"] as? String == backend)
    precondition(reply["encoder_fallback"] as? Bool == fallback)
    if let text { precondition((reply["text"] as? String)?.utf8.elementsEqual(text.utf8) == true, "Recovery changed the final transcript") }
    if reply["text"] != nil { precondition(reply["benchmark_seed"] as? Int == 2026) }
}

let control = try Worker(encoder: nil, fallback: false)
let baseline = try control.request("stt", ["wav_path": audio])
check(baseline, backend: "mlx", fallback: false)
let text = baseline["text"] as! String
precondition(!text.isEmpty)
try control.close()

let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mlmodelc").path
for (label, path) in [("load", missing), ("prediction", wrong)] {
    let strict = try Worker(encoder: path, fallback: false)
    if label == "load" {
        _ = try strict.request("stt_load", ok: false)
    } else {
        check(try strict.request("stt_load"), backend: "coreml", fallback: false)
        _ = try strict.request("stt", ["wav_path": audio], ok: false)
    }
    _ = try strict.request("ping")
    try strict.close()

    let recovered = try Worker(encoder: path, fallback: true)
    check(try recovered.request("stt_load"), backend: label == "load" ? "mlx" : "coreml", fallback: label == "load")
    if label == "prediction" {
        let preview = try recovered.request("stt", ["wav_path": audio, "preview_seq": 1])
        precondition(preview["skipped"] == nil && !(preview["text"] as? String ?? "").isEmpty,
                     "Prediction recovery lost the live preview")
    }
    for _ in 0..<2 {
        check(try recovered.request("stt", ["wav_path": audio]), backend: "mlx", fallback: true, text: text)
    }
    try recovered.close()
    print("\(label) failure: strict experiment rejected it; recovery used MLX with identical final bytes and a reusable worker")
}
