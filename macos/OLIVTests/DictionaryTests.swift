// Dictionary tests (unified Dictionary): model validation, dedupe keys, CSV
// round-trip + limits, legacy migration, starred ordering, wire derivation,
// and settings persistence. Hermetic (throwaway UserDefaults suite).

import XCTest
@testable import OLIV

@MainActor
final class DictionaryTests: XCTestCase {
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

    // MARK: Validation

    func testValidationTrimsRejectsBlanksAndPunctuation() {
        XCTAssertTrue(DictionaryEntry.isValidWord("Grafana"))
        XCTAssertTrue(DictionaryEntry.isValidWord("  ชยพัฒน์  "))
        XCTAssertFalse(DictionaryEntry.isValidWord(""))
        XCTAssertFalse(DictionaryEntry.isValidWord("   "))
        XCTAssertFalse(DictionaryEntry.isValidWord("!!!"))
        XCTAssertFalse(DictionaryEntry.isValidWord("…"))
        XCTAssertNil(DictionaryEntry.normalized(word: "  ", correction: nil))
        XCTAssertNil(DictionaryEntry.normalized(word: "!!!", correction: nil))
        // Blank correction normalizes to vocabulary-only, not invalid.
        XCTAssertEqual(DictionaryEntry.normalized(word: "Grafana", correction: "  ")?.correction, nil)
        XCTAssertTrue(DictionaryEntry.isValidCorrection(nil))
        XCTAssertFalse(DictionaryEntry.isValidCorrection("???"))
    }

    func testLengthLimitsWarnOver60RejectOver100() {
        let ok60 = String(repeating: "a", count: 60)
        let warn61 = String(repeating: "ก", count: 61)
        let tooLong = String(repeating: "a", count: 101)
        XCTAssertTrue(DictionaryEntry.isValidWord(ok60))
        XCTAssertTrue(DictionaryEntry.isValidWord(warn61), "over 60 still saves (Thai phrases run long)")
        XCTAssertFalse(DictionaryEntry.isValidWord(tooLong))
        XCTAssertTrue(DictionaryEntry(word: warn61).needsLengthWarning)
        XCTAssertFalse(DictionaryEntry(word: ok60).needsLengthWarning)
    }

    // MARK: Dedupe keys

    func testDedupeKeysLatinCaseInsensitiveThaiExact() {
        XCTAssertEqual(DictionaryEntry.dedupeKey(for: "Grafana"),
                       DictionaryEntry.dedupeKey(for: "grafana"))
        XCTAssertEqual(DictionaryEntry.dedupeKey(for: "  OLIV  "),
                       DictionaryEntry.dedupeKey(for: "oliv"))
        // Thai has no case — exact match only.
        XCTAssertEqual(DictionaryEntry.dedupeKey(for: "ชยพัฒน์"),
                       DictionaryEntry.dedupeKey(for: "ชยพัฒน์"))
        XCTAssertNotEqual(DictionaryEntry.dedupeKey(for: "Kubernetes"),
                          DictionaryEntry.dedupeKey(for: "คูเบอร์เนติส"))
        // One correction per entry: same word, different corrections differ.
        let a = DictionaryEntry(word: "Grafana", correction: "grafannah")
        let b = DictionaryEntry(word: "grafana", correction: "grafannah")
        let c = DictionaryEntry(word: "Grafana", correction: "grafenna")
        XCTAssertEqual(a.dedupeKey(), b.dedupeKey())
        XCTAssertNotEqual(a.dedupeKey(), c.dedupeKey())
    }

    // MARK: Add / update / remove / toggle / star / search

