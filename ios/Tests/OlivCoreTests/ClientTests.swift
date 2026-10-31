import Foundation
import XCTest
@testable import OlivCore

final class ClientTests: XCTestCase, @unchecked Sendable {
    func testHTTPSAndExplicitPrivateHTTPConfiguration() throws {
        for host in ["127.0.0.1", "localhost", "10.1.2.3", "192.168.1.2", "172.16.2.2", "172.31.2.2", "100.64.0.10", "oliv.local", "[::1]", "[fd12::1]"] {
            XCTAssertNoThrow(try OlivConfiguration(baseURL: URL(string: "http://\(host):8083")!, token: "test", allowsInsecureHTTP: true), host)
            XCTAssertThrowsError(try OlivConfiguration(baseURL: URL(string: "http://\(host):8083")!, token: "test"), host)
        }
        for address in ["http://example.com", "http://8.8.8.8", "http://172.32.0.1", "http://100.128.0.1", "ftp://127.0.0.1", "https://user:password@example.com", "https://example.com?token=oops", "https://example.com/#x"] {
            XCTAssertThrowsError(try OlivConfiguration(baseURL: URL(string: address)!, token: "test", allowsInsecureHTTP: true), address)
        }
        for token in ["", "with space", "new\nline", "ไทย", "tab\there"] {
            XCTAssertThrowsError(try OlivConfiguration(baseURL: URL(string: "https://example.com")!, token: token))
        }
        XCTAssertNoThrow(try OlivConfiguration(baseURL: URL(string: "https://example.com/oliv/")!, token: "test"))
    }

