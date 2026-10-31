import Foundation
import XCTest
import OlivCore
@testable import Oliv

/// AppModel's Dictionary: editing, migration from the old settings, request
/// options, and sync with the server (see server/docs/DICTIONARY.md).
final class DictionaryModelTests: XCTestCase {
    @MainActor
    func testEditingValidatesAndDeduplicates() throws {
        let h = try DictionaryHarness()
        defer { h.removeDirectory() }
        XCTAssertNil(h.model.saveDictionaryEntry(word: " Grafana ", correction: "กราฟาน่า"))
        XCTAssertNotNil(h.model.saveDictionaryEntry(word: "grafana", correction: "กราฟาน่า"), "duplicate")
        XCTAssertNotNil(h.model.saveDictionaryEntry(word: "!!!", correction: nil))
        XCTAssertNil(h.model.saveDictionaryEntry(word: "Grafana", correction: nil), "word-only is a separate entry")
        let id = try XCTUnwrap(h.model.dictionary.entries.first?.id)
        XCTAssertNil(h.model.saveDictionaryEntry(id: id, word: "Grafana", correction: "กราฟฟาน่า"))
        XCTAssertEqual(h.model.dictionary.entries.first?.correction, "กราฟฟาน่า")
        h.model.setDictionaryEntry(id, starred: true, enabled: false)
        XCTAssertEqual(h.model.dictionary.entries.first?.starred, true)
        h.model.removeDictionaryEntries([id])
        XCTAssertEqual(h.model.dictionary.entries.map(\.word), ["Grafana"])
        // Saved across relaunch.
        XCTAssertEqual(h.reopen().dictionary.entries.map(\.word), ["Grafana"])
    }

    @MainActor
    func testSyncUploadsAndTheServerThenAppliesTheDictionary() async throws {
        let h = try DictionaryHarness()
        defer { h.removeDirectory() }
        h.model.saveDictionaryEntry(word: "SHA256", correction: nil)
        // Before the server confirms sync, requests carry derived vocabulary.
        XCTAssertEqual(h.model.currentOptions.vocabulary, ["SHA256"])
        await h.model.syncDictionary()
        XCTAssertEqual(h.model.dictionarySyncStatus, .synced)
        let uploaded = await h.service.entries.map(\.word)
        XCTAssertEqual(uploaded, ["SHA256"])
        XCTAssertTrue(h.model.currentOptions.vocabulary.isEmpty, "the server applies its own copy")

        // Another device adds a word; the next reply's revision brings it here.
        await h.service.addFromAnotherDevice(DictionaryEntry(id: "phone", word: "Koolify"))
        await h.model.syncDictionary()
        XCTAssertEqual(Set(h.model.dictionary.entries.map(\.word)), ["SHA256", "Koolify"])
    }

    @MainActor
    func testOfflineEditsWaitAndOlderServersStayLocal() async throws {
        let h = try DictionaryHarness()
        defer { h.removeDirectory() }
        await h.service.fail(with: OlivError.networkUnavailable)
        h.model.saveDictionaryEntry(word: "Grafana", correction: nil)
        await h.model.syncDictionary()
        XCTAssertEqual(h.model.dictionarySyncStatus, .waiting)
        XCTAssertEqual(h.model.dictionary.pending.count, 1)

        await h.service.fail(with: OlivError.dictionaryUnsupported)
        await h.model.syncDictionary()
        XCTAssertEqual(h.model.dictionarySyncStatus, .unsupported)
        XCTAssertEqual(h.model.currentOptions.vocabulary, ["Grafana"], "older servers get derived vocabulary")
        XCTAssertEqual(h.model.dictionary.entries.map(\.word), ["Grafana"], "nothing local is lost")
    }

    @MainActor
    func testChangingConnectionCarriesTheWordsToTheNewServer() async throws {
        let h = try DictionaryHarness()
        defer { h.removeDirectory() }
        h.model.saveDictionaryEntry(word: "Grafana", correction: nil)
        await h.model.syncDictionary()
        XCTAssertEqual(h.model.dictionarySyncStatus, .synced)

        await h.service.reset()
        h.model.settings.serverURL = "https://other.example"
        h.model.saveSettings()
        XCTAssertEqual(h.model.currentOptions.vocabulary, ["Grafana"], "until the new server confirms sync")
        await h.model.syncDictionary()
        XCTAssertEqual(h.model.dictionary.entries.map(\.word), ["Grafana"])
        let uploaded = await h.service.entries.map(\.word)
        XCTAssertEqual(uploaded, ["Grafana"])

        // Saving the same connection again doesn't start over.
        h.model.saveSettings()
        let revision = h.model.dictionary.revision
        XCTAssertGreaterThan(revision, 0)
    }

    @MainActor
    func testAReplyFromTheOldConnectionIsIgnored() async throws {
        let h = try DictionaryHarness()
        defer { h.removeDirectory() }
        h.model.saveDictionaryEntry(word: "Grafana", correction: nil)
        await h.model.syncDictionary()
        await h.service.holdNextReply(returning: DictionarySnapshot(revision: 9, entries: []))
        let sync = Task { await h.model.syncDictionary() }
        while await !h.service.isHolding { await Task.yield() }

        await h.service.reset()
        h.model.settings.serverURL = "https://other.example"
        h.model.saveSettings()
        await h.service.release()
        await sync.value
        await h.model.syncDictionary()
        XCTAssertEqual(h.model.dictionary.entries.map(\.word), ["Grafana"], "not the old server's empty list")
        let uploaded = await h.service.entries.map(\.word)
        XCTAssertEqual(uploaded, ["Grafana"])
    }