    func testAddUpdateRemoveToggleStarSearch() {
        let s = makeSettings()
        XCTAssertTrue(s.dictionaryEntries.isEmpty, "fresh store migrates to empty")

        // Add word-only + correction pair; blanks/dups rejected.
        let w = s.addDictionaryEntry(word: "  Grafana  ", correction: nil)
        XCTAssertNotNil(w)
        XCTAssertNil(s.addDictionaryEntry(word: "grafana", correction: nil), "case-insensitive dup")
        XCTAssertNil(s.addDictionaryEntry(word: "   ", correction: nil))
        XCTAssertNil(s.addDictionaryEntry(word: "!!!", correction: nil))
        let pair = s.addDictionaryEntry(word: "Kubernetes", correction: "koobernetes")
        XCTAssertNotNil(pair)
        XCTAssertNil(s.addDictionaryEntry(word: "KUBERNETES", correction: "koobernetes"), "exact dup")
        XCTAssertEqual(s.dictionaryEntries.count, 2)

        // Upgrade: a correction for an existing word-only entry merges in place.
        let upgraded = s.addDictionaryEntry(word: "GRAFANA", correction: "grafannah")
        XCTAssertNotNil(upgraded)
        XCTAssertEqual(s.dictionaryEntries.count, 2, "upgrade must not append")
        XCTAssertEqual(s.dictionaryEntries.first(where: { $0.id == w?.id })?.correction, "grafannah")

        // Update by id; collisions and bad ids fail.
        XCTAssertTrue(s.updateDictionaryEntry(id: pair!.id, word: "k8s", correction: "kates"))
        XCTAssertFalse(s.updateDictionaryEntry(id: pair!.id, word: "", correction: nil))
        XCTAssertFalse(s.updateDictionaryEntry(id: pair!.id, word: "Grafana", correction: "grafannah"),
                       "would collide with the upgraded entry")
        XCTAssertFalse(s.updateDictionaryEntry(id: "missing", word: "x", correction: nil))

        // Toggle + star.
        s.setDictionaryEntryEnabled(id: pair!.id, enabled: false)
        XCTAssertFalse(s.dictionaryEntries.first(where: { $0.id == pair!.id })?.enabled ?? true)
        s.setDictionaryEntryStarred(id: pair!.id, starred: true)
        XCTAssertTrue(s.dictionaryEntries.first(where: { $0.id == pair!.id })?.starred ?? false)

        // Search covers word + correction, case-insensitively.
        XCTAssertEqual(s.dictionarySearch("").count, 2)
        XCTAssertEqual(s.dictionarySearch("graf").count, 1)
        XCTAssertEqual(s.dictionarySearch("KATES").count, 1, "search hits the correction")
        XCTAssertTrue(s.dictionarySearch("zzz").isEmpty)

        // Remove one, then bulk-remove the rest.
        s.removeDictionaryEntry(pair!.id)
        XCTAssertEqual(s.dictionaryEntries.count, 1)
        s.removeDictionaryEntries(Set(s.dictionaryEntries.map(\.id)))
        XCTAssertTrue(s.dictionaryEntries.isEmpty)
        s.removeDictionaryEntries([]) // no-op, never crashes
    }

    // MARK: CSV

    func testCSVRoundTrip() throws {
        let entries = [
            DictionaryEntry(word: "Grafana", correction: "grafannah"),
            DictionaryEntry(word: "ชยพัฒน์"),
            DictionaryEntry(word: "say \"hi\", please", correction: "a,b"),
        ]
        let csv = DictionaryEntry.serializeCSV(entries)
        XCTAssertTrue(csv.hasPrefix("word,correction\n"))
        let parsed = try DictionaryEntry.parseCSV(csv)
        XCTAssertEqual(parsed.skipped, 0)
        XCTAssertEqual(parsed.entries.count, 3)
        XCTAssertEqual(parsed.entries[0].word, "Grafana")
        XCTAssertEqual(parsed.entries[0].correction, "grafannah")
        XCTAssertNil(parsed.entries[1].correction)
        XCTAssertEqual(parsed.entries[2].word, "say \"hi\", please")
        XCTAssertEqual(parsed.entries[2].correction, "a,b")
        XCTAssertEqual(parsed.entries[2].source, .import)
    }

    func testCSVSkipsInvalidAndDuplicateRows() throws {
        let csv = "word,correction\nGrafana,grafannah\n   \n!!!,x\nGrafana,grafannah\nKubernetes,\n"
        let parsed = try DictionaryEntry.parseCSV(csv)
        XCTAssertEqual(parsed.entries.map(\.word), ["Grafana", "Kubernetes"])
        XCTAssertEqual(parsed.skipped, 2, "punctuation-only + exact dup (blank lines are ignored)")
    }

    func testCSVRejectsBadHeaderEmptyAndTooManyRows() {
        XCTAssertThrowsError(try DictionaryEntry.parseCSV("hello\nworld\n")) { error in
            XCTAssertEqual(error as? DictionaryEntry.CSVError, .badHeader)
        }
        XCTAssertThrowsError(try DictionaryEntry.parseCSV("  \n ")) { error in
            XCTAssertEqual(error as? DictionaryEntry.CSVError, .empty)
        }
        var big = "word,correction\n"
        for i in 0...DictionaryEntry.maxCSVRows {
            big += "word\(i),\n"
        }
        XCTAssertThrowsError(try DictionaryEntry.parseCSV(big)) { error in
            XCTAssertEqual(error as? DictionaryEntry.CSVError,
                            .tooManyRows(limit: DictionaryEntry.maxCSVRows))
        }
    }

    func testSettingsImportExportCSVDedupesAgainstExisting() throws {
        let s = makeSettings()
        s.addDictionaryEntry(word: "Grafana", correction: nil)
        let (imported, skipped) = try s.importDictionaryCSV(
            "word,correction\nGrafana,\nKubernetes,koobernetes\n!!!,\n")
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(skipped, 2, "existing dup + invalid row")
        XCTAssertEqual(s.dictionaryEntries.count, 2)
        // Export → re-import into a fresh store round-trips.
        let csv = s.exportDictionaryCSV()
        let freshName = suiteName + ".fresh"
        defer { UserDefaults(suiteName: freshName)?.removePersistentDomain(forName: freshName) }
        let fresh = OLIVSettings(defaults: UserDefaults(suiteName: freshName)!,
                                 keychain: InMemoryKeychain())
        let result = try fresh.importDictionaryCSV(csv)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(Set(fresh.dictionaryEntries.map(\.word)), ["Grafana", "Kubernetes"])
    }

