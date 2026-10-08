import XCTest
@testable import OLIV

final class OLIVAPIClientTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var state: OLIVAPIRequestState!

    override func setUpWithError() throws {
        suite = "oliv.api.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        state = OLIVAPIRequestState(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        APIFixtureProtocol.reset()
    }

    private func configuration() throws -> OLIVAPIConfiguration {
        try OLIVAPIConfiguration(url: "https://api.example.test", apiKey: "test-key-never-real")
    }

    private func client(_ transport: OLIVAPITransport, now: @escaping () -> Date = Date.init) throws -> OLIVAPIClient {
        OLIVAPIClient(configuration: try configuration(), transport: transport, state: state, now: now)
    }

    func testURLPolicyAndCredentialValidation() throws {
        for url in ["https://oliv.redcomp.tech", "https://example.test/prefix/", "http://localhost:8083",
                    "https://ทดสอบ.example", "https://example.test.", "https://[2001:db8::1]",
                    "http://127.0.0.1:1234", "http://[::1]:8083", "http://[0:0:0:0:0:0:0:1]:8083",
                    "http://192.168.1.2", "http://100.71.1.2"] {
            XCTAssertNoThrow(try OLIVAPIConfiguration(url: url, apiKey: "test"), url)
        }
        for url in ["http://example.test", "http://8.8.8.8", "http://private.local", "http://[2001:db8::1]",
                    "https://user:secret@example.test", "https://example.test?token=secret", "https://example.test/#secret",
                    "https://example.test\\evil", "https:example.test", "https://example.test:0", "https://example.test:70000",
                    "https://bad_host.test", "https://bad..test", "https://-bad.test", "https://bad-.test",
                    "https://%20.test", "https://[gg::1]", "https://" + String(repeating: "x", count: 64) + ".test",
                    "https://example.test\n", "file:///tmp/oliv"] {
            XCTAssertThrowsError(try OLIVAPIConfiguration(url: url, apiKey: "test"), url)
        }
        for key in ["", "a b", "a\nb", "คีย์"] {
            XCTAssertThrowsError(try OLIVAPIConfiguration(url: OLIVAPIConfiguration.defaultURL, apiKey: key))
        }
        for timeout in [9.0, 181, 10.5, Double.nan] {
            XCTAssertThrowsError(try OLIVAPIConfiguration(url: OLIVAPIConfiguration.defaultURL, apiKey: "test", timeout: timeout))
        }
        let cfg = try configuration()
        XCTAssertFalse(String(reflecting: cfg).contains(cfg.apiKey))
        let prefix = try OLIVAPIConfiguration(url: "https://example.test/api%2Fv1/@proxy/", apiKey: "test")
        XCTAssertEqual(prefix.baseURL.absoluteString, "https://example.test/api%2Fv1/@proxy")
        XCTAssertEqual(prefix.baseURL.appendingPathComponent("v1/dictate").absoluteString,
                       "https://example.test/api%2Fv1/@proxy/v1/dictate")
    }

    func testWAVHeaderAndQuantization() throws {
        let wav = try OLIVAPIClient.encodeWAV([0, 0.5, -0.5, 1, -1, 2, -2, .nan, .infinity])
        XCTAssertEqual(wav.count, 44 + 18)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<16], encoding: .ascii), "WAVEfmt ")
        XCTAssertEqual(little(wav, 4, 4), UInt32(wav.count - 8))
        XCTAssertEqual(little(wav, 20, 2), 1, "PCM, not IEEE float")
        XCTAssertEqual(little(wav, 22, 2), 1)
        XCTAssertEqual(little(wav, 24, 4), 16000)
        XCTAssertEqual(little(wav, 28, 4), 32000)
        XCTAssertEqual(little(wav, 32, 2), 2)
        XCTAssertEqual(little(wav, 34, 2), 16)
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(little(wav, 40, 4), 18)
        let samples = stride(from: 44, to: wav.count, by: 2).map { Int16(bitPattern: UInt16(little(wav, $0, 2))) }
        XCTAssertEqual(samples, [0, 16384, -16384, 32767, -32768, 32767, -32768, 0, 0])
    }

    func testAudioBoundariesAndRequestBudget() throws {
        XCTAssertThrowsError(try OLIVAPIClient.encodeWAV([]))
        XCTAssertThrowsError(try OLIVAPIClient.encodeWAV(Array(repeating: 0, count: OLIVAPIClient.maxSamples + 1)))
        let longest = try OLIVAPIClient.requestBody(samples: Array(repeating: 0, count: OLIVAPIClient.maxSamples),
                                                   options: DictationOptions(cleanup: false))
        XCTAssertLessThan(longest.count, OLIVAPIClient.maxRequestBytes)
        XCTAssertThrowsError(try OLIVAPIClient.requestBody(samples: [0], options: DictationOptions(
            cleanup: true, replacements: ["a": String(repeating: "b", count: OLIVAPIClient.maxRequestBytes)])))
    }

    func testRequestIncludesFalseAndPreservesUnicodeWithoutSidecarFields() throws {
        let data = try OLIVAPIClient.requestBody(samples: [0.25], options: DictationOptions(
            cleanup: false, removeFillers: false, replacements: ["อีเมล": "me@example.test"],
            vocabulary: ["OLIV", "ปัณณวิชญ์"], formatCommands: true, thaiFormat: true))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["cleanup"] as? Bool, false)
        XCTAssertEqual(body["remove_fillers"] as? Bool, false)
        XCTAssertEqual(body["thai_format"] as? Bool, false, "effective cleanup gates Thai formatting")
        XCTAssertEqual(body["vocabulary"] as? [String], ["OLIV", "ปัณณวิชญ์"])
        XCTAssertEqual(body["replacements"] as? [String: String], ["อีเมล": "me@example.test"])
        XCTAssertEqual(Set(body.keys), ["wav_b64", "cleanup", "remove_fillers", "thai_format", "vocabulary", "replacements"])
        let wav = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["wav_b64"] as? String)))
        XCTAssertEqual(wav, try OLIVAPIClient.encodeWAV([0.25]))
        let first = try OLIVAPIClient.requestBody(samples: [0], options: DictationOptions(cleanup: true, replacements: ["bb": "1", "aa": "2"]))
        let second = try OLIVAPIClient.requestBody(samples: [0], options: DictationOptions(cleanup: true, replacements: ["aa": "2", "bb": "1"]))
        XCTAssertEqual(first, second, "stable replacement tie order")
    }

    func testReplyFallbackAndNoSpeech() throws {
        let result = try OLIVAPIClient.parseReply(status: 200, data: Data("""
        {"ok":true,"raw":"ดิเพลอย","final":"deploy","t_stt":0.5,"t_cleanup":0.1,
         "cleanup_error":"private server detail","stt_redecoded":true,"thai_format_fired":2}
        """.utf8))
        XCTAssertEqual(result.textToPaste, "deploy")
        XCTAssertEqual(result.engineID, OLIVAPIClient.engineID)
        XCTAssertNotNil(result.cleanupError)
        XCTAssertTrue(result.sttRedecoded)
        XCTAssertEqual(result.thaiFormatFired, 2)
        for json in ["{\"ok\":true,\"no_speech\":true}", "{\"ok\":true,\"final\":\"ghost\",\"no_speech\":true}"] {
            XCTAssertEqual(try OLIVAPIClient.parseReply(status: 200, data: Data(json.utf8)).textToPaste, "")
        }
        XCTAssertEqual(try OLIVAPIClient.parseReply(status: 200, data: Data("{\"ok\":true,\"final\":\"\"}".utf8)).textToPaste, "")
    }

    func testMalformedAndErrorRepliesNeverExposeServerDetails() {
        for json in ["{\"ok\":true}", "{\"ok\":false,\"error\":\"private secret\"}", "<html>secret</html>",
                     "{\"ok\":1,\"final\":\"text\"}", "{\"ok\":true,\"final\":null,\"no_speech\":true}",
                     "{\"ok\":true,\"final\":12}", "{\"ok\":true,\"final\":\"text\",\"t_stt\":-1}"] {
            XCTAssertThrowsError(try OLIVAPIClient.parseReply(status: 200, data: Data(json.utf8))) {
                XCTAssertFalse($0.localizedDescription.contains("secret"))
            }
        }
        for status in [301, 302, 303, 307, 308, 400, 401, 403, 413, 415, 429, 502, 503, 504] {
            XCTAssertThrowsError(try OLIVAPIClient.parseReply(status: status, data: Data("private secret".utf8))) {
                XCTAssertFalse($0.localizedDescription.contains("secret"))
            }
        }
    }

    func testRetryAfterSecondsDatesAndFallback() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(OLIVAPIClient.retryAfter("12", now: now), 12)
        XCTAssertEqual(OLIVAPIClient.retryAfter("0", now: now), 1)
        XCTAssertEqual(OLIVAPIClient.retryAfter(nil, now: now), 60)
        XCTAssertEqual(OLIVAPIClient.retryAfter("garbage", now: now), 60)
        XCTAssertEqual(OLIVAPIClient.retryAfter("Tue, 14 Nov 2023 22:14:20 GMT", now: now), 60)
        XCTAssertEqual(OLIVAPIClient.retryAfter("Tue, 14 Nov 2023 22:12:20 GMT", now: now), 1)
    }

    func testCooldownPersistsAndPreventsAnyAutomaticResend() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = FixtureTransport(status: 429, headers: ["Retry-After": "90"], data: Data())
        let api = try client(transport, now: { now })
        do { _ = try await api.dictate(samples: [0], options: DictationOptions(cleanup: true)); XCTFail() }
        catch { XCTAssertTrue(error is OLIVAPIError) }
        XCTAssertEqual(transport.requests.count, 1)
        do { _ = try await api.dictate(samples: [0], options: DictationOptions(cleanup: true)); XCTFail() }
        catch OLIVAPIError.cooldown(let seconds) { XCTAssertEqual(seconds, 90) }
        XCTAssertEqual(transport.requests.count, 1)
        let reloaded = OLIVAPIRequestState(defaults: defaults)
        XCTAssertThrowsError(try reloaded.begin(now: now))
        XCTAssertNoThrow(try reloaded.begin(now: now.addingTimeInterval(91)))
        reloaded.end()
        XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("oliv.api.") }),
                       [OLIVAPIRequestState.deadlineKey], "only the cooldown deadline is persisted")
    }

    func testServiceUnavailableHeaderAlsoSetsCooldownAndFailureUnlocksState() async throws {
        let transport = FixtureTransport(status: 503, headers: ["Retry-After": "30"], data: Data())
        let api = try client(transport)
        do { _ = try await api.dictate(samples: [0], options: DictationOptions(cleanup: true)); XCTFail() }
        catch { XCTAssertTrue(error is OLIVAPIError) }
        XCTAssertNotNil(defaults.object(forKey: OLIVAPIRequestState.deadlineKey))
        XCTAssertNoThrow(try state.begin(now: .distantFuture), "request lock was released after failure")
        state.end()
    }

    func testSingleInferenceAndHealthHeaders() async throws {
        try state.begin(now: Date())
        let transport = FixtureTransport(status: 200, data: Data("{\"ok\":true,\"final\":\"hello\"}".utf8))
        let api = try client(transport)
        do { _ = try await api.dictate(samples: [0], options: DictationOptions(cleanup: false)); XCTFail() }
        catch OLIVAPIError.busy {}
        XCTAssertTrue(transport.requests.isEmpty)
        state.end()
        let result = try await api.dictate(samples: [0], options: DictationOptions(cleanup: false))
        XCTAssertEqual(result.final, "hello")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/dictate")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-never-real")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("oliv-macos/") == true)
        let health = FixtureTransport(status: 200, data: Data("{\"ok\":true}".utf8))
        try await client(health).health()
        XCTAssertEqual(health.requests.first?.url?.path, "/health")
        XCTAssertNil(health.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(health.requests.first?.httpBody)
    }

    func testURLSessionTransportRoundTripAndBoundedResponse() async throws {
        APIFixtureProtocol.fixture = .init(status: 200, data: Data("{\"ok\":true,\"final\":\"ไทย English\"}".utf8))
        let transport = OLIVAPIURLSessionTransport(protocolClasses: [APIFixtureProtocol.self])
        let result = try await client(transport).dictate(samples: [0.1], options: DictationOptions(cleanup: true))
        XCTAssertEqual(result.textToPaste, "ไทย English")
        XCTAssertEqual(APIFixtureProtocol.requests.count, 1)
        APIFixtureProtocol.fixture = .init(status: 200, data: Data(repeating: 65, count: 100))
        do {
            _ = try await transport.send(URLRequest(url: configuration().baseURL), timeout: 1, limit: 20)
            XCTFail("oversized streamed body accepted")
        } catch OLIVAPIError.responseTooLarge {}
    }

    func testURLSessionTotalDeadlineAndCancellation() async throws {
        APIFixtureProtocol.fixture = .init(status: 200, data: Data(), hang: true)
        let transport = OLIVAPIURLSessionTransport(protocolClasses: [APIFixtureProtocol.self])
        let request = URLRequest(url: try configuration().baseURL)
        do { _ = try await transport.send(request, timeout: 0.05, limit: 20); XCTFail("deadline ignored") }
        catch OLIVAPIError.timeout {}
        let task = Task { try await transport.send(request, timeout: 10, limit: 20) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation ignored") }
        catch OLIVAPIError.cancelled {}
    }

    private func little(_ data: Data, _ offset: Int, _ count: Int) -> UInt32 {
        (0..<count).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
}

private final class FixtureTransport: OLIVAPITransport {
    let status: Int
    let headers: [String: String]
    let data: Data
    private(set) var requests: [URLRequest] = []
    init(status: Int, headers: [String: String] = [:], data: Data) {
        self.status = status; self.headers = headers; self.data = data
    }
    func send(_ request: URLRequest, timeout: TimeInterval, limit: Int) async throws -> OLIVAPIHTTPReply {
        requests.append(request)
        return OLIVAPIHTTPReply(response: HTTPURLResponse(url: request.url!, statusCode: status,
                                                        httpVersion: "HTTP/1.1", headerFields: headers)!, data: data)
    }
}

private final class APIFixtureProtocol: URLProtocol {
    struct Fixture {
        let status: Int
        let data: Data
        var hang = false
    }
    static var fixture = Fixture(status: 200, data: Data())
    static var requests: [URLRequest] = []
    private static let lock = NSLock()
    static func reset() { lock.lock(); requests = []; fixture = .init(status: 200, data: Data()); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let fixture = Self.fixture
        Self.lock.unlock()
        if fixture.hang { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
