import Foundation
import XCTest
import OlivCore
@testable import Oliv

final class PublicAPIMigrationTests: XCTestCase {
    func testDefaultURLComesOnlyFromTheBuildsInfoPlist() {
        XCTAssertEqual(AppSettings.defaultServerURL(from: nil), "")
        XCTAssertEqual(AppSettings.defaultServerURL(from: [:]), "")
        XCTAssertEqual(AppSettings.defaultServerURL(from: ["OLIVDefaultAPIURL": ""]), "")
        XCTAssertEqual(AppSettings.defaultServerURL(from: ["OLIVDefaultAPIURL": 42]), "")
        XCTAssertEqual(AppSettings.defaultServerURL(
            from: ["OLIVDefaultAPIURL": " https://oliv.example.com \n"]), "https://oliv.example.com")
        XCTAssertEqual(AppSettings().serverURL, AppSettings.defaultServerURL)
    }

    @MainActor
    func testCustomEndpointsAndTheirExistingPreferencesAreNotMigrated() throws {
        for endpoint in ["https://custom.example/oliv", "http://192.168.1.10:8083",
                         "http://100.64.0.10:8083/custom"] {
            let directory = migrationTestDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var settings = AppSettings()
            settings.serverURL = endpoint
            settings.allowsInsecureHTTP = endpoint.hasPrefix("http:")
            settings.vocabularyText = "Keep this custom setup"
            settings.credentialBinding = "existing-custom-binding"
            settings.requiresNewAPIKey = nil
            try writeSettings(settings, directory: directory)
            let settingsURL = directory.appendingPathComponent("settings.json")
            let originalData = try Data(contentsOf: settingsURL)
            let credentials = MemoryCredentialStore(token: "custom-server-key")
            let service = PublicAPITestService()
            let model = AppModel(directory: directory, credentials: credentials,
                capture: FixtureAudioCapture(directory: directory), liveActivitiesEnabled: false,
                clientFactory: { _ in service })

            XCTAssertEqual(model.settings, settings)
            XCTAssertEqual(try Data(contentsOf: settingsURL), originalData)
            XCTAssertEqual(try credentials.read(), "custom-server-key")
        }
    }

