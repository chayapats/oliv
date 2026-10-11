import XCTest
@testable import OLIV

@MainActor
final class OLIVAPISettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUpWithError() throws {
        suite = "oliv.api.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: suite) }

    func testAPIIsOffByDefaultAndRequiresOptInAndValidConfiguration() {
        let settings = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertFalse(settings.olivAPIEnabled)
        XCTAssertEqual(settings.olivAPIURL, "https://oliv.redcomp.tech")
        XCTAssertEqual(settings.olivAPITimeout, 120)
        settings.olivAPIKey = "dummy-key"
        XCTAssertNil(settings.olivAPIConfiguration)
        XCTAssertFalse(settings.availableEngines.contains(.olivAPI))
        settings.olivAPIEnabled = true
        XCTAssertNotNil(settings.olivAPIConfiguration)
        XCTAssertTrue(settings.availableEngines.contains(.olivAPI))
        settings.olivAPIURL = "http://public.example.test"
        XCTAssertNil(settings.olivAPIConfiguration)
        XCTAssertNotNil(settings.olivAPIConfigurationError)
        XCTAssertFalse(settings.availableEngines.contains(.olivAPI))
    }

    func testAPIKeyUsesSeparateKeychainAccountAndSelectionPersists() {
        let keychain = InMemoryKeychain()
        let settings = OLIVSettings(defaults: defaults, keychain: keychain)
        settings.groqAPIKey = "groq-dummy"
        settings.olivAPIKey = "oliv-dummy"
        settings.olivAPIEnabled = true
        settings.engineID = OLIVSettings.Engine.olivAPI.id
        XCTAssertEqual(keychain.string(forAccount: KeychainStore.olivAPIAccount), "oliv-dummy")
        XCTAssertEqual(keychain.groqAPIKey(), "groq-dummy")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "oliv-dummy" })
        let reloaded = OLIVSettings(defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.engineID, OLIVSettings.Engine.olivAPI.id)
        XCTAssertNotNil(reloaded.olivAPIConfiguration)
        reloaded.olivAPIEnabled = false
        XCTAssertEqual(reloaded.engineID, SidecarClient.defaultEngine)
        XCTAssertNil(reloaded.olivAPIConfiguration)
        XCTAssertEqual(keychain.groqAPIKey(), "groq-dummy")
    }

    func testClearingKeyRevertsAPIAndModelRequirementsFollowProvider() {
        let settings = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        settings.olivAPIEnabled = true
        settings.olivAPIKey = "dummy"
        settings.engineID = OLIVSettings.Engine.olivAPI.id
        XCTAssertTrue(settings.requiredModelRepos.isEmpty)
        settings.olivAPIKey = ""
        XCTAssertEqual(settings.engineID, SidecarClient.defaultEngine)
        XCTAssertEqual(settings.requiredModelRepos, [RequiredModels.stt, RequiredModels.cleanup])
        settings.cleanupEnabled = false
        XCTAssertEqual(settings.requiredModelRepos, [RequiredModels.stt])
        settings.groqCloudEnabled = true
        settings.groqAPIKey = "groq-dummy"
        settings.engineID = OLIVSettings.Engine.groq.id
        XCTAssertTrue(settings.requiredModelRepos.isEmpty)
        settings.cleanupEnabled = true
        XCTAssertEqual(settings.requiredModelRepos, [RequiredModels.cleanup])
    }

    func testRoutingAndRecordingLimitsDoNotLaunchSidecarForAPI() throws {
        let sidecar = SidecarClient(command: ["/no/such/sidecar"])
        let config = try OLIVAPIConfiguration(url: "https://example.test", apiKey: "dummy")
        XCTAssertTrue(DictationController.provider(engine: OLIVAPIClient.engineID, sidecar: sidecar,
                                                   apiConfiguration: config) is OLIVAPIClient)
        XCTAssertNil(DictationController.provider(engine: OLIVAPIClient.engineID, sidecar: sidecar, apiConfiguration: nil))
        XCTAssertTrue(DictationController.provider(engine: SidecarClient.defaultEngine, sidecar: sidecar,
                                                   apiConfiguration: config) is SidecarDictationProvider)
        XCTAssertFalse(sidecar._isAliveForTests)
        XCTAssertEqual(DictationController.captureSeconds(for: OLIVAPIClient.engineID), 120)
        XCTAssertEqual(DictationController.captureSeconds(for: SidecarClient.defaultEngine), 600)
        XCTAssertEqual(AudioCapture.sampleLimit(seconds: 120), OLIVAPIClient.maxSamples)
        XCTAssertEqual(AudioCapture.sampleLimit(seconds: 600), AudioCapture.maxCaptureSamples)
    }
}
