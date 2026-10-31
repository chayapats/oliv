import Foundation
import XCTest
import UIKit
import AVFoundation
import OlivCore
@testable import Oliv

final class AppModelTests: XCTestCase {
    @MainActor
    func testSuccessfulDictationPersistsResultBeforeRemovingRetryAudio() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertTrue(h.model.isConfigured)
        await h.model.startInForeground()
        XCTAssertEqual(h.model.phase, .recording)
        await h.model.stopFromIntent()

        XCTAssertEqual(h.model.phase, .result)
        XCTAssertEqual(h.model.history.count, 1)
        XCTAssertTrue(h.model.pending.isEmpty)
        let result = try XCTUnwrap(h.model.latest)
        XCTAssertTrue(result.reply.hasText)
        XCTAssertEqual(result.source, .dictation)
        XCTAssertEqual(result.audioDuration, 1, accuracy: 0.001)
        XCTAssertEqual(h.model.latestTextForIntent, result.finalText)
        XCTAssertEqual(try HistoryStore(directory: h.directory).entries().map(\.id), [result.id])
        XCTAssertTrue(try PendingRecordingStore(directory: h.directory.appendingPathComponent("Pending")).recordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.capture.recoveryURL.path))
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testFailureRetainsAudioAndRetryUsesOriginalOptionSnapshot() async throws {
        let h = try Harness(mode: .failOnce)
        defer { h.removeDirectory() }
        // Settle the first Dictionary sync so request options cannot change underneath.
        await h.model.syncDictionary()
        h.model.settings.cleanup = false
        h.model.saveDictionaryEntry(word: "Grafana", correction: nil)
        h.model.saveDictionaryEntry(word: "C", correction: "ซี")
        let original = h.model.currentOptions
        await h.model.startInForeground()
        // Programmatic changes cannot alter an already-started recording.
        h.model.settings.cleanup = true
        h.model.saveDictionaryEntry(word: "Changed after start", correction: nil)
        await h.model.stopFromIntent()

        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertNil(h.model.latestTextForIntent)
        XCTAssertTrue(h.model.history.isEmpty)
        let pending = try XCTUnwrap(h.model.pending.first)
        XCTAssertEqual(pending.options, original)
        XCTAssertEqual(pending.attemptCount, 1)
        XCTAssertNotNil(pending.lastError)
        let store = try PendingRecordingStore(directory: h.directory.appendingPathComponent("Pending"))
        XCTAssertGreaterThan(try store.audio(for: pending.id).count, 44)
        h.model.saveDictionaryEntry(word: "Changed before retry", correction: nil)
        await h.model.retry(pending)

        XCTAssertEqual(h.model.phase, .result)
        XCTAssertTrue(h.model.pending.isEmpty)
        XCTAssertEqual(h.model.latest?.id, pending.id)
        XCTAssertEqual(h.model.latest?.source, .retry)
        let lastOptions = await h.service.lastOptions
        let calls = await h.service.dictateCalls
        XCTAssertEqual(lastOptions, original)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testCancellingUploadRetainsDurableAudioAndRejectsLateResult() async throws {
        let h = try Harness(mode: .slow)
        defer { h.removeDirectory() }
        await h.model.startInForeground()
        let submission = Task { @MainActor in await h.model.stopFromIntent() }
        try await waitUntil { h.model.phase == .processing && !h.model.pending.isEmpty }
        for _ in 0..<200 {
            if await h.service.dictateCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let inFlightCalls = await h.service.dictateCalls
        XCTAssertEqual(inFlightCalls, 1, "Cancel must exercise an actual in-flight request")
        let pending = try XCTUnwrap(h.model.pending.first)
        XCTAssertGreaterThan(try PendingRecordingStore(directory: h.directory.appendingPathComponent("Pending")).audio(for: pending.id).count, 44)
        await h.model.cancel()
        await submission.value

        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertNil(h.model.latest)
        XCTAssertNil(h.model.latestTextForIntent)
        XCTAssertTrue(h.model.history.isEmpty)
        XCTAssertEqual(h.model.pending.map(\.id), [pending.id])
        XCTAssertTrue(h.model.message?.contains("saved for retry") == true)
    }

    @MainActor
    func testCancelDuringRecordingDiscardsAudioWithoutUploading() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        await h.model.startInForeground()
        await h.model.cancel()
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.capture.discardCount, 1)
        XCTAssertEqual(h.model.elapsed, 0)
        XCTAssertTrue(h.model.pending.isEmpty)
        XCTAssertNil(h.model.latestTextForIntent)
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testNoSpeechCompletesWithoutShortcutTextOrRetryAudio() async throws {
        let h = try Harness(mode: .noSpeech)
        defer { h.removeDirectory() }
        await h.model.startInForeground()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertFalse(try XCTUnwrap(h.model.latest).reply.hasText)
        XCTAssertNil(h.model.latestTextForIntent)
        XCTAssertTrue(h.model.pending.isEmpty)
        XCTAssertTrue(h.model.message?.contains("No speech") == true)
        XCTAssertEqual(h.model.history.count, 1)
    }

    @MainActor
    func testCleanupFailureStillDeliversDeterministicText() async throws {
        let h = try Harness(mode: .cleanupFallback)
        defer { h.removeDirectory() }
        await h.model.startInForeground()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertNotNil(h.model.latest?.reply.cleanupError)
        XCTAssertNotNil(h.model.latestTextForIntent)
        XCTAssertTrue(h.model.pending.isEmpty)
        XCTAssertTrue(h.model.message?.contains("preserved") == true)
    }

    @MainActor
    func testDeniedMicrophoneDoesNotStartCaptureOrUpload() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        h.capture.hasPermission = false
        await h.model.startInForeground()
        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertEqual(h.capture.startCount, 0)
        XCTAssertTrue(h.model.message?.contains("Microphone") == true)
        XCTAssertTrue(h.model.pending.isEmpty)
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testIntentRequiresPreviouslyGrantedPermission() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        h.capture.hasPermission = false
        do {
            try await h.model.startFromIntent()
            XCTFail("A background intent cannot request microphone permission")
        } catch let error as AppCaptureError {
            guard case .needsForeground = error else { return XCTFail("Expected foreground setup requirement") }
        }
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.capture.startCount, 0)
    }

    @MainActor
    func testOldPermissionDenialCannotCancelANewerRecording() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = PermissionGateCapture(directory: directory)
        defer { capture.resolveAll(granted: false) }
        let service = FixtureOlivService()
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "test"),
                             capture: capture, liveActivitiesEnabled: false, clientFactory: { _ in service })
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-token"
        model.settings.autoCopy = false
        model.saveSettings()
        let firstStart = Task { @MainActor in await model.startInForeground() }
        try await waitUntil { capture.permissionRequestCount == 1 }
        await model.cancel()
        let secondStart = Task { @MainActor in await model.startInForeground() }
        try await waitUntil { capture.permissionRequestCount == 2 }
        capture.resolveRequest(2, granted: true)
        await secondStart.value
        XCTAssertEqual(model.phase, .recording)
        capture.resolveRequest(1, granted: false)
        await firstStart.value
        XCTAssertEqual(model.phase, .recording, "A stale permission result must not overwrite the active session")
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertNil(model.message)
        await model.cancel()
    }

    @MainActor
    func testDoubleStartAndStopWhileIdleDoNotDuplicateWork() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .idle)
        await h.model.startInForeground()
        await h.model.startInForeground()
        try await h.model.startFromIntent()
        XCTAssertEqual(h.capture.startCount, 1)
        await h.model.stopFromIntent()
        await h.model.stopFromIntent()
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(h.model.history.count, 1)
    }

    @MainActor
    func testShortRecordingIsDiscardedBeforeNetworking() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        h.capture.audioDuration = 0.1
        await h.model.startInForeground()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertEqual(h.capture.discardCount, 1)
        XCTAssertTrue(h.model.pending.isEmpty)
        XCTAssertTrue(h.model.history.isEmpty)
        XCTAssertTrue(h.model.message?.contains("too short") == true)
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testCaptureStartFailureCanBeRetried() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        h.capture.startError = AppCaptureError.unavailable
        await h.model.startInForeground()
        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertFalse(h.model.isBusy)
        XCTAssertTrue(h.model.pending.isEmpty)
        h.capture.startError = nil
        await h.model.startInForeground()
        XCTAssertEqual(h.model.phase, .recording)
        await h.model.cancel()
    }

    @MainActor
    func testHistoryDisabledLeavesResultAvailableButNothingOnDisk() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        h.model.settings.keepHistory = false
        await h.model.startInForeground()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertNotNil(h.model.latestTextForIntent)
        XCTAssertTrue(h.model.history.isEmpty)
        XCTAssertTrue(h.model.pending.isEmpty)
        XCTAssertTrue(try HistoryStore(directory: h.directory).entries().isEmpty)
        let reopened = AppModel(directory: h.directory, credentials: MemoryCredentialStore(token: "test"),
                                capture: FixtureAudioCapture(directory: h.directory), liveActivitiesEnabled: false,
                                clientFactory: { _ in h.service })
        XCTAssertNil(reopened.latest)
        XCTAssertTrue(reopened.history.isEmpty)
        XCTAssertTrue(reopened.pending.isEmpty)
    }

    @MainActor
    func testCleanTextUsesSamePipelineWithoutAudioAndIgnoresBlankInput() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        await h.model.cleanText(" \n ")
        XCTAssertEqual(h.model.phase, .idle)
        await h.model.cleanText("ส่งขึ้นกราฟาน่า")
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertEqual(h.model.latest?.source, .cleanup)
        XCTAssertEqual(h.model.latest?.audioDuration, 0)
        XCTAssertNotNil(h.model.latestTextForIntent)
        XCTAssertEqual(h.capture.startCount, 0)
        let cleanCalls = await h.service.cleanCalls
        let dictateCalls = await h.service.dictateCalls
        XCTAssertEqual(cleanCalls, 1)
        XCTAssertEqual(dictateCalls, 0)
    }

    @MainActor
    func testConnectionCheckOnlyReportsPublicLivenessWithoutVerifyingToken() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AuthorizationProbeService()
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "wrong-token"),
                             capture: FixtureAudioCapture(directory: directory), liveActivitiesEnabled: false,
                             clientFactory: { _ in service })
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-token"
        model.saveSettings()
        await model.checkConnection()
        let healthCalls = await service.healthCalls
        let cleanCalls = await service.cleanCalls
        XCTAssertEqual(healthCalls, 1)
        let dictateCalls = await service.dictateCalls
        XCTAssertEqual(cleanCalls, 0)
        XCTAssertEqual(dictateCalls, 0)
        XCTAssertFalse(model.isCheckingConnection)
        XCTAssertEqual(model.connectionMessage, "The API key is invalid, expired or revoked. Update it in Settings and retry.")
        XCTAssertFalse(model.connectionMessage?.contains("wrong-token") == true)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNil(model.latest)
    }

    @MainActor
    func testConnectionCheckTellsAValidKeyWithoutDictateScopeFromARejectedOne() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "cleanup-only"),
                             capture: FixtureAudioCapture(directory: directory), liveActivitiesEnabled: false,
                             clientFactory: { _ in ScopeLimitedService() })
        model.settings.serverURL = "https://oliv.example.com"
        model.tokenInput = "fixture-token"
        model.saveSettings()
        await model.checkConnection()
        XCTAssertEqual(model.connectionMessage, "Connected, but this API key can't dictate. Ask the administrator to add the dictate scope.")
    }

    @MainActor
    func testSuccessfulConnectionCheckDoesNotCreateHistory() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        await h.model.checkConnection()
        XCTAssertEqual(h.model.connectionMessage, "Connected. Your API key works.")
        XCTAssertTrue(h.model.history.isEmpty)
        XCTAssertNil(h.model.latest)
        let cleanCalls = await h.service.cleanCalls
        let dictateCalls = await h.service.dictateCalls
        XCTAssertEqual(cleanCalls, 0)
        XCTAssertEqual(dictateCalls, 0)
    }

    @MainActor
    func testSettingsStoreNeverContainsAccessToken() throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        h.model.tokenInput = "new-test-secret"
        h.model.saveSettings()
        XCTAssertNil(h.model.message)
        XCTAssertEqual(h.model.tokenInput, "")
        XCTAssertEqual(try h.credentials.read(), "new-test-secret")
        let stored = try Data(contentsOf: h.directory.appendingPathComponent("settings.json"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("new-test-secret"))
    }

    @MainActor
    func testUnsavedServerAddressCannotForwardExistingToken() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = FixtureAudioCapture(directory: directory)
        let service = FixtureOlivService()
        let credentials = MemoryCredentialStore(token: "fixture-bound-token")
        var forwardedHosts: [String] = []
        var forwardedTokens: [String] = []
        let model = AppModel(directory: directory, credentials: credentials, capture: capture,
                             liveActivitiesEnabled: false, clientFactory: { configuration in
            forwardedHosts.append(configuration.baseURL.host ?? "")
            forwardedTokens.append(configuration.token)
            return service
        })
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-bound-token"
        model.settings.autoCopy = false
        model.saveSettings()
        XCTAssertTrue(model.isConfigured)

        model.settings.serverURL = "https://unconfirmed.example"
        model.tokenInput = "fixture-bound-token"
        XCTAssertFalse(model.isConfigured)
        await model.checkConnection()
        XCTAssertEqual(forwardedHosts, ["unconfirmed.example"])
        XCTAssertNotEqual(forwardedTokens.first, "fixture-bound-token",
                          "A public health check must not carry the stored credential to an unsaved endpoint")
        await model.startInForeground()
        await model.cleanText("private draft")
        XCTAssertEqual(forwardedHosts.count, 1, "Unsaved endpoints permit health only")
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(try credentials.read(), "fixture-bound-token")
        let saved = try JSONDecoder().decode(AppSettings.self,
            from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
        XCTAssertEqual(saved.serverURL, "https://oliv.example")

        model.saveSettings()
        XCTAssertTrue(model.isConfigured)
        XCTAssertNil(model.message)
        await model.startInForeground()
        XCTAssertEqual(model.phase, .recording)
        await model.stopFromIntent()
        XCTAssertEqual(model.phase, .result)
        // Once saved, requests (dictation, Dictionary sync) go to that endpoint only.
        XCTAssertGreaterThanOrEqual(forwardedHosts.count, 2)
        XCTAssertTrue(forwardedHosts.allSatisfy { $0 == "unconfirmed.example" })
        XCTAssertEqual(forwardedTokens.last, "fixture-bound-token")
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(try credentials.read(), "fixture-bound-token")
    }

    @MainActor
    func testCleanupFailurePreservesDraftForEditingAndRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CleanupFailureService()
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "test"),
                             capture: FixtureAudioCapture(directory: directory), liveActivitiesEnabled: false,
                             clientFactory: { _ in service })
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-token"
        model.settings.autoCopy = false
        model.saveSettings()
        let draft = "ส่ง draft ให้ทีม review\nข้อความต้องยังอยู่"
        model.cleanupDraft = draft
        await model.cleanText(model.cleanupDraft)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.cleanupDraft, draft)
        XCTAssertNil(model.latest)
        XCTAssertNil(model.latestTextForIntent)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(model.pending.isEmpty)
    }

    @MainActor
    func testMismatchedTokenAndSavedEndpointCannotBeSent() async throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        // Models a Keychain write succeeding but its matching settings write failing.
        try h.credentials.write("token-from-an-uncommitted-server-change")
        await h.model.startInForeground()
        XCTAssertEqual(h.capture.startCount, 0)
        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertTrue(h.model.message?.contains("pair") == true)
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testCopyUsesSystemClipboardAndNoSpeechLeavesItUntouched() throws {
        let h = try Harness()
        defer { h.removeDirectory() }
        // Read only text written by this test, avoiding cross-app paste permission.
        defer { UIPasteboard.general.items = [] }
        let entry = HistoryEntry(audioDuration: 1, totalDuration: 1,
            reply: DictationReply(raw: "original", finalText: "ข้อความไทย and English"))
        h.model.copy(entry)
        XCTAssertEqual(UIPasteboard.general.string, entry.finalText)
        h.model.copy(HistoryEntry(audioDuration: 1, totalDuration: 1,
            reply: DictationReply(noSpeech: true)))
        XCTAssertEqual(UIPasteboard.general.string, entry.finalText)
    }

    func testKeychainRoundTripUsesOnlyAnIsolatedRandomService() throws {
        let service = "com.chayapat.oliv.tests.\(UUID().uuidString)"
        let credentials = KeychainCredentialStore(service: service)
        defer { XCTAssertNoThrow(try credentials.delete()) }
        XCTAssertNil(try credentials.read())
        try credentials.write("first-integration-test-value")
        XCTAssertEqual(try credentials.read(), "first-integration-test-value")
        try credentials.write("updated-integration-test-value")
        XCTAssertEqual(try credentials.read(), "updated-integration-test-value")
        try credentials.delete()
        XCTAssertNil(try credentials.read())
    }

    @MainActor
    func testLivePublicAPIHealthAndUnauthorizedCleanup() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OLIV_LIVE_TESTS"] == "1", let liveURL = environment["OLIV_LIVE_TEST_URL"] else {
            throw XCTSkip("Set OLIV_LIVE_TESTS=1 and OLIV_LIVE_TEST_URL to check a server with a deliberately invalid key.")
        }
        let url = try XCTUnwrap(URL(string: liveURL))
        let invalidToken = "oliv-deliberately-invalid-\(UUID().uuidString)"
        let configuration = try OlivConfiguration(baseURL: url, token: invalidToken,
                                                   allowsInsecureHTTP: url.scheme == "http")
        let client = OlivClient(configuration: configuration)
        let health = try await client.health()
        XCTAssertTrue(health.ok)
        // The public gateway may return only {"ok":true}; model readiness is separate.
        if let version = health.version { XCTAssertFalse(version.isEmpty) }
        do {
            _ = try await client.clean(text: "")
            XCTFail("The public API accepted a deliberately invalid key")
        } catch let error as OlivError {
            XCTAssertEqual(error, .unauthorized)
        }
        // Verify the exact gateway status independently: 403 is not a 401 alias.
        // No real credential, transcript, or WAV leaves this opt-in test.
        var request = URLRequest(url: url.appendingPathComponent("v1/clean"))
        request.httpMethod = "POST"
        request.timeoutInterval = OlivClient.requestTimeout
        request.setValue("Bearer \(invalidToken)", forHTTPHeaderField: "Authorization")
        request.setValue(OlivClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"text":""}"#.utf8)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 401)
    }

    @MainActor
    func testInterruptedRecordingRecoversOriginalOptionsOnLaunch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capture = FixtureAudioCapture(directory: directory)
        let wav = try WAVEncoder.encode(samples: .init(repeating: 1, count: 16_000))
        let options = OlivOptions(cleanup: false, vocabulary: ["Recovered vocabulary"])
        try wav.write(to: capture.recoveryURL)
        try JSONEncoder().encode(options).write(to: directory.appendingPathComponent("inflight-options.json"))
        let service = FixtureOlivService()
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "test"),
                             capture: capture, liveActivitiesEnabled: false, clientFactory: { _ in service })
        let item = try XCTUnwrap(model.pending.first)
        XCTAssertEqual(item.options, options)
        XCTAssertEqual(item.audioDuration, 1)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.message?.contains("Recovered") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.recoveryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("inflight-options.json").path))
    }

    @MainActor
    func testCorruptInterruptedRecordingIsPreservedWithoutHidingGoodHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyStore = try HistoryStore(directory: directory)
        let previous = HistoryEntry(audioDuration: 1, totalDuration: 0.4,
                                    reply: DictationReply(raw: "preserved", finalText: "preserved"))
        try historyStore.append(previous)
        let capture = FixtureAudioCapture(directory: directory)
        let partial = Data("incomplete WAV".utf8)
        try partial.write(to: capture.recoveryURL)
        try JSONEncoder().encode(OlivOptions()).write(to: directory.appendingPathComponent("inflight-options.json"))
        let service = FixtureOlivService()
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "test"),
                             capture: capture, liveActivitiesEnabled: false, clientFactory: { _ in service })
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-token"
        model.settings.autoCopy = false
        XCTAssertEqual(model.history.map(\.id), [previous.id])
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.message?.contains("preserved") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.recoveryURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Interrupted"), includingPropertiesForKeys: nil)
        let preservedAudio = try XCTUnwrap(quarantined.first { $0.pathExtension == "wav" })
        XCTAssertEqual(try Data(contentsOf: preservedAudio), partial)
        model.saveSettings()
        await model.startInForeground()
        XCTAssertEqual(model.phase, .recording)
        await model.cancel()
    }

    @MainActor
    func testDefaultOptionsMatchSourceAndInvalidSettingsDoNotReplaceSavedSettings() throws {
        let defaults = AppSettings()
        XCTAssertTrue(defaults.cleanup)
        XCTAssertTrue(defaults.removeFillers)
        XCTAssertTrue(defaults.thaiFormat)
        XCTAssertTrue(defaults.keepHistory)
        XCTAssertFalse(defaults.allowsInsecureHTTP)
        XCTAssertFalse(defaults.stopAfterSilence)
        XCTAssertEqual(defaults.options(dictionary: DictionaryBook()), OlivOptions())
        let h = try Harness()
        defer { h.removeDirectory() }
        h.model.saveSettings()
        let url = h.directory.appendingPathComponent("settings.json")
        let saved = try Data(contentsOf: url)
        h.model.tokenInput = "must-not-be-written"
        h.model.settings.serverURL = "http://example.com"
        h.model.saveSettings()
        XCTAssertTrue(h.model.message?.contains("HTTPS") == true)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        XCTAssertEqual(try h.credentials.read(), "fixture-token")
    }

    @MainActor
    func testMissingTokenRequiresSetupWithoutStartingMicrophone() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = FixtureAudioCapture(directory: directory)
        let service = FixtureOlivService()
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(),
                             capture: capture, liveActivitiesEnabled: false, clientFactory: { _ in service })
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-token"
        XCTAssertFalse(model.hasToken)
        XCTAssertFalse(model.isConfigured)
        await model.startInForeground()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.selectedTab, 2)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertTrue(model.message?.contains("access token") == true)
        let calls = await service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testCredentialReadFailurePreservesHistoryAndPendingRecordings() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryEntry(audioDuration: 1, totalDuration: 0.5,
                                   reply: DictationReply(raw: "saved", finalText: "saved"))
        try HistoryStore(directory: directory).append(history)
        let pendingStore = try PendingRecordingStore(directory: directory.appendingPathComponent("Pending"))
        let pending = try pendingStore.enqueue(wav: WAVEncoder.encode(samples: .init(repeating: 1, count: 16_000)),
                                               options: OlivOptions(vocabulary: ["Preserved"]))
        let capture = FixtureAudioCapture(directory: directory)
        let service = FixtureOlivService()
        let model = AppModel(directory: directory, credentials: UnavailableCredentialStore(),
                             capture: capture, liveActivitiesEnabled: false, clientFactory: { _ in service })
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-token"
        XCTAssertFalse(model.hasToken)
        XCTAssertEqual(model.history.map(\.id), [history.id])
        XCTAssertEqual(model.pending.map(\.id), [pending.id])
        XCTAssertTrue(model.message?.contains("Unlock") == true)
        await model.startInForeground()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(model.history.map(\.id), [history.id])
        XCTAssertEqual(model.pending.map(\.id), [pending.id])
    }

    func testBackgroundStoresRemainAccessibleAfterFirstUnlock() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("iOS Simulator does not expose Data Protection file attributes. Verify this policy on a physical iPhone.")
        #else
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyStore = try HistoryStore(directory: directory)
        try historyStore.append(HistoryEntry(audioDuration: 1, totalDuration: 0.4,
            reply: DictationReply(raw: "test", finalText: "test")))
        let pendingDirectory = directory.appendingPathComponent("Pending")
        let pendingStore = try PendingRecordingStore(directory: pendingDirectory)
        let pending = try pendingStore.enqueue(wav: WAVEncoder.encode(samples: .init(repeating: 1, count: 16_000)),
                                               options: OlivOptions())
        try RetryCooldownStore(directory: directory).record(until: Date().addingTimeInterval(600))
        let recordingDirectory = pendingDirectory.appendingPathComponent(pending.id.uuidString)
        for file in [directory.appendingPathComponent("history.json"),
                     directory.appendingPathComponent("retry-cooldown.json"),
                     recordingDirectory.appendingPathComponent("metadata.json"),
                     recordingDirectory.appendingPathComponent("audio.wav")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(attributes[.protectionKey] as? String,
                           FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
                           "\(file.lastPathComponent) must support close/reopen during locked-screen processing")
        }
        #endif
    }

    @MainActor
    func testRealAudioRecorderProducesCompatiblePCMWithoutNetworking() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capture = AudioCaptureService(directory: directory)
        NSLog("[OlivAudioIntegration] before permission preflight")
        guard capture.hasPermission else {
            throw XCTSkip("Grant microphone permission to com.chayapat.oliv.ios before running the real recorder check.")
        }
        NSLog("[OlivAudioIntegration] iOS permission granted; host macOS microphone permission is independent")
        defer {
            NSLog("[OlivAudioIntegration] before capture.discard")
            capture.discard()
            NSLog("[OlivAudioIntegration] after capture.discard")
        }
        NSLog("[OlivAudioIntegration] before capture.start")
        try await capture.start()
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .measurement)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers),
                      "Explicit dictation must not request interruption of another app's audio")
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothHFP))
        NSLog("[OlivAudioIntegration] after capture.start; before 400 ms sleep")
        try await Task.sleep(for: .milliseconds(400))
        NSLog("[OlivAudioIntegration] after sleep; before capture.stop")
        let audio = try capture.stop()
        XCTAssertEqual(capture.meter().duration, 0, "Stopping releases the recorder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.recoveryURL.path),
                      "Stopping must preserve audio until the app durably enqueues it")
        NSLog("[OlivAudioIntegration] after capture.stop; before WAV metadata validation")
        let metadata = try WAVMetadata(data: audio)
        XCTAssertEqual(metadata.sampleRate, 16_000)
        XCTAssertEqual(metadata.channelCount, 1)
        XCTAssertEqual(metadata.bitsPerSample, 16)
        XCTAssertGreaterThan(metadata.duration, 0)
        XCTAssertLessThanOrEqual(metadata.duration, RecordingLimits.maximumDuration)
        XCTAssertGreaterThan(metadata.dataByteCount, 0)
        // Apple's recorder adds FLLR padding that the public API rejects. Check
        // the actual recorder's upload conversion, not only our local decoder.
        let upload = try WAVEncoder.canonicalize(audio)
        XCTAssertEqual(try WAVMetadata(data: upload), metadata)
        XCTAssertEqual(upload.count, 44 + metadata.dataByteCount)
        XCTAssertEqual(String(decoding: upload[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: upload[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(try WAVEncoder.canonicalize(upload), upload)
        capture.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.recoveryURL.path))
        NSLog("[OlivAudioIntegration] WAV metadata validation finished")
        // Deliberately no network client: microphone bytes never leave this test.
    }

    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the expected state transition")
        throw TestFailure.timedOut
    }

    private enum TestFailure: Error { case timedOut }
}

