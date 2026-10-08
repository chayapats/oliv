import Foundation

// No model, microphone, settings or credentials. Keep stdin open while waiting
// for each reply: EOF-only smoke tests miss buffering regressions in workers.
let directory = CommandLine.arguments.dropFirst().first ?? "build/native-runtime"
for name in ["oliv-sidecar", "oliv-inference"] {
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: directory).appendingPathComponent(name)
    process.standardInput = input; process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let signal = DispatchSemaphore(value: 0), lock = NSLock()
    var buffer = Data(), frames = [Data]()
    output.fileHandleForReading.readabilityHandler = { handle in
        let bytes = handle.availableData
        lock.lock()
        buffer.append(bytes)
        while let end = buffer.firstIndex(of: 10) {
            frames.append(buffer.prefix(upTo: end)); buffer.removeSubrange(...end)
            signal.signal()
        }
        lock.unlock()
    }
    try process.run()
    for id in 1...2 {
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":\(id),\"cmd\":\"ping\"}\n".utf8))
        guard signal.wait(timeout: .now() + 5) == .success else {
            process.terminate(); fatalError("\(name): no reply with stdin open")
        }
        lock.lock(); let frame = frames.removeFirst(); lock.unlock()
        let reply = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
        precondition(reply["id"] as? Int == id && reply["ok"] as? Bool == true)
    }
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    output.fileHandleForReading.readabilityHandler = nil
    precondition(process.terminationStatus == 0)
    print("\(name): persistent IPC and clean EOF passed")
}
