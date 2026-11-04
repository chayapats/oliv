import Foundation

// Optional reproducibility check with cached weights. The supplied JSONL lists
// WAV paths, including at least one utterance that reaches temperature fallback.
// No recording, settings, injection or transcript logs. A seed is research-only.
guard CommandLine.arguments.count == 3 else {
    fatalError("usage: swift scripts/test_whisper_sampling.swift RUNTIME_DIR FIXTURE_MANIFEST")
}
let process = Process(), input = Pipe(), output = Pipe()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("oliv-inference")
process.standardInput = input; process.standardOutput = output
process.standardError = FileHandle.standardError
var environment = ProcessInfo.processInfo.environment
environment["OLIV_WHISPER_ANE_ENCODER"] = nil
environment["OLIV_WHISPER_ANE_FALLBACK"] = nil
environment["OLIV_WHISPER_ENCODER"] = "mlx"
environment["OLIV_WHISPER_BENCHMARK_SEED"] = "2026"
process.environment = environment
let signal = DispatchSemaphore(value: 0), lock = NSLock()
var buffer = Data(), frames = [Data](), nextID = 0
output.fileHandleForReading.readabilityHandler = { handle in
    let bytes = handle.availableData
    lock.lock(); defer { lock.unlock() }
    buffer.append(bytes)
    while let end = buffer.firstIndex(of: 10) {
        frames.append(buffer.prefix(upTo: end)); buffer.removeSubrange(...end)
        signal.signal()
    }
}
try process.run()
func request(_ fields: [String: Any]) throws -> [String: Any] {
    nextID += 1
    var body = fields; body["id"] = nextID
    try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: body) + Data([10]))
    guard signal.wait(timeout: .now() + 120) == .success else {
        process.terminate()
        throw NSError(domain: "WhisperSampling", code: 1, userInfo: [NSLocalizedDescriptionKey: "Helper timeout"])
    }
    lock.lock(); let frame = frames.removeFirst(); lock.unlock()
    let reply = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
    precondition(reply["id"] as? Int == nextID && reply["ok"] as? Bool == true, "Helper failed")
    return reply
}
do {
    let rows = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    var exercised = false
    for row in rows.prefix(16) {
        let fixture = try JSONSerialization.jsonObject(with: Data(row.utf8)) as! [String: Any]
        let body: [String: Any] = ["cmd": "stt", "wav_path": fixture["path"] as! String]
        let first = try request(body)
        precondition(first["benchmark_seed"] as? Int == 2026)
        precondition(first["encoder_backend"] as? String == "mlx" && first["encoder_fallback"] as? Bool == false)
        guard let attempts = first["sampling_fallbacks"] as? Int, attempts > 0 else { continue }
        let text = first["text"] as! String
        for _ in 0..<2 {
            let again = try request(body)
            precondition(again["encoder_backend"] as? String == "mlx" && again["encoder_fallback"] as? Bool == false)
            precondition((again["text"] as? String)?.utf8.elementsEqual(text.utf8) == true,
                         "Seeded fallback changed its text between requests")
            precondition(again["sampling_fallbacks"] as? Int == attempts)
            precondition(again["avg_logprob"] as? Double == first["avg_logprob"] as? Double)
        }
        print("Seed 2026 reproduced identical final bytes, logprob and \(attempts) sampling attempts across three requests")
        exercised = true
        break
    }
    precondition(exercised, "Supply a fixture that actually reaches temperature fallback")
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    output.fileHandleForReading.readabilityHandler = nil
    precondition(process.terminationStatus == 0)
} catch {
    process.terminate(); process.waitUntilExit()
    throw error
}
