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

/// Live previews up to `through` are cancelled. Set by the stdin reader the
/// moment a `cancel_preview` line arrives, read by the decode loop per token.
final class PreviewCancellation: @unchecked Sendable {
    static let shared = PreviewCancellation()
    private let lock = NSLock()
    private var through = 0
    func cancel(through seq: Int) { lock.lock(); through = max(through, seq); lock.unlock() }
    func isCancelled(_ seq: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return seq <= through }
}

/// One parsed request handed from the stdin reader to the request loop.
private struct Incoming: @unchecked Sendable { let request: [String: Any] }

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
        // Read stdin on its own thread so a `cancel_preview` takes effect while
        // a request (the preview being cancelled) is still running. It gets no
        // reply; every other request keeps its order.
        let (requests, continuation) = AsyncStream.makeStream(of: Incoming.self)
        let reader = Thread {
            var buffer = Data()
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end)
                    buffer.removeSubrange(...end)
                    let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                    if request["cmd"] as? String == "cancel_preview" {
                        if let seq = request["through"] as? Int { PreviewCancellation.shared.cancel(through: seq) }
                        continue
                    }
                    continuation.yield(Incoming(request: request))
                    if request["cmd"] as? String == "shutdown" { break }
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
            continuation.finish()
        }
        reader.start()
        for await incoming in requests {
            let request = incoming.request
            var reply: [String: Any]
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
        }
        watchdog.cancel()
    }
}
