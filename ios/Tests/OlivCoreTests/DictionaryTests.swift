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
        let entries = DictionaryBook.migrate(
            vocabularyText: "OLIV\n\n olive \nOLIV\n!!!",
            replacements: [ReplacementRule(spoken: "กราฟาน่า", written: "Grafana"),
                           ReplacementRule(spoken: "remove", written: "")])
        XCTAssertEqual(entries.map(\.word), ["OLIV", "olive", "Grafana"])
        XCTAssertEqual(entries.last?.correction, "กราฟาน่า")
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
