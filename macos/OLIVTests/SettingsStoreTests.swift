// Settings store round-trip tests (W3-T4). OLIVSettings persists to
// UserDefaults under the "oliv." namespace; these drive it against a
// throwaway suite (never the user's real defaults) and assert every knob
// round-trips, the verbatim set stays lowercased, and onChange fires. Hermetic.

import XCTest
@testable import OLIV

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "oliv.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // Defaults: right_option / SidecarClient.defaultEngine (typhoon-turbo-mlx) /
    // cleanup on / no verbatim apps.
    func testDefaults() {
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertEqual(s.hotkeyID, "right_option")
        XCTAssertEqual(s.engineID, SidecarClient.defaultEngine)
        XCTAssertTrue(s.cleanupEnabled)
        XCTAssertTrue(s.verbatimApps.isEmpty)
        // W4-T1: filler removal defaults ON; no replacements out of the box.
        XCTAssertTrue(s.removeFillers)
        XCTAssertTrue(s.replacements.isEmpty)
        // W4-T2: recording HUD defaults ON.
        XCTAssertTrue(s.showRecordingIndicator)
        // B3/B4: empty vocabulary, formatting commands OFF by default.
        XCTAssertTrue(s.vocabulary.isEmpty)
        XCTAssertFalse(s.formatCommands)
        // Thai formatting post-pass defaults ON.
        XCTAssertTrue(s.thaiFormat)
    }

    // Engine → weights-repo mapping: every LOCAL engine must declare the HF
    // repo its weights live in (so Settings can tell "not downloaded" before
    // the first dictate fails under HF_HUB_OFFLINE), and the cloud engine
    // declares none. The default engine's repo must be the SAME repo
    // onboarding downloads — one source of truth, no drift.
    func testLocalEnginesDeclareTheirWeightsRepos() {
        for engine in OLIVSettings.Engine.local {
            XCTAssertNotNil(engine.repo, "\(engine.id) must declare its weights repo")
        }
        XCTAssertNil(OLIVSettings.Engine.groq.repo, "cloud engine needs no local weights")
        XCTAssertEqual(OLIVSettings.Engine.typhoon.repo, RequiredModels.stt)
    }

    // The picker's download prompt decision: nil when the engine is ready, is
    // cloud, or is unknown; the missing repo id when local weights are absent.
    // `isPresent` is injected so this unit-tests without touching disk.
    func testMissingRepoForEngine() {
        let onlyTyphoonPresent: (String) -> Bool = { $0 == RequiredModels.stt }
        XCTAssertNil(OLIVSettings.missingRepo(
            for: "typhoon-turbo-mlx", isPresent: onlyTyphoonPresent))
        XCTAssertEqual(OLIVSettings.missingRepo(
            for: "pathumma-mlx", isPresent: onlyTyphoonPresent),
            "kinoppy555/Pathumma-whisper-th-large-v3-mlx")
        XCTAssertEqual(OLIVSettings.missingRepo(
            for: "mlx-large-v3", isPresent: onlyTyphoonPresent),
            "mlx-community/whisper-large-v3-mlx")
        XCTAssertNil(OLIVSettings.missingRepo(
            for: "groq-large-v3", isPresent: onlyTyphoonPresent))
        XCTAssertNil(OLIVSettings.missingRepo(
            for: "no-such-engine", isPresent: onlyTyphoonPresent))
    }

    // Every field round-trips: set on one instance, reload from the SAME suite.
    func testRoundTrip() {
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        s.hotkeyID = "f19"
        s.engineID = "mlx-large-v3"
        s.cleanupEnabled = false
        s.verbatimApps = ["com.apple.dt.xcode", "com.apple.terminal"]
        s.removeFillers = false
        s.showRecordingIndicator = false
        s.replacements = ["อีเมลของผม": "me@example.com", "เบอร์ผม": "080-000-0000"]
        s.vocabulary = ["Grafana", "คูเบอร์เนติส", "OLIV"]
        s.formatCommands = true
        s.thaiFormat = false   // default is ON; flip to prove the round-trip

        let reloaded = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertEqual(reloaded.hotkeyID, "f19")
        XCTAssertEqual(reloaded.engineID, "mlx-large-v3")
        XCTAssertFalse(reloaded.cleanupEnabled)
        XCTAssertEqual(reloaded.verbatimApps, ["com.apple.dt.xcode", "com.apple.terminal"])
        XCTAssertFalse(reloaded.removeFillers)
        XCTAssertFalse(reloaded.showRecordingIndicator)
        XCTAssertEqual(reloaded.replacements,
                       ["อีเมลของผม": "me@example.com", "เบอร์ผม": "080-000-0000"])
        // B3: vocabulary round-trips AND preserves the user's ordering.
        XCTAssertEqual(reloaded.vocabulary, ["Grafana", "คูเบอร์เนติส", "OLIV"])
        XCTAssertTrue(reloaded.formatCommands)
        XCTAssertFalse(reloaded.thaiFormat)
    }

    // B3: addVocabularyTerm trims, ignores blanks, de-duplicates
    // case-insensitively, appends (preserving order), and persists; remove drops
    // by exact value.
    func testVocabularyAddDedupRemovePersist() {
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        s.addVocabularyTerm("  Grafana  ")
        s.addVocabularyTerm("คูเบอร์เนติส")
        s.addVocabularyTerm("")             // blank → ignored
        s.addVocabularyTerm("grafana")      // case-insensitive dup → ignored
        XCTAssertEqual(s.vocabulary, ["Grafana", "คูเบอร์เนติส"])

        let reloaded = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertEqual(reloaded.vocabulary, ["Grafana", "คูเบอร์เนติส"])
        reloaded.removeVocabularyTerm("Grafana")
        XCTAssertEqual(reloaded.vocabulary, ["คูเบอร์เนติส"])
    }

    // W4-T1: setReplacement trims the spoken key, ignores a blank spoken OR
    // replacement, overwrites an existing key, and persists across a reload;
    // removeReplacement drops by exact spoken phrase.
    func testReplacementsAddOverwriteRemovePersist() {
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        s.setReplacement(spoken: "  อีเมลของผม  ", replacement: "me@example.com")
        s.setReplacement(spoken: "เบอร์ผม", replacement: "080-000-0000")
        s.setReplacement(spoken: "", replacement: "x")            // blank spoken → ignored
        s.setReplacement(spoken: "y", replacement: "   ")         // blank replacement → ignored
        XCTAssertEqual(s.replacements,
                       ["อีเมลของผม": "me@example.com", "เบอร์ผม": "080-000-0000"])

        s.setReplacement(spoken: "อีเมลของผม", replacement: "new@example.com")  // overwrite
        XCTAssertEqual(s.replacements["อีเมลของผม"], "new@example.com")

        let reloaded = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertEqual(reloaded.replacements["อีเมลของผม"], "new@example.com")
        reloaded.removeReplacement("เบอร์ผม")
        XCTAssertNil(reloaded.replacements["เบอร์ผม"])
        XCTAssertEqual(reloaded.replacements.count, 1)
    }

    // add/remove lowercase the bundle id (macOS bundle-id case-insensitivity) and
    // persist across a reload.
    func testVerbatimAppsLowercasedAndPersisted() {
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        s.addVerbatimApp("Com.Apple.DT.Xcode")
        s.addVerbatimApp("  com.apple.Notes  ")
        s.addVerbatimApp("")   // ignored

        XCTAssertEqual(s.verbatimApps, ["com.apple.dt.xcode", "com.apple.notes"])

        let reloaded = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertEqual(reloaded.verbatimApps, ["com.apple.dt.xcode", "com.apple.notes"])

        reloaded.removeVerbatimApp("COM.APPLE.NOTES")   // case-insensitive remove
        XCTAssertEqual(reloaded.verbatimApps, ["com.apple.dt.xcode"])
    }

    // The hotkeyKey convenience resolves the stored id to a HotkeyKey.
    func testHotkeyKeyConvenience() {
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        s.hotkeyID = "right_control"
        XCTAssertEqual(s.hotkeyKey, .rightControl)
        s.hotkeyID = "nonsense"
        XCTAssertEqual(s.hotkeyKey, .rightOption)   // fallback
    }

    // 0.1.5 transcript history toggle: default ON, round-trips, fires onChange
    // (the coordinator clears retained entries when it flips off).
    func testHistoryEnabledDefaultRoundTripAndOnChange() {
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertTrue(s.historyEnabled, "history defaults ON")

        var fired = 0
        s.onChange = { fired += 1 }
        s.historyEnabled = false
        XCTAssertEqual(fired, 1)

        let reloaded = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertFalse(reloaded.historyEnabled)
    }

    // onChange fires on a mutation (the live-apply hook) but NOT during init.
    func testOnChangeFires() {
        var initFired = false
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        s.onChange = { initFired = true }
        XCTAssertFalse(initFired, "onChange must not fire retroactively for init")

        var count = 0
        s.onChange = { count += 1 }
        s.cleanupEnabled.toggle()
        s.hotkeyID = "f19"
        XCTAssertEqual(count, 2)
    }
}
