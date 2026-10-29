import Foundation
import Darwin

// Reserve the protocol fd before any library can print to stdout.
private let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
private let outputLock = NSLock()
func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    outputLock.lock(); defer { outputLock.unlock() }
    do { try protocolOutput.write(contentsOf: data + Data([10])) } catch { exit(0) }
}

@main
struct InferenceMain {
    static func main() async {
        _ = protocolOutput
        dup2(STDERR_FILENO, STDOUT_FILENO)
        signal(SIGPIPE, SIG_IGN)
        let parent = getppid()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { if getppid() != parent { _exit(0) } }
        watchdog.resume()
        let runtime = ModelRuntime()
        var buffer = Data()
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                var reply: [String: Any]
                let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                if request["cmd"] as? String == "shutdown" { break }
                do { reply = try await runtime.handle(request) }
                catch {
                    // Never echo model, tokenizer, network or request contents.
                    if ProcessInfo.processInfo.environment["OLIV_INFERENCE_DIAGNOSTICS"] == "1" {
                        FileHandle.standardError.write(Data("Native inference error: \(error)\n".utf8))
                    }
                    reply = ["ok": false, "error": "Native inference failed; check downloaded models"]
                }
                reply["id"] = request["id"] ?? NSNull()
                emit(reply)
            } else {
                // FileHandle.read(upToCount:) can wait for the requested length
                // on a pipe. POSIX read returns the available request immediately.
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
                if buffer.count > 56 * 1024 * 1024 { break }
            }
        }
        watchdog.cancel()
    }
}