    // MARK: Migration

    func testMigrationFoldsLegacyStores() {
        let migrated = DictionaryEntry.migrate(
            vocabulary: ["Grafana", "grafana", "  ", "!!!", "Kubernetes"],
            replacements: ["my email": "me@example.com", "koobernetes": "Kubernetes"])
        // "grafana" dup + blank + punctuation dropped; "koobernetes"→Kubernetes
        // upgrades the word-only Kubernetes entry in place.
        XCTAssertEqual(migrated.map(\.word),
                       ["Grafana", "Kubernetes", "me@example.com"])
        XCTAssertNil(migrated[0].correction)
        XCTAssertEqual(migrated[1].correction, "koobernetes")
        XCTAssertEqual(migrated[2].correction, "my email")
        XCTAssertTrue(migrated.allSatisfy { $0.source == .manual })
    }

    func testInitMigratesLegacyOnceThenRetiresTheOldStores() {
        defaults.set(["Grafana"], forKey: "oliv.vocabulary")
        defaults.set(["my email": "me@example.com"], forKey: "oliv.replacements")
        let s = makeSettings()
        XCTAssertEqual(s.dictionaryEntries.map(\.word), ["Grafana", "me@example.com"])
        // The old stores are gone (they would resurrect deleted entries)…
        XCTAssertNil(defaults.object(forKey: "oliv.vocabulary"))
        XCTAssertNil(defaults.object(forKey: "oliv.replacements"))
        // …but a recovery copy is kept.
        let backup = try? JSONSerialization.jsonObject(
            with: defaults.data(forKey: "oliv.legacyDictionaryBackup") ?? Data()) as? [String: Any]
        XCTAssertEqual(backup?["vocabulary"] as? [String], ["Grafana"])
        // Deleting a migrated entry sticks across relaunch.
        s.removeDictionaryEntry(s.dictionaryEntries[0].id)
        XCTAssertEqual(makeSettings().dictionaryEntries.map(\.word), ["me@example.com"])
    }

    func testLegacyStoresLeftBesideAnExistingDictionaryAreRetired() {
        // Builds before the retirement kept both; the entries are the truth.
        defaults.set(try! JSONEncoder().encode([DictionaryEntry(word: "Kept")]), forKey: "oliv.dictionaryEntries")
        defaults.set(["Deleted earlier"], forKey: "oliv.vocabulary")
        XCTAssertEqual(makeSettings().dictionaryEntries.map(\.word), ["Kept"])
        XCTAssertNil(defaults.object(forKey: "oliv.vocabulary"))
    }

    // MARK: Ordering + wire derivation

    func testStarredOrderingAndDisabledExcluded() {
        let entries = [
            DictionaryEntry(word: "plain"),
            DictionaryEntry(word: "Starred", starred: true),
            DictionaryEntry(word: "Off", enabled: false, starred: true),
            DictionaryEntry(word: "fix", correction: "fiks", starred: true),
        ]
        // Vocabulary for servers without sync: starred-first, disabled excluded.
        XCTAssertEqual(DictionaryEntry.vocabulary(from: entries), ["Starred", "fix", "plain"])
    }

    func testReplacementsForServersWithoutSync() {
        let entries = [
            DictionaryEntry(word: "Grafana", correction: "grafannah"),
            DictionaryEntry(word: "Shadow", correction: "grafannah"),
            DictionaryEntry(word: "Off", correction: "off", enabled: false),
        ]
        XCTAssertEqual(DictionaryEntry.replacements(from: entries), ["grafannah": "Grafana"],
                       "first entry owns a phrase; disabled entries never reach the wire")
    }

    func testDedupeMatchesTheServerRule() {
        XCTAssertEqual(DictionaryEntry.dedupeKey(for: " Koolify "), DictionaryEntry.dedupeKey(for: "KOOLIFY"))
        // Anything containing Thai compares exactly, like the server.
        XCTAssertNotEqual(DictionaryEntry.dedupeKey(for: "API ไทย"), DictionaryEntry.dedupeKey(for: "api ไทย"))
    }

    // MARK: Persistence

    func testDictionaryPersistsAndAutoLearnDefaultsOff() {
        let s = makeSettings()
        XCTAssertFalse(s.dictionaryAutoLearn, "auto-learn defaults OFF")
        s.addDictionaryEntry(word: "Grafana", correction: "grafannah", source: .import)
        s.dictionaryEntries[0].starred = true
        s.dictionaryEntries[0].usageCount = 3
        s.dictionaryAutoLearn = true

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.dictionaryEntries.count, 1)
        XCTAssertEqual(reloaded.dictionaryEntries[0].word, "Grafana")
        XCTAssertEqual(reloaded.dictionaryEntries[0].correction, "grafannah")
        XCTAssertTrue(reloaded.dictionaryEntries[0].starred)
        XCTAssertEqual(reloaded.dictionaryEntries[0].usageCount, 3)
        XCTAssertEqual(reloaded.dictionaryEntries[0].source, .import)
        XCTAssertTrue(reloaded.dictionaryAutoLearn)
    }
}