    @MainActor
    func testAWorkingRequestSendsEditsThatWereWaiting() async throws {
        let h = try DictionaryHarness()
        defer { h.removeDirectory() }
        await h.model.syncDictionary()
        await h.service.fail(with: OlivError.networkUnavailable)
        h.model.saveDictionaryEntry(word: "Grafana", correction: nil)
        await h.model.syncDictionary()
        XCTAssertEqual(h.model.dictionary.pending.count, 1)

        await h.service.fail(with: nil)
        await h.model.cleanText("ok") // Answers with the revision already saved.
        let deadline = ContinuousClock.now + .seconds(5)
        while !h.model.dictionary.pending.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(h.model.dictionary.pending.isEmpty)
    }

    @MainActor
    func testADamagedDictionaryLeavesEverythingElseWorking() async throws {
        let h = try DictionaryHarness()
        defer { h.removeDirectory() }
        // The harness's own model finishes its first sync before the damage.
        await h.model.syncDictionary()
        try await Task.sleep(for: .milliseconds(100))
        let url = h.directory.appendingPathComponent("dictionary.json")
        let damaged = Data("not json".utf8)
        try damaged.write(to: url)

        let model = h.reopen()
        XCTAssertNotNil(model.message)
        await model.cleanText("still works")
        XCTAssertEqual(model.latest?.finalText, "still works")
        model.saveDictionaryEntry(word: "Grafana", correction: nil)
        await model.syncDictionary()
        XCTAssertEqual(model.dictionarySyncStatus, .localOnly)
        XCTAssertEqual(try Data(contentsOf: url), damaged, "kept for recovery")
    }

    @MainActor
    func testTheEditorStopsAtTheServersLimit() async throws {
        let h = try DictionaryHarness()
        defer { h.removeDirectory() }
        let entries = (0..<DictionaryBook.maxEntries).map { DictionaryEntry(id: "\($0)", word: "w\($0)") }
        try DictionaryBookStore(directory: h.directory).save(DictionaryBook(entries: entries))
        let model = h.reopen()
        XCTAssertNotNil(model.saveDictionaryEntry(word: "one more", correction: nil))
        XCTAssertNil(model.saveDictionaryEntry(id: "0", word: "renamed", correction: nil), "edits still work")
    }

    @MainActor
    func testWithoutAConnectionTheDictionaryIsLocalOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OlivDictionary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DictionaryTestService()
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(),
                             capture: FixtureAudioCapture(directory: directory), liveActivitiesEnabled: false,
                             clientFactory: { _ in service })
        model.saveDictionaryEntry(word: "Grafana", correction: nil)
        await model.syncDictionary()
        XCTAssertEqual(model.dictionarySyncStatus, .localOnly)
        let calls = await service.calls
        XCTAssertEqual(calls, 0)
    }
}

@MainActor
private struct DictionaryHarness {
    let directory: URL
    let service = DictionaryTestService()
    let credentials = MemoryCredentialStore(token: "fixture-token")
    let model: AppModel

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OlivDictionary-\(UUID())")
        model = Self.model(directory: directory, credentials: credentials, service: service)
        model.settings.serverURL = "https://oliv.example"
        model.saveSettings()
        XCTAssertNil(model.message)
    }

    func reopen() -> AppModel { Self.model(directory: directory, credentials: credentials, service: service) }

    private static func model(directory: URL, credentials: MemoryCredentialStore,
                              service: DictionaryTestService) -> AppModel {
        AppModel(directory: directory, credentials: credentials,
                 capture: FixtureAudioCapture(directory: directory), liveActivitiesEnabled: false,
                 clientFactory: { _ in service })
    }

    func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}

/// A server dictionary with the server semantics the app relies on.
private actor DictionaryTestService: OlivServing {
    private(set) var entries: [DictionaryEntry] = []
    private(set) var calls = 0
    private var revision = 0
    private var failure: OlivError?

    private var heldReply: DictionarySnapshot?
    private var waiting: CheckedContinuation<Void, Never>?
    var isHolding: Bool { waiting != nil }

    func fail(with error: OlivError?) { failure = error }

    /// Now talking to a server that has never seen this device.
    func reset() {
        entries = []
        revision = 0
    }

    func holdNextReply(returning snapshot: DictionarySnapshot) { heldReply = snapshot }

    func release() {
        waiting?.resume()
        waiting = nil
    }

    func addFromAnotherDevice(_ entry: DictionaryEntry) {
        entries.append(entry)
        revision += 1
    }

    func dictionary(ops: [DictionaryOp]?) async throws -> DictionarySnapshot {
        calls += 1
        if let held = heldReply {
            heldReply = nil
            await withCheckedContinuation { waiting = $0 }
            return held
        }
        if let failure { throw failure }
        if let ops, !ops.isEmpty {
            entries = DictionaryOp.apply(ops, to: entries)
            revision += 1
        }
        return DictionarySnapshot(revision: revision, entries: entries)
    }

    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply {
        DictationReply(finalText: "ok", dictionaryRevision: revision)
    }

    func clean(text: String, options: OlivOptions) async throws -> DictationReply {
        DictationReply(raw: text, finalText: text, dictionaryRevision: revision)
    }

    func health() async throws -> ServerHealth {
        try JSONDecoder().decode(ServerHealth.self, from: Data(#"{"ok":true}"#.utf8))
    }

    func verifyKey() async throws {}
}
