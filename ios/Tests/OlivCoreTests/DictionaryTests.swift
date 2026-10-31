import Foundation
import XCTest
@testable import OlivCore

final class DictionaryTests: XCTestCase {
    func testFieldsAndIdentityFollowTheServerRules() {
        XCTAssertEqual(DictionaryEntry.clean("  Grafana "), "Grafana")
        XCTAssertEqual(DictionaryEntry.clean("บางแค"), "บางแค")
        for bad in ["", "   ", "!!!", String(repeating: "ก", count: 101)] {
            XCTAssertNil(DictionaryEntry.clean(bad), bad)
        }
        XCTAssertEqual(DictionaryEntry(word: "Koolify").identity, DictionaryEntry(word: "KOOLIFY").identity)
        XCTAssertNotEqual(DictionaryEntry(word: "API ไทย").identity, DictionaryEntry(word: "api ไทย").identity)
        XCTAssertNotEqual(DictionaryEntry(word: "SHA256").identity,
                          DictionaryEntry(word: "SHA256", correction: "ชาสองห้าหก").identity)
    }

    func testDiffCompactAndApply() {
        let a = DictionaryEntry(id: "a", word: "A")
        var a2 = a
        a2.starred = true
        let b = DictionaryEntry(id: "b", word: "B")
        XCTAssertEqual(DictionaryOp.diff(from: [a, b], to: [a2]), [.upsert(a2), .delete(id: "b")])
        XCTAssertEqual(DictionaryOp.compact([.upsert(a), .upsert(b), .delete(id: "a")]), [.upsert(b), .delete(id: "a")])
        XCTAssertEqual(DictionaryOp.apply([.upsert(a2), .delete(id: "b"), .upsert(b)], to: [a, b]).map(\.id), ["a", "b"])
    }

    func testFirstSyncUploadsThenAcknowledgesTheServerCopy() {
        var book = DictionaryBook(entries: [DictionaryEntry(id: "mine", word: "SHA256")])
        XCTAssertEqual(book.outgoing(), [.upsert(DictionaryEntry(id: "mine", word: "SHA256"))])
        book.acknowledge(DictionarySnapshot(revision: 3, entries: [
            DictionaryEntry(id: "mine", word: "SHA256"), DictionaryEntry(id: "phone", word: "Koolify"),
        ]))
        XCTAssertEqual(book.entries.map(\.id), ["mine", "phone"])
        XCTAssertEqual(book.revision, 3)
        XCTAssertTrue(book.serverAppliesDictionary)
        XCTAssertNil(book.outgoing(), "nothing left to send: just fetch")
    }

    func testEditsDuringAnExchangeStayQueued() {
        var book = DictionaryBook()
        book.acknowledge(DictionarySnapshot(revision: 1, entries: []))
        let first = DictionaryEntry(id: "1", word: "First")
        book.edit([first])
        XCTAssertEqual(book.outgoing(), [.upsert(first)])
        // The user edits the same entry while the request is in flight.
        var renamed = first
        renamed.word = "First!"
        book.edit([renamed])
        book.acknowledge(DictionarySnapshot(revision: 2, entries: [first]))
        XCTAssertEqual(book.entries, [renamed], "the newer local edit is replayed on top")
        XCTAssertEqual(book.pending, [.upsert(renamed)])
    }

    func testFailuresKeepEverythingAndOlderServersStayLocal() {
        var book = DictionaryBook()
        book.edit([DictionaryEntry(id: "1", word: "Grafana")])
        _ = book.outgoing()
        book.exchangeFailed()
        XCTAssertEqual(book.pending.count, 1)
        book.serverUnsupported()
        XCTAssertFalse(book.serverAppliesDictionary)
        XCTAssertTrue(book.pending.isEmpty)
        XCTAssertEqual(book.entries.map(\.word), ["Grafana"])
    }

    func testDerivedOptionsForServersWithoutSync() {
        let book = DictionaryBook(entries: [
            DictionaryEntry(word: "plain"),
            DictionaryEntry(word: "Star", starred: true),
            DictionaryEntry(word: "Off", correction: "off", enabled: false),
            DictionaryEntry(word: "Grafana", correction: "กราฟาน่า"),
            DictionaryEntry(word: "Shadow", correction: "กราฟาน่า"),
        ])
        XCTAssertEqual(book.derivedVocabulary, ["Star", "plain", "Grafana", "Shadow"])
        XCTAssertEqual(book.derivedReplacements.map(\.spoken), ["กราฟาน่า"])
        XCTAssertEqual(book.derivedReplacements.first?.written, "Grafana")
    }