    func testRequestPreservesOrderedReplacementMapAndStringEscaping() throws {
        let options = OlivOptions(vocabulary: ["Grafana", "คูเบอร์"], replacements: [
            ReplacementRule(spoken: "ซี", written: "C"),
            ReplacementRule(spoken: "เอ", written: "A"),
            ReplacementRule(spoken: "quote\"\n", written: "slash\\")
        ])
        let body = try RequestBody.encode(audio: Data([1, 2, 3]), text: nil, options: options)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["wav_b64"] as? String, "AQID")
        XCTAssertEqual(object["cleanup"] as? Bool, true)
        XCTAssertEqual(object["remove_fillers"] as? Bool, true)
        XCTAssertEqual(object["thai_format"] as? Bool, true)
        XCTAssertEqual(object["vocabulary"] as? [String], ["Grafana", "คูเบอร์"])
        XCTAssertNil(object["prompt"])
        let replacements = try XCTUnwrap(object["replacements"] as? [String: String])
        XCTAssertEqual(replacements["quote\"\n"], "slash\\")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(try XCTUnwrap(text.range(of: "\"ซี\"" )).lowerBound < XCTUnwrap(text.range(of: "\"เอ\"" )).lowerBound)
    }

    func testDuplicateAndBlankReplacementSourcesFailBeforeNetworking() {
        XCTAssertThrowsError(try OlivOptions(replacements: [ReplacementRule(spoken: " ", written: "x")]).validate())
        XCTAssertThrowsError(try OlivOptions(replacements: [ReplacementRule(spoken: "a", written: "b"), ReplacementRule(spoken: "a", written: "c")]).validate())
        XCTAssertNoThrow(try OlivOptions(replacements: [ReplacementRule(spoken: "remove", written: "")]).validate())
    }

    func testDictationRequestAndTraceResponseMatchServer() async throws {
        let capture = RequestCapture()
        let (client, session) = try makeClient { request in
            capture.set(request)
            return .response(200, Data(#"{"ok":true,"raw":"กราฟาน่า","final":"Grafana","no_speech":false,"stt_redecoded":true,"t_stt":0.6,"t_cleanup":0.2,"llm_ran":true,"gate_reason":"code-switch","guardrail_flag":"accepted","dict_hits":2,"vocab_fired":1,"fillers_removed":3,"replacements_fired":4,"thai_format_fired":5,"cleanup_error":null}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let wav = try WAVEncoder.encode(samples: .init(repeating: 0, count: 1_600))
        let reply = try await client.dictate(wav: wav)
        XCTAssertEqual(reply.finalText, "Grafana")
        XCTAssertTrue(reply.hasText)
        XCTAssertTrue(reply.sttRedecoded)
        XCTAssertEqual(reply.dictionaryHits, 2)
        XCTAssertEqual(reply.vocabularyCorrections, 1)
        XCTAssertEqual(reply.fillersRemoved, 3)
        XCTAssertEqual(reply.replacementsFired, 4)
        XCTAssertEqual(reply.thaiFormatFired, 5)
        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.url?.path, "/proxy/v1/dictate")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.timeoutInterval, 120)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "oliv-ios/0.1.0")
        let body = try requestBody(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["wav_b64"] as? String)), wav)
    }

    func testCleanupFallbackIsAUsableSuccessAndNoSpeechIsNotText() async throws {
        let (client, session) = try makeClient { _ in
            .response(200, Data(#"{"ok":true,"raw":"hello","final":"Hello","cleanup_error":"timeout","guardrail_flag":"llmError->dict"}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let reply = try await client.clean(text: "hello")
        XCTAssertEqual(reply.cleanupError, "timeout")
        XCTAssertTrue(reply.hasText)
        XCTAssertFalse(DictationReply(finalText: " ").hasText)
        XCTAssertFalse(DictationReply(finalText: "unexpected", noSpeech: true).hasText)
    }

    func testDictationNormalizesRecorderChunksOnlyInTheOutgoingBody() async throws {
        let capture = RequestCapture()
        let (client, session) = try makeClient { request in
            capture.set(request)
            return .response(200, Data(#"{"ok":true,"final":"Hello"}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let samples: [Int16] = [.min, -1, 0, 1, .max]
        let recorderWAV = try RecorderWAVFixture.make(samples: samples)
        let untouched = recorderWAV
        _ = try await client.dictate(wav: recorderWAV)
        let body = try requestBody(XCTUnwrap(capture.get()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let uploaded = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["wav_b64"] as? String)))
        XCTAssertEqual(uploaded, try WAVEncoder.encode(samples: samples))
        XCTAssertEqual(uploaded.count, 44 + samples.count * 2)
        XCTAssertEqual(uploaded.dropFirst(44), recorderWAV.suffix(samples.count * 2))
        XCTAssertEqual(try WAVMetadata(data: uploaded), try WAVMetadata(data: recorderWAV))
        XCTAssertEqual(recorderWAV, untouched)
        XCTAssertEqual(recorderWAV.count - uploaded.count, 4_052)
    }

    func testMalformedRecorderAudioFailsBeforeNetworking() async throws {
        let requests = RequestCounter()
        let (client, session) = try makeClient { _ in
            requests.increment()
            return .response(200, Data(#"{"ok":true,"final":"Unexpected"}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let complete = try RecorderWAVFixture.make(samples: [1, 2, 3])
        do {
            _ = try await client.dictate(wav: complete.dropLast())
            XCTFail("Expected invalid audio")
        } catch let error as OlivError {
            guard case .invalidAudio = error else { return XCTFail("Expected invalid audio") }
        }
        XCTAssertEqual(requests.count, 0)
    }

    func testHealthOmitsBearerAndReportsPartialServiceAvailability() async throws {
        let capture = RequestCapture()
        let (client, session) = try makeClient { request in
            capture.set(request)
            return .response(200, Data(#"{"ok":true,"whisper":true,"gemma":false,"version":"1.0","prompt":"v5","llm_timeout":5}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let health = try await client.health()
        XCTAssertFalse(health.ready)
        XCTAssertEqual(health.whisper, true)
        XCTAssertNil(capture.get()?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(capture.get()?.url?.path, "/proxy/health")
        XCTAssertEqual(capture.get()?.httpMethod, "GET")
    }

    func testVerifyKeySendsTheBearerToTheDictionaryRoute() async throws {
        let capture = RequestCapture()
        let (client, session) = try makeClient { request in
            capture.set(request)
            return .response(200, Data(#"{"ok":true,"revision":0,"max_entries":1000,"rejected":[],"entries":[]}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        try await client.verifyKey()
        XCTAssertEqual(capture.get()?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(capture.get()?.url?.path, "/proxy/v1/dictionary")
        XCTAssertEqual(capture.get()?.httpMethod, "GET")
    }

    func testVerifyKeyReportsARejectedKey() async throws {
        let (client, session) = try makeClient { _ in .response(401, Data()) }
        defer { session.invalidateAndCancel() }
        do { try await client.verifyKey(); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? OlivError, .unauthorized) }
    }

    func testTrialRequestReturnsAValidatedKeyWithoutAnyCredential() async throws {
        let capture = RequestCapture()
        let (url, session) = makeTrialServer { request in
            capture.set(request)
            return .response(200, Data(#"{"ok":true,"token":"oliv_0123_abcd","expires_at":1800000000,"daily_requests":60}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let key = try await TrialClient.requestKey(baseURL: url, session: session)
        XCTAssertEqual(key, TrialKey(token: "oliv_0123_abcd", expiresAt: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertNil(capture.get()?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(capture.get()?.url?.path, "/try/key")
        XCTAssertEqual(capture.get()?.httpMethod, "POST")
    }

    func testTrialRefusalsAndMalformedRepliesAreDistinct() async throws {
        let cases: [(Int, String, any Error)] = [
            (429, #"{"ok":false,"error":"daily_limit"}"#, TrialRefusal.limitReached),
            (503, #"{"ok":false,"error":"closed"}"#, TrialRefusal.closed),
            (404, "", TrialRefusal.closed),
            (200, #"{"ok":true,"token":"has space","expires_at":1}"#, OlivError.invalidResponse),
            (200, #"{"ok":false}"#, OlivError.invalidResponse)
        ]
        for (status, body, expected) in cases {
            let (url, session) = makeTrialServer { _ in .response(status, Data(body.utf8)) }
            defer { session.invalidateAndCancel() }
            do {
                _ = try await TrialClient.requestKey(baseURL: url, session: session)
                XCTFail("Expected refusal for \(status) \(body)")
            } catch {
                XCTAssertEqual(String(describing: error), String(describing: expected))
            }
        }
    }

    func testHTTPErrorsAndMalformedRepliesAreSafe() async throws {
        let cases: [(Int, String, OlivError)] = [
            (401, "private token secret", .unauthorized),
            (403, "private token secret", .forbidden(reason: .unknown)),
            (502, #"{"ok":false,"error":"private transcript","code":"inference_failed"}"#, .serviceUnavailable(statusCode: 502, retryAfter: nil)),
            (302, "redirect", .server(statusCode: 302)),
            (200, "<html>private transcript</html>", .invalidResponse),
            (200, #"{"ok":false,"error":"private transcript"}"#, .server(statusCode: 200)),
            (200, #"{"raw":"unrelated"}"#, .invalidResponse),
            (200, #"{"ok":true}"#, .invalidResponse),
            (200, #"{"ok":true,"raw":"preserve this audio"}"#, .invalidResponse),
            (200, #"{"ok":true,"raw":null,"final":""}"#, .invalidResponse),
            (200, #"{"ok":true,"raw":"","final":null}"#, .invalidResponse),
            (200, #"{"ok":true,"no_speech":true,"raw":null}"#, .invalidResponse),
            (200, #"{"ok":true,"no_speech":true,"final":null}"#, .invalidResponse),
            (200, #"{"ok":true,"no_speech":null,"final":"x"}"#, .invalidResponse),
            (200, #"{"ok":true,"no_speech":"true"}"#, .invalidResponse),
            (200, #"{"ok":true,"final":123}"#, .invalidResponse)
        ]
        for (status, body, expected) in cases {
            let (client, session) = try makeClient { _ in .response(status, Data(body.utf8)) }
            defer { session.invalidateAndCancel() }
            do { _ = try await client.clean(text: "private transcript"); XCTFail("Expected failure") }
            catch let error as OlivError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("private"))
                XCTAssertFalse(error.localizedDescription.contains("test-token"))
            }
        }
    }

    func testExplicitEmptyNoSpeechSuccessStillDecodesWithOptionalMetadataMissing() throws {
        let data = Data(#"{"ok":true,"raw":"","final":"","no_speech":true}"#.utf8)
        let reply = try JSONDecoder().decode(DictationReply.self, from: data)
        XCTAssertTrue(reply.ok)
        XCTAssertTrue(reply.noSpeech)
        XCTAssertFalse(reply.hasText)
        XCTAssertEqual(reply.tSTT, 0)
        XCTAssertNil(reply.cleanupError)
    }

    func testPublicDefaultsAndMinimalHealthPreserveUnknownReadiness() async throws {
        let capture = RequestCapture()
        let (client, session) = try makeClient { request in
            capture.set(request)
            return .response(200, Data(#"{"ok":true}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let health = try await client.health()
        XCTAssertTrue(health.ok)
        XCTAssertNil(health.whisper)
        XCTAssertNil(health.gemma)
        XCTAssertNil(health.version)
        XCTAssertNil(health.prompt)
        XCTAssertNil(health.llmTimeout)
        XCTAssertFalse(health.ready)
        XCTAssertNil(capture.get()?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(capture.get()?.value(forHTTPHeaderField: "User-Agent"), OlivClient.userAgent)
        XCTAssertEqual(capture.get()?.timeoutInterval, 120)
        let known = try JSONDecoder().decode(ServerHealth.self, from: Data(#"{"ok":true,"whisper":true,"gemma":true}"#.utf8))
        XCTAssertTrue(known.ready)
        let unavailable = try JSONDecoder().decode(ServerHealth.self, from: Data(#"{"ok":true,"whisper":false}"#.utf8))
        XCTAssertEqual(unavailable.whisper, false)
        XCTAssertNil(unavailable.gemma)
        XCTAssertThrowsError(try JSONDecoder().decode(ServerHealth.self, from: Data(#"{"whisper":true}"#.utf8)))
    }

    func testPublicDictationAllowsMissingRawAndExplicitMinimalNoSpeech() throws {
        let text = try JSONDecoder().decode(DictationReply.self, from: Data(#"{"ok":true,"final":"สวัสดี"}"#.utf8))
        XCTAssertEqual(text.raw, "")
        XCTAssertTrue(text.hasText)
        let empty = try JSONDecoder().decode(DictationReply.self, from: Data(#"{"ok":true,"no_speech":true}"#.utf8))
        XCTAssertTrue(empty.noSpeech)
        XCTAssertEqual(empty.raw, "")
        XCTAssertEqual(empty.finalText, "")
        XCTAssertFalse(empty.hasText)
    }

    func testForbiddenScopeAndEdgeErrorsExposeOnlySafeCategories() async throws {
        let cases: [(String, OlivForbiddenReason)] = [
            (#"{"error":"API key does not allow this operation","private":"test-token"}"#, .missingScope),
            ("error code: 1010; private secret test-token", .edgePolicy),
            ("<html>Cloudflare denied private secret test-token</html>", .edgePolicy),
            (#"{"error":"private secret test-token"}"#, .unknown)
        ]
        for (body, reason) in cases {
            let (client, session) = try makeClient { _ in .response(403, Data(body.utf8)) }
            defer { session.invalidateAndCancel() }
            do { _ = try await client.clean(text: "private secret"); XCTFail("Expected refusal") }
            catch let error as OlivError {
                XCTAssertEqual(error, .forbidden(reason: reason))
                XCTAssertFalse(error.localizedDescription.contains("private secret"))
                XCTAssertFalse(error.localizedDescription.contains("test-token"))
                XCTAssertNil(error.retryAfter)
            }
        }
    }

    func testRetryAfterParsesSecondsAndHTTPDatesConservatively() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for header in [nil, "", "nonsense", "-1", "1.5", "+2"] {
            XCTAssertEqual(OlivClient.retryDate(header: header, now: now), now.addingTimeInterval(60))
        }
        XCTAssertEqual(OlivClient.retryDate(header: "0", now: now), now.addingTimeInterval(1))
        XCTAssertEqual(OlivClient.retryDate(header: " 123 ", now: now), now.addingTimeInterval(123))
        for header in ["Wed, 18 May 2033 03:35:37 GMT", "Wednesday, 18-May-33 03:35:37 GMT", "Wed May 18 03:35:37 2033"] {
            XCTAssertEqual(OlivClient.retryDate(header: header, now: now), now.addingTimeInterval(137), header)
        }
        XCTAssertEqual(OlivClient.retryDate(header: "Wed, 18 May 2033 03:33:19 GMT", now: now), now.addingTimeInterval(1))
    }

    func testRateLimitsAndServerCooldownHeadersAreReturnedWithoutAutomaticRetry() async throws {
        for (status, header, delay) in [(429, "17", 17.0), (429, "invalid", 60.0), (429, "0", 1.0), (503, "23", 23.0)] {
            let requests = RequestCounter()
            let (client, session) = try makeClient { _ in
                requests.increment()
                return .response(status, Data("private body".utf8), headers: ["Retry-After": header])
            }
            defer { session.invalidateAndCancel() }
            let before = Date()
            do { _ = try await client.clean(text: "test"); XCTFail("Expected cooldown") }
            catch let error as OlivError {
                let until = try XCTUnwrap(error.retryAfter)
                XCTAssertGreaterThanOrEqual(until.timeIntervalSince(before), delay)
                XCTAssertLessThan(until.timeIntervalSince(before), delay + 3)
                if status == 429 { XCTAssertEqual(error, .rateLimited(retryAfter: until)) }
                else { XCTAssertEqual(error, .serviceUnavailable(statusCode: status, retryAfter: until)) }
                XCTAssertFalse(error.localizedDescription.contains("private body"))
            }
            XCTAssertEqual(requests.count, 1)
        }
        let (client, session) = try makeClient { _ in
            .response(429, Data(), headers: ["Retry-After": "Wed, 18 May 2033 03:33:20 GMT"])
        }
        defer { session.invalidateAndCancel() }
        do { _ = try await client.clean(text: "test"); XCTFail("Expected cooldown") }
        catch let error as OlivError { XCTAssertEqual(error.retryAfter, Date(timeIntervalSince1970: 2_000_000_000)) }
    }

    func testTransportErrorsAndCancellation() async throws {
        for (code, expected) in [(URLError.Code.timedOut, OlivError.timedOut), (.notConnectedToInternet, .networkUnavailable), (.secureConnectionFailed, .transport)] {
            let (client, session) = try makeClient { _ in .failure(URLError(code)) }
            defer { session.invalidateAndCancel() }
            do { _ = try await client.clean(text: "x"); XCTFail("Expected error") }
            catch let error as OlivError { XCTAssertEqual(error, expected) }
        }
        let (client, session) = try makeClient { _ in .failure(URLError(.cancelled)) }
        defer { session.invalidateAndCancel() }
        do { _ = try await client.clean(text: "x"); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellationStopsAnInFlightRequest() async throws {
        let started = expectation(description: "Request started")
        let (client, session) = try makeClient { _ in
            started.fulfill()
            return .hold
        }
        defer { session.invalidateAndCancel() }
        let task = Task { try await client.clean(text: "cancel me") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testResponseAndRequestLimits() async throws {
        let data = Data(repeating: 120, count: OlivClient.maximumResponseBytes + 1)
        let (client, session) = try makeClient { _ in .response(200, data) }
        defer { session.invalidateAndCancel() }
        do { _ = try await client.clean(text: "x"); XCTFail("Expected oversized response") }
        catch let error as OlivError { XCTAssertEqual(error, .responseTooLarge) }
        // The server's 8,192-byte text limit refuses this long before the
        // 8 MiB transport guard (kept as defense in depth) could.
        do { _ = try await client.clean(text: String(repeating: "x", count: OlivClient.maximumRequestBytes)); XCTFail("Expected oversized request") }
        catch let error as OlivError {
            guard case .invalidOptions = error else { return XCTFail("Expected the cleanup text limit, got \(error)") }
        }
        do { _ = try await client.dictate(wav: WAVEncoder.encode(samples: [0], sampleRate: 44_100)); XCTFail("Expected wrong sample rate") }
        catch let error as OlivError {
            guard case .invalidAudio = error else { return XCTFail("Expected invalid audio") }
        }
    }

    func testDictionarySyncRequestsAndReplies() async throws {
        let snapshot = Data(#"{"ok":true,"revision":2,"max_entries":1000,"rejected":[],"entries":[{"id":"a","word":"SHA256","correction":null,"enabled":true,"starred":true,"source":"manual"}]}"#.utf8)
        let capture = RequestCapture()
        let (client, session) = try makeClient { request in
            capture.set(request)
            return .response(200, snapshot)
        }
        defer { session.invalidateAndCancel() }
        let fetched = try await client.dictionary(ops: nil)
        XCTAssertEqual(fetched.entries.first?.word, "SHA256")
        var request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/proxy/v1/dictionary")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token",
                       "unlike /health, the dictionary is per key")

        _ = try await client.dictionary(ops: [.delete(id: "a"), .upsert(DictionaryEntry(id: "b", word: "Koolify", correction: "คูลิฟาย"))])
        request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: [[String: Any]]])
        XCTAssertEqual(body["ops"]?.first?["op"] as? String, "delete")
        let entry = try XCTUnwrap(body["ops"]?.last?["entry"] as? [String: Any])
        XCTAssertEqual(entry["correction"] as? String, "คูลิฟาย")
        XCTAssertEqual(entry["source"] as? String, "manual")
    }

    func testOlderServersReportDictionaryUnsupported() async throws {
        let (client, session) = try makeClient { _ in .response(404, Data(#"{"ok":false,"code":"not_found"}"#.utf8)) }
        defer { session.invalidateAndCancel() }
        do { _ = try await client.dictionary(ops: nil); XCTFail("Expected unsupported") }
        catch let error as OlivError { XCTAssertEqual(error, .dictionaryUnsupported) }
    }

    func testDictationReplyCarriesTheDictionaryRevision() throws {
        let reply = try JSONDecoder().decode(DictationReply.self, from: Data(#"{"ok":true,"final":"x","dictionary_revision":7}"#.utf8))
        XCTAssertEqual(reply.dictionaryRevision, 7)
        XCTAssertNil(try JSONDecoder().decode(DictationReply.self, from: Data(#"{"ok":true,"final":"x"}"#.utf8)).dictionaryRevision)
    }

    func testOnlyAWholeForeignErrorBodyProvesARequestNeverArrived() {
        let page = Data("<html>Bad gateway</html>".utf8)
        let own = Data(#"{"ok":false,"error":"failed","code":"inference_failed"}"#.utf8)
        XCTAssertTrue(OlivClient.neverReachedOlivAPI(body: page, complete: true))
        XCTAssertFalse(OlivClient.neverReachedOlivAPI(body: own, complete: true))
        XCTAssertFalse(OlivClient.neverReachedOlivAPI(body: Data(#"{"ok":false,"err"#.utf8), complete: false),
                       "the lost part may be oliv-api's error, after it charged for the request")
    }

    func testUnreachedRequestsAreRetriedOnceAndProcessedOnesNever() async throws {
        let attempts = RequestCounter()
        let (client, session) = try makeClient { _ in
            attempts.increment()
            return attempts.count == 1
                ? .response(502, Data("<html>Bad gateway</html>".utf8), headers: ["Content-Type": "text/html"])
                : .response(200, Data(#"{"ok":true,"revision":1,"entries":[]}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let snapshot = try await client.dictionary(ops: nil)
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(attempts.count, 2, "safe to repeat, whoever answered")

        // A proxy may have passed this on before it lost the origin.
        let paid = RequestCounter()
        let (spends, session4) = try makeClient { _ in
            paid.increment()
            return .response(502, Data("<html>Bad gateway</html>".utf8), headers: ["Content-Type": "text/html"])
        }
        defer { session4.invalidateAndCancel() }
        do { _ = try await spends.clean(text: "x"); XCTFail("Expected failure") }
        catch let error as OlivError { XCTAssertEqual(error, .serviceUnavailable(statusCode: 502, retryAfter: nil)) }
        XCTAssertEqual(paid.count, 1, "quota is never spent twice on a guess")

        let processed = RequestCounter()
        let (again, session2) = try makeClient { _ in
            processed.increment()
            return .response(502, Data(#"{"ok":false,"error":"speech recognition failed","code":"inference_failed"}"#.utf8))
        }
        defer { session2.invalidateAndCancel() }
        do { _ = try await again.clean(text: "x"); XCTFail("Expected failure") }
        catch let error as OlivError { XCTAssertEqual(error, .serviceUnavailable(statusCode: 502, retryAfter: nil)) }
        XCTAssertEqual(processed.count, 1, "an oliv-api error means the request was processed")

        let refused = RequestCounter()
        let (third, session3) = try makeClient { _ in
            refused.increment()
            return .failure(URLError(.cannotConnectToHost))
        }
        defer { session3.invalidateAndCancel() }
        do { _ = try await third.clean(text: "x"); XCTFail("Expected failure") }
        catch let error as OlivError { XCTAssertEqual(error, .networkUnavailable) }
        XCTAssertEqual(refused.count, 2)
    }

    private func makeClient(_ handler: @escaping @Sendable (URLRequest) -> StubURLProtocol.Result) throws -> (OlivClient, URLSession) {
        let host = UUID().uuidString.lowercased() + ".example.test"
        StubURLProtocol.registry.set(host, handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return (OlivClient(configuration: try OlivConfiguration(baseURL: URL(string: "https://\(host)/proxy/")!, token: "test-token"), session: session), session)
    }

    private func makeTrialServer(_ handler: @escaping @Sendable (URLRequest) -> StubURLProtocol.Result) -> (URL, URLSession) {
        let host = UUID().uuidString.lowercased() + ".example.test"
        StubURLProtocol.registry.set(host, handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return (URL(string: "https://\(host)")!, URLSession(configuration: config))
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    func testCleanupOverTheServerTextLimitIsRefusedBeforeSending() async throws {
        let counter = RequestCounter()
        let (client, session) = try makeClient { _ in
            counter.increment()
            return .response(200, Data(#"{"ok":true,"raw":"x","final":"x","no_speech":false}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let atLimit = String(repeating: "a", count: OlivOptions.maximumCleanupTextBytes)
        _ = try await client.clean(text: atLimit)
        XCTAssertEqual(counter.count, 1)
        // Thai is three UTF-8 bytes per scalar: 2,731 characters exceed 8,192 bytes.
        let over = String(repeating: "ก", count: 2_731)
        do { _ = try await client.clean(text: over); XCTFail("Expected a local refusal") }
        catch let error as OlivError {
            guard case .invalidOptions(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("8,192") || message.contains("8192"), message)
        }
        XCTAssertEqual(counter.count, 1, "An over-limit draft must never reach the server")
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ request: URLRequest) { lock.withLock { self.request = request } }
    func get() -> URLRequest? { lock.withLock { request } }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Result: Sendable { case response(Int, Data, headers: [String: String] = [:]), failure(URLError), hold }
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: @Sendable (URLRequest) -> Result] = [:]
        func set(_ host: String, _ handler: @escaping @Sendable (URLRequest) -> Result) { lock.withLock { handlers[host] = handler } }
        func get(_ host: String) -> (@Sendable (URLRequest) -> Result)? { lock.withLock { handlers[host] } }
    }
    static let registry = Registry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".example.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.registry.get(request.url!.host!) else { return }
        switch handler(request) {
        case .hold: break
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let data, let headers):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new })!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
