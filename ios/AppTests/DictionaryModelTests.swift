import Foundation
import XCTest
import OlivCore
@testable import Oliv

/// AppModel's Dictionary: editing, migration from the old settings, request
/// options, and sync with the server (see oliv-server docs/DICTIONARY.md).
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

    func fail(with error: OlivError?) { failure = error }

    func addFromAnotherDevice(_ entry: DictionaryEntry) {
        entries.append(entry)
        revision += 1
    }

    func dictionary(ops: [DictionaryOp]?) async throws -> DictionarySnapshot {
        calls += 1
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
