import Foundation

// Optional integration check. Requires a cached STT checkpoint, a public test
// WAV, and OLIV_WHISPER_ANE_ENCODER pointing to the converted encoder. It never
// records audio, changes settings, injects text or prints a transcript.
guard CommandLine.arguments.count == 3,
      ProcessInfo.processInfo.environment["OLIV_WHISPER_ANE_ENCODER"] != nil else {
    fatalError("usage: OLIV_WHISPER_ANE_ENCODER=... swift scripts/test_hybrid_preview.swift RUNTIME_DIR PUBLIC_WAV")
}
let directory = CommandLine.arguments[1], audio = CommandLine.arguments[2]
let process = Process(), input = Pipe(), output = Pipe()
process.executableURL = URL(fileURLWithPath: directory).appendingPathComponent("oliv-inference")
process.standardInput = input; process.standardOutput = output
process.standardError = FileHandle.standardError
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

func send(_ body: [String: Any]) throws {
    try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: body) + Data([10]))
}

func request(_ command: String, _ fields: [String: Any] = [:], cancelThrough: Int? = nil) throws -> [String: Any] {
    nextID += 1
    var body = fields
    body["id"] = nextID; body["cmd"] = command
    try send(body)
    if let cancelThrough {
        // The stdin reader must cancel work while the serialized model loop is
        // busy. It must not emit an extra reply or corrupt the final's cache.
        Thread.sleep(forTimeInterval: 0.02)
        try send(["cmd": "cancel_preview", "through": cancelThrough])
    }
    guard signal.wait(timeout: .now() + 300) == .success else {
        process.terminate()
        throw NSError(domain: "HybridPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Helper timeout"])
    }
    lock.lock(); let frame = frames.removeFirst(); lock.unlock()
    let reply = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
    guard reply["id"] as? Int == nextID && reply["ok"] as? Bool == true else {
        throw NSError(domain: "HybridPreview", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "Helper failed during \(command): \(reply["error"] as? String ?? "unexpected reply ID")"])
    }
    return reply
}

do {
    let cold = try request("stt", ["wav_path": audio, "preview_seq": 1])
    precondition(cold["skipped"] as? String == "notLoaded", "A preview unexpectedly loaded STT")
    _ = try request("stt_load")
    let before = try request("stt", ["wav_path": audio])["text"] as! String
    precondition(!before.isEmpty, "Use an audible public speech fixture")
    var measured = [[String: Any]]()
    for (index, floor) in [10, 15, 20, 25, 30].enumerated() {
        let reply = try request("stt", ["wav_path": audio, "preview_seq": index + 2,
                                        "preview_floor": Double(floor), "preview_tail": 0.0])
        precondition(reply["skipped"] == nil && !(reply["text"] as? String ?? "").isEmpty,
                     "An initialized hybrid encoder failed to preview")
        let timings = reply["timings"] as! [String: Double]
        precondition(timings["frames"]! >= Double(floor * 100) && timings["frames"]! <= 3000)
        precondition(timings.values.allSatisfy { $0.isFinite && $0 >= 0 })
        measured.append(["requested_floor": floor, "timings": timings])
    }
    let cancelled = try request("stt", ["wav_path": audio, "preview_seq": 100], cancelThrough: 100)
    precondition(cancelled["skipped"] as? String == "cancelled")
    let after = try request("stt", ["wav_path": audio])["text"] as! String
    precondition(before.utf8.elementsEqual(after.utf8), "Previews or cancellation changed the final transcript")
    print(String(decoding: try JSONSerialization.data(withJSONObject: [
        "previews": measured, "cancelled": true, "final_bytes_unchanged": true
    ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    output.fileHandleForReading.readabilityHandler = nil
    precondition(process.terminationStatus == 0)
    lock.lock(); let extra = frames.count; lock.unlock()
    precondition(extra == 0, "Out-of-band cancellation emitted a reply")
} catch {
    process.terminate(); process.waitUntilExit()
    throw error
}
