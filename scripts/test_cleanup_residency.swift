import Foundation

// Optional integration check: requires the already downloaded cleanup model.
// No microphone, private examples, downloads, settings writes or network calls.
let directory = CommandLine.arguments.dropFirst().first ?? "build/native-runtime"
let process = Process(), input = Pipe(), output = Pipe()
process.executableURL = URL(fileURLWithPath: directory).appendingPathComponent("oliv-inference")
process.standardInput = input
process.standardOutput = output
process.standardError = FileHandle.nullDevice
var environment = ProcessInfo.processInfo.environment
environment["OLIV_CLEANUP_IDLE_SECONDS"] = "3"
process.environment = environment
let signal = DispatchSemaphore(value: 0), lock = NSLock()
var buffer = Data(), frames = [Data](), nextID = 0
output.fileHandleForReading.readabilityHandler = { handle in
    let bytes = handle.availableData
    lock.lock(); defer { lock.unlock() }
    buffer.append(bytes)
    while let end = buffer.firstIndex(of: 10) {
        frames.append(buffer.prefix(upTo: end))
        buffer.removeSubrange(...end)
        signal.signal()
    }
}
try process.run()

func request(_ command: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
    nextID += 1
    var body = fields
    body["id"] = nextID; body["cmd"] = command
    try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: body) + Data([10]))
    guard signal.wait(timeout: .now() + 120) == .success else {
        process.terminate()
        throw NSError(domain: "CleanupResidency", code: 1, userInfo: [NSLocalizedDescriptionKey: "No helper reply"])
    }
    lock.lock(); let frame = frames.removeFirst(); lock.unlock()
    let reply = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
    precondition(reply["id"] as? Int == nextID && reply["ok"] as? Bool == true,
                 "Helper failed; check the local model and runtime")
    return reply
}

func generate() throws {
    let reply = try request("generate", ["content": "Correct spelling only. Reply with just the sentence: Hello world.", "max_tokens": 20])
    precondition(reply["stop_reason"] as? String == "stop")
}

func resident() throws -> Bool {
    try request("memory_status")["cleanup_resident"] as? Bool == true
}

func waitForEviction() throws {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if try !resident() { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    preconditionFailure("Cleanup weights stayed resident")
}

do {
    try generate()
    let loaded = try request("memory_status")["mlx_active_bytes"] as! Int
    let initiallyResident = try resident()
    precondition(loaded > 0 && initiallyResident)
    Thread.sleep(forTimeInterval: 2)
    try generate()
    Thread.sleep(forTimeInterval: 1.3)
    let stillResident = try resident()
    precondition(stillResident, "An old idle timer evicted a new request")
    try waitForEviction()
    let released = try request("memory_status")["mlx_active_bytes"] as! Int
    precondition(released < loaded / 10, "The cache flag cleared but the weights remain allocated")
    for _ in 0..<5 { _ = try request("llm_warm", ["background": true, "load_only": true]) }
    _ = try request("llm_trim")
    try waitForEviction()
    _ = try request("llm_warm", ["load_only": true])
    try generate()
    _ = try request("llm_trim")
    try waitForEviction()
    _ = try request("memory_policy", ["cleanup_idle_seconds": 0])
    _ = try request("llm_warm", ["load_only": true])
    Thread.sleep(forTimeInterval: 4)
    let responsiveResident = try resident()
    precondition(responsiveResident, "Responsive mode still evicts on the idle timer")
    _ = try request("memory_policy", ["cleanup_idle_seconds": 1])
    try waitForEviction()
    let recording = UUID().uuidString, nextRecording = UUID().uuidString
    _ = try request("llm_warm", ["load_only": true, "recording_token": recording])
    Thread.sleep(forTimeInterval: 2)
    let recordingResident = try resident()
    precondition(recordingResident, "A long recording lost its prewarm to the idle timer")
    try generate() // The reservation covers STT/cleanup processing too.
    _ = try request("llm_warm", ["load_only": true, "recording_token": nextRecording])
    _ = try request("llm_release_warm", ["recording_token": recording])
    _ = try request("llm_release_warm", ["recording_token": recording])
    Thread.sleep(forTimeInterval: 2)
    let nextRecordingResident = try resident()
    precondition(nextRecordingResident, "An old release cleared a new recording reservation")
    _ = try request("llm_trim")
    try waitForEviction() // Pressure may evict even while recording.
    _ = try request("llm_release_warm", ["recording_token": nextRecording])
    _ = try request("llm_warm", ["load_only": true, "recording_token": recording])
    _ = try request("llm_release_warm", ["recording_token": recording])
    try waitForEviction() // Idle release resumes after the last recording ends.
    print("Cleanup idle reset, deferred trim, coalesced load and reload passed; MLX active bytes \(loaded) -> \(released)")
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    output.fileHandleForReading.readabilityHandler = nil
    precondition(process.terminationStatus == 0)
} catch {
    process.terminate()
    process.waitUntilExit()
    throw error
}