    func testMigrationFromTheOldSettings() {
        let long = String(repeating: "x", count: 101)
        let book = DictionaryBook.migrate(
            vocabularyText: "OLIV\n\n olive \nOLIV\n!!!\n\(long)",
            replacements: [ReplacementRule(spoken: "กราฟาน่า", written: "Grafana"),
                           ReplacementRule(spoken: "remove", written: ""),
                           ReplacementRule(spoken: "and", written: "&")])
        XCTAssertEqual(book.entries.map(\.word), ["OLIV", "olive", "Grafana"])
        XCTAssertEqual(book.entries.last?.correction, "กราฟาน่า")
        // What an entry can't hold keeps working, on any server.
        XCTAssertEqual(book.olderVocabulary, ["!!!", long])
        XCTAssertEqual(book.olderRules.map(\.spoken), ["remove", "and"])
        var synced = book
        _ = synced.outgoing()
        synced.acknowledge(DictionarySnapshot(revision: 1, entries: book.entries))
        XCTAssertEqual(synced.requestVocabulary, ["!!!", long])
        XCTAssertEqual(synced.requestReplacements.map(\.written), ["", "&"])
    }

    func testFieldsAreMeasuredAsTheServerMeasuresThem() {
        XCTAssertNotNil(DictionaryEntry.clean(String(repeating: "e\u{301}", count: 50)))
        XCTAssertNil(DictionaryEntry.clean(String(repeating: "e\u{301}", count: 51)), "102 scalars")
        XCTAssertNil(DictionaryEntry.clean("\u{301}"), "a mark alone is not a letter")
        XCTAssertEqual(DictionaryEntry.clean(" บางแค "), "บางแค")
        XCTAssertEqual(DictionaryEntry.clean("๑"), "๑")
    }

    func testALargeQueueGoesInBatchesTheServerAccepts() {
        let entries = (0...DictionaryBook.maxOpsPerRequest).map { DictionaryEntry(id: "\($0)", word: "w\($0)") }
        var book = DictionaryBook(entries: entries)
        XCTAssertEqual(book.outgoing()?.count, DictionaryBook.maxOpsPerRequest)
        book.acknowledge(DictionarySnapshot(revision: 1, entries: Array(entries.dropLast())))
        XCTAssertEqual(book.pending.count, 1, "only what was sent is acknowledged")
        XCTAssertEqual(book.entries.count, entries.count)
        XCTAssertEqual(book.outgoing(), [.upsert(entries[entries.count - 1])])
        book.acknowledge(DictionarySnapshot(revision: 2, entries: entries))
        XCTAssertNil(book.outgoing())
    }

    func testAFailedFirstSyncStillUploadsEverything() {
        var book = DictionaryBook(entries: [DictionaryEntry(id: "a", word: "A")])
        XCTAssertEqual(book.outgoing()?.count, 1)
        book.exchangeFailed()
        XCTAssertEqual(book.outgoing()?.count, 1)
    }

    func testANewConnectionUploadsEverythingAgain() {
        let word = DictionaryEntry(id: "a", word: "A")
        var book = DictionaryBook(entries: [word])
        _ = book.outgoing()
        book.acknowledge(DictionarySnapshot(revision: 5, entries: [word]))
        book.connectionChanged()
        XCTAssertFalse(book.serverAppliesDictionary)
        XCTAssertEqual(book.revision, 0)
        XCTAssertEqual(book.outgoing(), [.upsert(word)])
    }

    func testRequestsStayWithinTheLimitsOfAnOlderServer() throws {
        let tooLong = String(repeating: "ก", count: 100)
        let words = (0..<OlivOptions.maximumEntries + 5).map { DictionaryEntry(word: "w\($0)", correction: "s\($0)") }
        let book = DictionaryBook(entries: [DictionaryEntry(word: tooLong, correction: "x")] + words)
        let options = OlivOptions(vocabulary: book.requestVocabulary, replacements: book.requestReplacements)
        XCTAssertEqual(options.vocabulary.count, OlivOptions.maximumEntries)
        XCTAssertEqual(options.replacements.count, OlivOptions.maximumEntries)
        XCTAssertFalse(options.vocabulary.contains(tooLong))
        try options.validateServerLimits()
        try options.validate()
    }

    func testBookPersistsWithoutTheInFlightMarker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DictionaryBookStore(directory: directory)
        XCTAssertFalse(store.exists)
        var book = DictionaryBook()
        book.edit([DictionaryEntry(id: "1", word: "Grafana")])
        _ = book.outgoing()
        try store.save(book)
        var loaded = try store.load()
        XCTAssertEqual(loaded.pending.count, 1)
        // A request lost to a crash is simply sent again.
        XCTAssertEqual(loaded.outgoing()?.count, 1)
    }

    func testSnapshotDecoding() throws {
        let snapshot = try JSONDecoder().decode(DictionarySnapshot.self, from: Data(#"""
        {"ok":true,"revision":4,"max_entries":1000,"rejected":[{"index":0,"id":"b","reason":"limit"}],
         "entries":[{"id":"a","word":"เจนจิรา","correction":"เจนจิลา","enabled":true,"starred":false,"source":"autoLearn","updated_at":1}]}
        """#.utf8))
        XCTAssertEqual(snapshot.revision, 4)
        XCTAssertEqual(snapshot.entries.first?.source, .autoLearn)
        XCTAssertEqual(snapshot.rejected, [.init(id: "b", reason: "limit")])
        XCTAssertThrowsError(try JSONDecoder().decode(DictionarySnapshot.self, from: Data(#"{"entries":[]}"#.utf8)))
    }
}
