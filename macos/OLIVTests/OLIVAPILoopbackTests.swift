import XCTest
@testable import OLIV

/// Real sockets exercise the production Rust redirect/TLS behavior that URLProtocol
/// fixtures cannot establish. Synthetic audio and test keys only.
final class OLIVAPILoopbackTests: XCTestCase {
    func testNativeRequestCancellationStopsPromptly() async throws {
        let server = try LoopbackAPIServer()
        defer { server.close() }
        let client = OLIVAPIClient(configuration: try OLIVAPIConfiguration(url: server.url + "/stall", apiKey: "dummy"))
        let operation = Task { try await client.dictate(samples: [0.1], options: DictationOptions(cleanup: false)) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let start = Date()
        operation.cancel()
        do { _ = try await operation.value; XCTFail("cancelled operation succeeded") }
        catch OLIVAPIError.cancelled {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testAllRedirectsStopBeforeSendingKeyOrAudioToDestination() async throws {
        let server = try LoopbackAPIServer()
        defer { server.close() }
        for status in [301, 302, 303, 307, 308] {
            let configuration = try OLIVAPIConfiguration(url: server.url + "/redirect/\(status)", apiKey: "dummy")
            let client = OLIVAPIClient(configuration: configuration)
            do { _ = try await client.dictate(samples: [0.1], options: DictationOptions(cleanup: false)); XCTFail("redirect followed") }
            catch OLIVAPIError.redirect {}
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: server.url + "/counts")!)
        let counts = try JSONSerialization.jsonObject(with: data) as! [String: Int]
        XCTAssertEqual(counts["redirects"], 5)
        XCTAssertEqual(counts["targets"], 0, "neither audio nor Authorization can reach a redirect target")
    }

    func testRealRequestAndUnauthenticatedHealth() async throws {
        let server = try LoopbackAPIServer()
        defer { server.close() }
        let client = OLIVAPIClient(configuration: try OLIVAPIConfiguration(url: server.url, apiKey: "dummy"))
        try await client.health()
        let result = try await client.dictate(samples: [0.25], options: DictationOptions(cleanup: false))
        XCTAssertEqual(result.final, "ไทย English")
        let (data, _) = try await URLSession.shared.data(from: URL(string: server.url + "/counts")!)
        let counts = try JSONSerialization.jsonObject(with: data) as! [String: Int]
        XCTAssertEqual(counts["valid_requests"], 1, "headers, boolean flags and PCM16 WAV validated by server")
        XCTAssertEqual(counts["health_keys"], 0)
    }

    func testUntrustedTLSCertificateIsRejected() async throws {
        let server = try LoopbackAPIServer(tls: true)
        defer { server.close() }
        let client = OLIVAPIClient(configuration: try OLIVAPIConfiguration(url: server.url, apiKey: "dummy"))
        do { try await client.health(); XCTFail("untrusted certificate accepted") }
        catch OLIVAPIError.network {}
    }
}

private final class LoopbackAPIServer {
    private let process = Process()
    let url: String

    init(tls: Bool = false) throws {
        process.executableURL = URL(fileURLWithPath: try NativeTestSupport.executable())
        process.arguments = [tls ? "https" : "http"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var startup = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock(); startup.append(data); lock.unlock()
            if data.contains(10) || data.isEmpty { ready.signal() }
        }
        try process.run()
        let started = ready.wait(timeout: .now() + 5) == .success
        output.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let bytes = startup; lock.unlock()
        guard started, let port = String(data: bytes, encoding: .utf8).flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw NSError(domain: "LoopbackAPIServer", code: 1)
        }
        url = "\(tls ? "https" : "http")://127.0.0.1:\(port)"
    }

    func close() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
}
