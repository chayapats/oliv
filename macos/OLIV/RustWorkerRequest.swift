import Foundation
import Darwin

/// One cancellable API transaction. Credentials travel only on the private stdin
/// pipe. A failed transaction is never replayed or sent to another provider.
final class RustWorkerRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: Any], Error>?
    private var result: Result<[String: Any], Error>?
    private var process: Process?
    private var deadline: DispatchWorkItem?

    func send(_ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) + Data([10])
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                self.continuation = continuation
                let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(OLIVAPIError.timeout)) }
                self.deadline = deadline
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                DispatchQueue.global(qos: .userInitiated).async { self.run(data) }
            }
        }, onCancel: { self.finish(.failure(OLIVAPIError.cancelled)) })
    }

    private func run(_ data: Data) {
        let launch = SidecarClient.resolveLaunch()
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: launch.command[0])
        child.arguments = Array(launch.command.dropFirst()) + ["--once"]
        var environment = ProcessInfo.processInfo.environment
        launch.environment?.forEach { environment[$0] = $1 }
        child.environment = environment
        child.standardInput = input; child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if result != nil { lock.unlock(); return }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); finish(.failure(OLIVAPIError.network)); return }
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if child.isRunning { kill(child.processIdentifier, SIGTERM) }
            child.waitUntilExit()
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            var bytes = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                guard chunk.count <= 2 * OLIVAPIClient.maxResponseBytes - bytes.count else {
                    finish(.failure(OLIVAPIError.responseTooLarge)); return
                }
                bytes.append(chunk)
                if bytes.contains(10) { break }
            }
            guard let reply = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                finish(.failure(OLIVAPIError.invalidReply)); return
            }
            finish(.success(reply))
        } catch { finish(.failure(OLIVAPIError.network)) }
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, process = self.process, deadline = self.deadline
        self.continuation = nil; self.process = nil; self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        if let process, process.isRunning { kill(process.processIdentifier, SIGTERM) }
        continuation?.resume(with: result)
    }
}
