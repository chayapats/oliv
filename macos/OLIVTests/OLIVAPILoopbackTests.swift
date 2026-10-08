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
    private let directory: URL
    let url: String

    init(tls: Bool = false) throws {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Python is needed for loopback HTTP/TLS tests")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oliv-api-sockets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        if tls {
            let openssl = Process()
            openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                                 "-keyout", directory.appendingPathComponent("key.pem").path,
                                 "-out", directory.appendingPathComponent("cert.pem").path]
            openssl.standardOutput = FileHandle.nullDevice
            openssl.standardError = FileHandle.nullDevice
            try openssl.run(); openssl.waitUntilExit()
            guard openssl.terminationStatus == 0 else { throw XCTSkip("Unable to generate a temporary TLS certificate") }
        }
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", script.path, tls ? directory.path : ""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ready = DispatchSemaphore(value: 0)
        var startup = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            startup.append(data)
            if data.contains(10) || data.isEmpty { ready.signal() }
        }
        try process.run()
        let started = ready.wait(timeout: .now() + 5) == .success
        output.fileHandleForReading.readabilityHandler = nil
        guard started, let port = String(data: startup, encoding: .utf8).flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw NSError(domain: "LoopbackAPIServer", code: 1)
        }
        url = "\(tls ? "https" : "http")://127.0.0.1:\(port)"
    }

    func close() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
import base64, http.server, json, ssl, sys
counts = dict(redirects=0, targets=0, valid_requests=0, health_keys=0)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == '/health':
            counts['health_keys'] += int('Authorization' in self.headers)
            self.reply(200, dict(ok=True))
        elif self.path == '/counts': self.reply(200, counts)
        else: self.reply(404, dict(ok=False))
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/stall/v1/dictate':
            import time
            time.sleep(20)
            return
        if self.path.startswith('/redirect/'):
            counts['redirects'] += 1
            status = int(self.path.split('/')[2])
            self.send_response(status)
            self.send_header('Location', '/target/v1/dictate')
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif self.path == '/target/v1/dictate':
            counts['targets'] += 1
            self.reply(200, dict(ok=True, final='unexpected redirect'))
        elif self.path == '/v1/dictate':
            body = json.loads(raw)
            wav = base64.b64decode(body['wav_b64'])
            assert self.headers.get('Authorization') == 'Bearer dummy'
            assert self.headers.get('User-Agent', '').startswith('oliv-macos/')
            assert self.headers.get('Content-Type') == 'application/json'
            assert body['cleanup'] is False and body['remove_fillers'] is False and body['thai_format'] is False
            assert wav[:4] == b'RIFF' and wav[20:24] == b'\x01\x00\x01\x00'
            assert wav[24:28] == (16000).to_bytes(4, 'little') and wav[34:36] == b'\x10\x00'
            counts['valid_requests'] += 1
            self.reply(200, dict(ok=True, final='ไทย English'))
        else: self.reply(404, dict(ok=False))
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
if sys.argv[1]:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1] + '/cert.pem', sys.argv[1] + '/key.pem')
    server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_address[1], flush=True)
server.serve_forever()
"""#
}