    @MainActor
    func testPublicHealthWorksWithoutAStoredKeyAndNeverSubmitsInference() async throws {
        let directory = migrationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = FixtureAudioCapture(directory: directory)
        let credentials = MemoryCredentialStore()
        let service = PublicAPITestService()
        var healthConfigurations: [OlivConfiguration] = []
        let model = AppModel(directory: directory, credentials: credentials, capture: capture,
            liveActivitiesEnabled: false, clientFactory: { configuration in
                healthConfigurations.append(configuration)
                return service
            })
        XCTAssertEqual(model.settings.serverURL, AppSettings.defaultServerURL)
        model.settings.serverURL = "https://oliv.example.com"
        XCTAssertFalse(model.hasToken)
        XCTAssertFalse(model.isConfigured)
        await model.checkConnection()

        let counts = await service.counts()
        XCTAssertEqual(counts.health, 1)
        XCTAssertEqual(counts.clean, 0)
        XCTAssertEqual(counts.dictate, 0)
        XCTAssertEqual(healthConfigurations.count, 1)
        XCTAssertFalse(try XCTUnwrap(healthConfigurations.first).token.isEmpty,
                       "The unauthenticated GET may use a non-secret configuration placeholder")
        XCTAssertNil(try credentials.read())
        XCTAssertFalse(model.isCheckingConnection)
        XCTAssertEqual(model.connectionMessage, "Server found. Save your settings to check your API key.")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.latest)
    }

    @MainActor
    func testRateLimitPersistsCooldownAndKeepsNewRecordingsDurableWithoutAutomaticRetry() async throws {
        let deadline = Date().addingTimeInterval(600)
        let h = try PublicAPIHarness(mode: .dictationRateLimit(deadline))
        defer { h.removeDirectory() }
        h.model.settings.vocabularyText = "Original options"
        await h.model.startInForeground()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertEqual(h.model.pending.count, 1)
        XCTAssertNil(h.capture.startedAt, "The microphone must be released even on a quota failure")
        let store = try RetryCooldownStore(directory: h.directory)
        let storedDeadline = try XCTUnwrap(store.until())
        XCTAssertEqual(storedDeadline.timeIntervalSince1970, deadline.timeIntervalSince1970, accuracy: 0.01)
        try await Task.sleep(for: .milliseconds(250))
        let afterFailure = await h.service.counts()
        XCTAssertEqual(afterFailure.dictate, 1, "A rate-limit response must not schedule automatic retries")

        // A user can still capture a new thought; cooldown applies to submission.
        await h.model.startInForeground()
        XCTAssertEqual(h.model.phase, .recording)
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertEqual(h.model.pending.count, 2)
        let afterSecondRecording = await h.service.counts()
        XCTAssertEqual(afterSecondRecording.dictate, 1)
        let recordings = try PendingRecordingStore(directory: h.directory.appendingPathComponent("Pending"))
        for item in h.model.pending {
            XCTAssertGreaterThan(try recordings.audio(for: item.id).count, 44)
            XCTAssertEqual(item.options.vocabulary, ["Original options"])
        }
        XCTAssertTrue(h.model.history.isEmpty)
        XCTAssertNil(h.model.latest)
        XCTAssertNil(h.capture.startedAt)
    }

    @MainActor
    func testPersistedCooldownSurvivesRestartAndEndpointOrKeyChanges() async throws {
        let h = try PublicAPIHarness()
        defer { h.removeDirectory() }
        let deadline = Date().addingTimeInterval(600)
        try RetryCooldownStore(directory: h.directory).record(until: deadline)
        let recordings = try PendingRecordingStore(directory: h.directory.appendingPathComponent("Pending"))
        let item = try recordings.enqueue(wav: testWAV(), options: OlivOptions(vocabulary: ["saved retry"]))
        h.model.settings.serverURL = "https://different.example"
        h.model.tokenInput = "different-api-key"
        h.model.saveSettings()
        XCTAssertNil(h.model.message)
        XCTAssertTrue(h.model.isConfigured)
        let reopened = AppModel(directory: h.directory, credentials: h.credentials,
            capture: FixtureAudioCapture(directory: h.directory), liveActivitiesEnabled: false,
            clientFactory: { _ in h.service })
        XCTAssertTrue(reopened.isConfigured)
        await reopened.retry(try XCTUnwrap(reopened.pending.first))
        XCTAssertEqual(reopened.phase, .failed)
        XCTAssertEqual(reopened.pending.map(\.id), [item.id])
        XCTAssertGreaterThan(try recordings.audio(for: item.id).count, 44)

        reopened.cleanupDraft = "Draft still belongs to the user"
        await reopened.cleanText(reopened.cleanupDraft)
        XCTAssertEqual(reopened.cleanupDraft, "Draft still belongs to the user")
        XCTAssertEqual(reopened.phase, .failed)
        let counts = await h.service.counts()
        XCTAssertEqual(counts.dictate, 0)
        XCTAssertEqual(counts.clean, 0)
        let storedDeadline = try XCTUnwrap(RetryCooldownStore(directory: h.directory).until())
        XCTAssertEqual(storedDeadline.timeIntervalSince1970, deadline.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertTrue(reopened.history.isEmpty)
        XCTAssertNil(reopened.latest)
    }

    @MainActor
    func testCleanupRateLimitPreservesDraftAndAlsoBlocksLaterDictationSubmission() async throws {
        let deadline = Date().addingTimeInterval(600)
        let h = try PublicAPIHarness(mode: .cleanupRateLimit(deadline))
        defer { h.removeDirectory() }
        let draft = "ยังต้องแก้ draft นี้\nKeep this exact text"
        h.model.cleanupDraft = draft
        await h.model.cleanText(draft)
        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertEqual(h.model.cleanupDraft, draft)
        XCTAssertTrue(h.model.history.isEmpty)
        XCTAssertTrue(h.model.pending.isEmpty)
        let storedDeadline = try XCTUnwrap(RetryCooldownStore(directory: h.directory).until())
        XCTAssertEqual(storedDeadline.timeIntervalSince1970, deadline.timeIntervalSince1970, accuracy: 0.01)

        await h.model.cleanText(draft)
        await h.model.startInForeground()
        XCTAssertEqual(h.model.phase, .recording)
        await h.model.stopFromIntent()
        let counts = await h.service.counts()
        XCTAssertEqual(counts.clean, 1)
        XCTAssertEqual(counts.dictate, 0)
        XCTAssertEqual(h.model.cleanupDraft, draft)
        XCTAssertEqual(h.model.pending.count, 1)
        XCTAssertTrue(h.model.history.isEmpty)
        XCTAssertNil(h.model.latest)
        XCTAssertNil(h.capture.startedAt)
    }
}

@MainActor
private struct PublicAPIHarness {
    let directory: URL
    let capture: FixtureAudioCapture
    let credentials: MemoryCredentialStore
    let service: PublicAPITestService
    let model: AppModel

