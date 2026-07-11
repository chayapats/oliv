// Cloud-fallback settings tests (W3-T4) — the engine-picker gating + revert
// logic and the Keychain-backed key wiring. Driven against a throwaway
// UserDefaults suite AND an InMemoryKeychain seam, so fully hermetic (no real
// defaults, no real keychain). The invariant under test is the privacy DoD: the
// cloud engine is offered ONLY when the opt-in toggle is on AND a key is present,
// and turning either off reverts a selected cloud engine back to local.

import XCTest
@testable import OLIV

@MainActor
final class CloudFallbackSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "oliv.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSettings() -> OLIVSettings {
        OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
    }

    // Cloud fallback is OFF by default and no key is stored — the privacy DoD.
    func testDefaultsOffAndLocalOnly() {
        let s = makeSettings()
        XCTAssertFalse(s.groqCloudEnabled)
        XCTAssertTrue(s.groqAPIKey.isEmpty)
        XCTAssertNil(s.groqKeyForSidecar)
    }

    // The pure gating helper: cloud engine appears ONLY with toggle on + key.
    func testAvailableEnginesGating() {
        let off = OLIVSettings.availableEngines(groqEnabled: false, groqKeyPresent: true)
        XCTAssertFalse(off.contains { $0.id == OLIVSettings.Engine.groq.id })

        let noKey = OLIVSettings.availableEngines(groqEnabled: true, groqKeyPresent: false)
        XCTAssertFalse(noKey.contains { $0.id == OLIVSettings.Engine.groq.id })

        let on = OLIVSettings.availableEngines(groqEnabled: true, groqKeyPresent: true)
        XCTAssertTrue(on.contains { $0.id == OLIVSettings.Engine.groq.id })
        XCTAssertEqual(on.count, 4, "local trio + cloud")
        // The local engines are always present regardless.
        XCTAssertEqual(off.map(\.id), [OLIVSettings.Engine.typhoon.id,
                                       OLIVSettings.Engine.pathumma.id,
                                       OLIVSettings.Engine.mlxLarge.id])
    }

    // Instance accessor mirrors the static helper against live state.
    func testInstanceAvailableEnginesReflectState() {
        let s = makeSettings()
        XCTAssertEqual(s.availableEngines.count, 3, "local-only by default")
        s.groqCloudEnabled = true
        s.groqAPIKey = "gsk_test"
        XCTAssertTrue(s.availableEngines.contains { $0.id == OLIVSettings.Engine.groq.id })
        XCTAssertEqual(s.groqKeyForSidecar, "gsk_test")
    }

    // Selecting groq then DISABLING the toggle reverts the engine to local default.
    func testDisableTogglRevertsSelectedGroqEngine() {
        let s = makeSettings()
        s.groqCloudEnabled = true
        s.groqAPIKey = "gsk_test"
        s.engineID = OLIVSettings.Engine.groq.id
        XCTAssertEqual(s.engineID, OLIVSettings.Engine.groq.id)

        s.groqCloudEnabled = false
        XCTAssertEqual(s.engineID, OLIVSettings.Engine.typhoon.id,
                       "disabling the toggle reverts a selected cloud engine to the local default")
        XCTAssertNil(s.groqKeyForSidecar, "toggle off => no key handed to the sidecar")
    }

    // Clearing the KEY (while the toggle stays on) also reverts a selected groq.
    func testClearingKeyRevertsSelectedGroqEngine() {
        let s = makeSettings()
        s.groqCloudEnabled = true
        s.groqAPIKey = "gsk_test"
        s.engineID = OLIVSettings.Engine.groq.id

        s.groqAPIKey = ""   // cleared
        XCTAssertEqual(s.engineID, OLIVSettings.Engine.typhoon.id)
        XCTAssertNil(s.groqKeyForSidecar)
    }

    // Disabling while a LOCAL engine is selected leaves the selection untouched.
    func testDisableDoesNotDisturbLocalSelection() {
        let s = makeSettings()
        s.engineID = OLIVSettings.Engine.mlxLarge.id
        s.groqCloudEnabled = true
        s.groqAPIKey = "gsk_test"
        s.groqCloudEnabled = false
        XCTAssertEqual(s.engineID, OLIVSettings.Engine.mlxLarge.id)
    }

    // The key persists to the injected keychain and reloads on a fresh store; the
    // toggle persists to UserDefaults. groqKeyForSidecar honors the toggle.
    func testKeyAndTogglePersistAndGateSidecarKey() {
        let keychain = InMemoryKeychain()
        let s = OLIVSettings(defaults: defaults, keychain: keychain)
        s.groqCloudEnabled = true
        s.groqAPIKey = "gsk_persist_me"
        XCTAssertEqual(keychain.groqAPIKey(), "gsk_persist_me", "key written to the keychain seam")

        let reloaded = OLIVSettings(defaults: defaults, keychain: keychain)
        XCTAssertTrue(reloaded.groqCloudEnabled)
        XCTAssertEqual(reloaded.groqAPIKey, "gsk_persist_me")
        XCTAssertEqual(reloaded.groqKeyForSidecar, "gsk_persist_me")

        // Key present but toggle off => nil to the sidecar (never leak the key).
        reloaded.groqCloudEnabled = false
        XCTAssertNil(reloaded.groqKeyForSidecar)
    }

    // onChange fires on a toggle/key edit (drives the sidecar respawn + live-apply).
    func testOnChangeFiresOnCloudEdits() {
        let s = makeSettings()
        var count = 0
        s.onChange = { count += 1 }
        s.groqCloudEnabled = true
        s.groqAPIKey = "gsk_x"
        XCTAssertGreaterThanOrEqual(count, 2, "toggle + key edits each announce a change")
    }
}
