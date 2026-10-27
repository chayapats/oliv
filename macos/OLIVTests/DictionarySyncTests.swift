// DictionarySync tests: edits become queued operations, the first sync merges
// local entries, snapshots replace the list without echoing back as edits,
// offline queues survive, and servers without sync fall back cleanly.
// Hermetic: throwaway UserDefaults and an in-memory fake server.

import XCTest
@testable import OLIV

/// A server that keeps entries the way oliv-server does (ops in order, last
/// writer wins, identity duplicates rejected).
final class FakeDictionaryServer: DictionaryRemote, @unchecked Sendable {
    var entries: [DictionaryEntry] = []
    var revision = 0
    var calls: [[DictionaryOp]?] = []
    var failure: Error?
    /// Runs while a request is "in flight" (to simulate concurrent edits).
    var duringRequest: (() async -> Void)?

    func dictionary(ops: [DictionaryOp]?) async throws -> DictionarySnapshot {
        calls.append(ops)
        if let failure { throw failure }
        await duringRequest?()
        duringRequest = nil
        var rejected: [DictionarySnapshot.Rejection] = []
        var changed = false
        for op in ops ?? [] {
            switch op {
            case .delete(let id):
                let before = entries.count
                entries.removeAll { $0.id == id }
                changed = changed || entries.count != before
            case .upsert(let entry):
                if entries.contains(where: { $0.id != entry.id && $0.dedupeKey() == entry.dedupeKey() }) {
                    rejected.append(.init(id: entry.id, reason: "duplicate"))
                    continue
                }
                if let i = entries.firstIndex(where: { $0.id == entry.id }) {
                    if entries[i] != entry { entries[i] = entry; changed = true }
                } else {
                    entries.append(entry); changed = true
                }
            }
        }
        if changed { revision += 1 }
        return DictionarySnapshot(revision: revision, maxEntries: 1000, entries: entries, rejected: rejected)
    }
}