    init(mode: PublicAPITestService.Mode = .success) throws {
        directory = migrationTestDirectory()
        capture = FixtureAudioCapture(directory: directory)
        credentials = MemoryCredentialStore(token: "public-fixture-key")
        service = PublicAPITestService(mode: mode)
        let service = self.service
        model = AppModel(directory: directory, credentials: credentials, capture: capture,
            liveActivitiesEnabled: false, clientFactory: { _ in service })
        model.settings.serverURL = "https://oliv.example.com"
        model.settings.autoCopy = false
        model.saveSettings()
        XCTAssertNil(model.message)
        XCTAssertTrue(model.isConfigured)
    }

    func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class FreeTrialTests: XCTestCase {
    private func makeModel(_ request: @escaping (URL) async throws -> TrialKey,
                           credentials: MemoryCredentialStore = MemoryCredentialStore()) -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(directory: directory, credentials: credentials,
                             capture: FixtureAudioCapture(directory: directory), liveActivitiesEnabled: false,
                             clientFactory: { _ in PublicAPITestService() }, requestTrialKey: request)
        model.trialServerURL = "https://oliv.example.com"
        return (model, directory)
    }

    func testTrialConnectsWithoutTheUserSeeingOrEnteringAKey() async throws {
        let credentials = MemoryCredentialStore()
        let end = Date().addingTimeInterval(604_800)
        let (model, directory) = makeModel({ _ in TrialKey(token: "oliv_trial_key", expiresAt: end) }, credentials: credentials)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(model.needsSetup)
        await model.startTrial()
        XCTAssertTrue(model.isConfigured)
        XCTAssertEqual(try credentials.read(), "oliv_trial_key")
        XCTAssertEqual(model.tokenInput, "")
        XCTAssertEqual(model.settings.trialExpiresAt, end)
        XCTAssertFalse(model.needsSetup)
        XCTAssertFalse(model.trialHasEnded)
    }

    func testTrialRefusalLeavesTheAppUnconfiguredWithAPlainMessage() async throws {
        let (model, directory) = makeModel({ _ in throw TrialRefusal.limitReached })
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.startTrial()
        XCTAssertFalse(model.isConfigured)
        XCTAssertEqual(model.trialMessage, "Today's free trials are taken. Try again tomorrow.")
    }

    func testTypingAnOwnKeyEndsTrialMode() async throws {
        let (model, directory) = makeModel({ _ in TrialKey(token: "oliv_trial_key", expiresAt: Date().addingTimeInterval(60)) })
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.startTrial()
        model.tokenInput = "my-own-key"
        model.saveSettings()
        XCTAssertNil(model.settings.trialExpiresAt)
    }

    func testSetupStaysOpenAfterConnectingUntilFinished() async throws {
        let (model, directory) = makeModel({ _ in TrialKey(token: "oliv_trial_key", expiresAt: Date().addingTimeInterval(60)) })
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(model.isInSetup)
        await model.startTrial()
        XCTAssertTrue(model.isInSetup)
        model.finishSetup()
        XCTAssertFalse(model.isInSetup)
    }
}

private actor PublicAPITestService: OlivServing {
    enum Mode: Sendable { case success, dictationRateLimit(Date), cleanupRateLimit(Date) }
    struct Counts: Sendable { let health: Int; let dictate: Int; let clean: Int }
    let mode: Mode
    private var healthCalls = 0
    private var dictateCalls = 0
    private var cleanCalls = 0

    init(mode: Mode = .success) { self.mode = mode }
    func counts() -> Counts { Counts(health: healthCalls, dictate: dictateCalls, clean: cleanCalls) }
    func verifyKey() async throws {}
    func health() async throws -> ServerHealth {
        healthCalls += 1
        return try JSONDecoder().decode(ServerHealth.self, from: Data(#"{"ok":true}"#.utf8))
    }
    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply {
        dictateCalls += 1
        _ = try WAVMetadata(data: wav)
        if case .dictationRateLimit(let deadline) = mode { throw OlivError.rateLimited(retryAfter: deadline) }
        return DictationReply(raw: "Synthetic result", finalText: "Synthetic result")
    }
    func clean(text: String, options: OlivOptions) async throws -> DictationReply {
        cleanCalls += 1
        if case .cleanupRateLimit(let deadline) = mode { throw OlivError.rateLimited(retryAfter: deadline) }
        return DictationReply(raw: text, finalText: text)
    }
}

private func migrationTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("OlivPublicAPITests-\(UUID())", isDirectory: true)
}

private func writeSettings(_ settings: AppSettings, directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
}

private func testWAV() throws -> Data {
    try WAVEncoder.encode(samples: .init(repeating: 100, count: 16_000))
}