@MainActor
private struct Harness {
    let directory: URL
    let capture: FixtureAudioCapture
    let service: FixtureOlivService
    let credentials: MemoryCredentialStore
    let model: AppModel

    init(mode: FixtureOlivService.Mode = .success) throws {
        directory = temporaryDirectory()
        capture = FixtureAudioCapture(directory: directory)
        service = FixtureOlivService(mode: mode)
        credentials = MemoryCredentialStore(token: "fixture-token")
        let service = self.service
        model = AppModel(directory: directory, credentials: credentials, capture: capture,
                         liveActivitiesEnabled: false, clientFactory: { _ in service })
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-token"
        model.settings.autoCopy = false
        model.saveSettings()
        XCTAssertNil(model.message)
    }

    func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("OlivAppTests-\(UUID())", isDirectory: true)
}

private actor ScopeLimitedService: OlivServing {
    func verifyKey() async throws { throw OlivError.forbidden(reason: .missingScope) }
    func health() async throws -> ServerHealth {
        try JSONDecoder().decode(ServerHealth.self, from: Data(#"{"ok":true}"#.utf8))
    }
    func clean(text: String, options: OlivOptions) async throws -> DictationReply { throw OlivError.networkUnavailable }
    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply { throw OlivError.networkUnavailable }
}

private actor AuthorizationProbeService: OlivServing {
    private(set) var healthCalls = 0
    private(set) var cleanCalls = 0
    private(set) var dictateCalls = 0
    func verifyKey() async throws { throw OlivError.unauthorized }
    func health() async throws -> ServerHealth {
        healthCalls += 1
        return try JSONDecoder().decode(ServerHealth.self, from: Data(#"{"ok":true}"#.utf8))
    }
    func clean(text: String, options: OlivOptions) async throws -> DictationReply {
        cleanCalls += 1
        XCTFail("A connection check must never submit cleanup, including empty text")
        throw OlivError.unauthorized
    }
    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply {
        dictateCalls += 1
        XCTFail("Connection checks must not upload audio")
        throw OlivError.unauthorized
    }
}

private struct UnavailableCredentialStore: CredentialStoring {
    func read() throws -> String? { throw CredentialError.unavailable }
    func write(_ token: String) throws { throw CredentialError.unavailable }
}

private actor CleanupFailureService: OlivServing {
    func clean(text: String, options: OlivOptions) async throws -> DictationReply { throw OlivError.networkUnavailable }
    func verifyKey() async throws {}
    func health() async throws -> ServerHealth { throw OlivError.networkUnavailable }
    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply { throw OlivError.networkUnavailable }
}

@MainActor
private final class PermissionGateCapture: AudioCapturing {
    let recoveryURL: URL
    var hasPermission = true
    var onInterruption: (() -> Void)?
    private(set) var permissionRequestCount = 0
    private(set) var startCount = 0
    private var responses: [Int: CheckedContinuation<Bool, Never>] = [:]

    init(directory: URL) { recoveryURL = directory.appendingPathComponent("permission-gate.wav") }
    func requestPermission() async -> Bool {
        permissionRequestCount += 1
        let number = permissionRequestCount
        return await withCheckedContinuation { responses[number] = $0 }
    }
    func resolveRequest(_ number: Int, granted: Bool) {
        responses.removeValue(forKey: number)?.resume(returning: granted)
    }
    func resolveAll(granted: Bool) {
        let pending = responses.values
        responses.removeAll()
        pending.forEach { $0.resume(returning: granted) }
    }
    func start() throws { startCount += 1 }
    func meter() -> (duration: TimeInterval, level: Double, decibels: Float) { (0, 0, -160) }
    func stop() throws -> Data { try WAVEncoder.encode(samples: .init(repeating: 0, count: 16_000)) }
    func discard() {}
    func removeRecoveredAudio() throws {}
}