@MainActor
final class DictionarySyncTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var server: FakeDictionaryServer!

    override func setUpWithError() throws {
        suiteName = "oliv.tests.sync.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        server = FakeDictionaryServer()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSettings(apiEnabled: Bool = true) -> OLIVSettings {
        let s = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        if apiEnabled {
            s.olivAPIKey = "oliv-test-key"
            s.olivAPIEnabled = true
        }
        return s
    }

    private func makeSync() -> DictionarySync {
        let server = self.server!
        return DictionarySync(defaults: defaults, autoSync: false, makeRemote: { _ in server })
    }

    // MARK: Pure helpers

    func testDiffProducesUpsertsAndDeletesByID() {
        let a = DictionaryEntry(id: "a", word: "Grafana")
        let b = DictionaryEntry(id: "b", word: "Kafka")
        var a2 = a
        a2.starred = true
        var usage = b
        usage.usageCount = 9
        XCTAssertEqual(DictionaryOp.diff(from: [a, b], to: [a2, usage]), [.upsert(a2)],
                       "usageCount is device-local and never synced")
        XCTAssertEqual(DictionaryOp.diff(from: [a, b], to: [b]), [.delete(id: "a")])
    }

    func testCompactKeepsTheLastOperationPerEntry() {
        let a = DictionaryEntry(id: "a", word: "A")
        let ops: [DictionaryOp] = [.upsert(a), .upsert(DictionaryEntry(id: "b", word: "B")), .delete(id: "a")]
        XCTAssertEqual(DictionarySync.compact(ops), [.upsert(DictionaryEntry(id: "b", word: "B")), .delete(id: "a")])
    }

    func testWireFormMatchesTheServerContract() {
        let op = DictionaryOp.upsert(DictionaryEntry(id: "x", word: "SHA256", starred: true, usageCount: 4))
        let entry = op.wire["entry"] as? [String: Any]
        XCTAssertEqual(op.wire["op"] as? String, "upsert")
        XCTAssertEqual(entry?["id"] as? String, "x")
        XCTAssertEqual(entry?["source"] as? String, "manual")
        XCTAssertTrue(entry?["correction"] is NSNull)
        XCTAssertNil(entry?["usageCount"])
        XCTAssertEqual(DictionaryOp.delete(id: "x").wire as? [String: String], ["op": "delete", "id": "x"])
    }

    // MARK: Sync

    func testFirstSyncUploadsLocalEntriesAndAdoptsTheServerCopy() async {
        let settings = makeSettings()
        settings.addDictionaryEntry(word: "SHA256", correction: nil)
        server.entries = [DictionaryEntry(id: "phone", word: "Koolify", correction: "คูลิฟาย")]
        let sync = makeSync()
        sync.attach(to: settings)
        await sync.syncNow()

        XCTAssertEqual(Set(settings.dictionaryEntries.map(\.word)), ["SHA256", "Koolify"])
        XCTAssertEqual(server.entries.count, 2)
        XCTAssertTrue(sync.state.uploadedLocal)
        XCTAssertTrue(sync.serverAppliesDictionary)
        XCTAssertTrue(sync.state.pending.isEmpty, "the server copy is not echoed back as edits")
        guard case .synced = sync.status else { return XCTFail("\(sync.status)") }
    }

    func testSwitchingAccountsUploadsLocalEntriesInsteadOfAdoptingTheNewServer() async {
        let settings = makeSettings()
        settings.addDictionaryEntry(word: "SHA256", correction: nil)
        let first = server!
        let second = FakeDictionaryServer()
        second.entries = [DictionaryEntry(id: "other", word: "Koolify")]
        var current = first
        let sync = DictionarySync(defaults: defaults, autoSync: false, makeRemote: { _ in current })
        sync.attach(to: settings)
        await sync.syncNow()
        XCTAssertEqual(first.entries.map(\.word), ["SHA256"])

        // Another key (another account or server): this Mac's entries must be
        // merged into it, not replaced by its copy.
        settings.olivAPIKey = "oliv-other-key"
        current = second
        await sync.syncNow()
        XCTAssertEqual(Set(settings.dictionaryEntries.map(\.word)), ["SHA256", "Koolify"])
        XCTAssertEqual(Set(second.entries.map(\.word)), ["SHA256", "Koolify"])
        XCTAssertEqual(sync.state.revision, second.revision)

        // The state survives relaunch with its account, so a restart does not re-upload.
        let relaunched = DictionarySync(defaults: defaults, autoSync: false, makeRemote: { _ in second })
        relaunched.attach(to: settings)
        let calls = second.calls.count
        await relaunched.syncNow()
        XCTAssertEqual(second.calls.count, calls + 1)
        XCTAssertNil(second.calls.last!, "nothing to upload after a relaunch on the same account")
        let stored = String(decoding: defaults.data(forKey: DictionarySync.stateKey) ?? Data(), as: UTF8.self)
        XCTAssertFalse(stored.contains("oliv-other-key"), "only a hash of the key is persisted")
    }

    func testEditsAreQueuedAndSentAsOperations() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        await sync.syncNow()

        settings.addDictionaryEntry(word: "Grafana", correction: "grafannah")
        XCTAssertEqual(sync.state.pending.count, 1)
        await sync.syncNow()
        XCTAssertEqual(server.entries.map(\.word), ["Grafana"])
        XCTAssertTrue(sync.state.pending.isEmpty)

        settings.removeDictionaryEntry(settings.dictionaryEntries[0].id)
        await sync.syncNow()
        XCTAssertTrue(server.entries.isEmpty)
        XCTAssertEqual(server.calls.last??.count, 1)
    }

    func testOfflineEditsWaitAndSurviveRelaunch() async {
        let settings = makeSettings()
        server.failure = OLIVAPIError.network
        let sync = makeSync()
        sync.attach(to: settings)
        settings.addDictionaryEntry(word: "Grafana", correction: nil)
        await sync.syncNow()
        XCTAssertEqual(sync.status, .waiting)

        // A new process reads the same queue and delivers it once online.
        server.failure = nil
        let relaunched = makeSync()
        XCTAssertEqual(relaunched.state.pending.count, 1)
        relaunched.attach(to: settings)
        await relaunched.syncNow()
        XCTAssertEqual(server.entries.map(\.word), ["Grafana"])
    }

    func testEditsDuringAnExchangeAreKeptAndSentNext() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        await sync.syncNow()
        settings.addDictionaryEntry(word: "First", correction: nil)
        server.duringRequest = { @MainActor in
            settings.addDictionaryEntry(word: "Second", correction: nil)
        }
        await sync.syncNow()
        XCTAssertEqual(Set(server.entries.map(\.word)), ["First", "Second"], "the second edit followed")
        XCTAssertEqual(Set(settings.dictionaryEntries.map(\.word)), ["First", "Second"])
        XCTAssertTrue(sync.state.pending.isEmpty)
    }

    func testRejectedDuplicatesAreReported() async {
        let settings = makeSettings()
        server.entries = [DictionaryEntry(id: "phone", word: "Grafana")]
        server.revision = 1
        let sync = makeSync()
        sync.attach(to: settings)
        await sync.syncNow()
        // Another device added the same word meanwhile, under a different id.
        settings.dictionaryEntries.append(DictionaryEntry(id: "mac", word: "grafana"))
        await sync.syncNow()
        XCTAssertEqual(sync.rejectedWords, ["grafana"])
        XCTAssertEqual(settings.dictionaryEntries.map(\.id), ["phone"], "the server copy wins")
    }

    func testAnOlderServerKeepsTheDictionaryLocal() async {
        let settings = makeSettings()
        server.failure = OLIVAPIError.unsupported
        let sync = makeSync()
        sync.attach(to: settings)
        settings.addDictionaryEntry(word: "Grafana", correction: nil)
        await sync.syncNow()
        XCTAssertEqual(sync.status, .unsupported)
        XCTAssertFalse(sync.serverAppliesDictionary, "requests keep derived vocabulary")
        XCTAssertTrue(sync.state.pending.isEmpty)
        XCTAssertEqual(settings.dictionaryEntries.map(\.word), ["Grafana"], "nothing local is lost")
    }

    func testNoAPIKeyMeansLocalOnly() async {
        let settings = makeSettings(apiEnabled: false)
        let sync = makeSync()
        sync.attach(to: settings)
        await sync.syncNow()
        XCTAssertEqual(sync.status, .localOnly)
        XCTAssertTrue(server.calls.isEmpty)
        XCTAssertFalse(sync.serverAppliesDictionary)
    }

    func testRejectedKeyNeedsTheUser() async {
        let settings = makeSettings()
        server.failure = OLIVAPIError.http(401)
        let sync = makeSync()
        sync.attach(to: settings)
        await sync.syncNow()
        guard case .failed = sync.status else { return XCTFail("\(sync.status)") }
    }

    func testSnapshotParsing() throws {
        let snap = try DictionarySnapshot([
            "revision": 4, "max_entries": 1000,
            "entries": [["id": "a", "word": "เจนจิรา", "correction": "เจนจิลา", "enabled": true,
                         "starred": false, "source": "autoLearn"]],
            "rejected": [["index": 0, "id": "b", "reason": "limit"]],
        ])
        XCTAssertEqual(snap.revision, 4)
        XCTAssertEqual(snap.entries.first?.source, .autoLearn)
        XCTAssertEqual(snap.rejected, [.init(id: "b", reason: "limit")])
        XCTAssertThrowsError(try DictionarySnapshot(["entries": []]), "revision is required")
    }
}
