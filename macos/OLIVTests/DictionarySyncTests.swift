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
    /// Upserts of new entries past this are rejected with `limit`.
    var limit = 1000
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
                } else if entries.count >= limit {
                    rejected.append(.init(id: entry.id, reason: "limit"))
                } else {
                    entries.append(entry); changed = true
                }
            }
        }
        if changed { revision += 1 }
        return DictionarySnapshot(revision: revision, maxEntries: limit, entries: entries, rejected: rejected)
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

    func testCompactMergesOnlyBackToBackOperationsOnOneEntry() {
        let a = DictionaryEntry(id: "a", word: "A")
        let b = DictionaryEntry(id: "b", word: "B")
        var a2 = a
        a2.starred = true
        XCTAssertEqual(DictionarySync.compact([.upsert(a), .upsert(a2), .upsert(b)]), [.upsert(a2), .upsert(b)])
        let interleaved: [DictionaryOp] = [.upsert(a), .upsert(b), .delete(id: "a")]
        XCTAssertEqual(DictionarySync.compact(interleaved), interleaved, "order across entries is kept")
    }

    func testRenameThenReuseTheOldWordSyncsBothEntries() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        settings.dictionaryEntries = [DictionaryEntry(id: "a", word: "Foo")]
        await sync.syncNow()
        // Offline burst: rename A, reuse its old word for B, then star A.
        settings.dictionaryEntries[0].word = "Bar"
        settings.dictionaryEntries.append(DictionaryEntry(id: "b", word: "Foo"))
        settings.dictionaryEntries[0].starred = true
        await sync.syncNow()
        XCTAssertEqual(Set(server.entries.map(\.word)), ["Bar", "Foo"])
        XCTAssertEqual(Set(settings.dictionaryEntries.map(\.word)), ["Bar", "Foo"])
        XCTAssertTrue(sync.rejectedWords.isEmpty)
    }

    func testAFullAccountKeepsRefusedEntriesOnThisMac() async {
        let settings = makeSettings()
        server.limit = 1
        let sync = makeSync()
        sync.attach(to: settings)
        settings.addDictionaryEntry(word: "Grafana", correction: nil)
        await sync.syncNow()
        settings.addDictionaryEntry(word: "Signature", correction: "my signature")
        await sync.syncNow()
        XCTAssertEqual(server.entries.map(\.word), ["Grafana"])
        XCTAssertEqual(settings.dictionaryEntries.map(\.word), ["Grafana", "Signature"], "nothing is lost")
        XCTAssertEqual(settings.dictionaryEntries.last?.correction, "my signature")
        XCTAssertEqual(sync.rejectedWords, ["Signature"])
        XCTAssertFalse(sync.serverAppliesDictionary, "requests carry the full dictionary meanwhile")

        // A later sync (another device's edit) still keeps it; so does relaunch.
        await sync.syncNow()
        XCTAssertEqual(settings.dictionaryEntries.map(\.word), ["Grafana", "Signature"])
        let relaunched = makeSync()
        relaunched.attach(to: settings)
        XCTAssertTrue(relaunched.state.held.isEmpty, "offered again at launch")
        server.limit = 10
        await relaunched.syncNow()
        XCTAssertEqual(server.entries.map(\.word), ["Grafana", "Signature"])
        XCTAssertTrue(relaunched.rejectedWords.isEmpty)
    }

    func testDeletionsSurviveAKeyChangeAndAnUnsupportedSpell() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        settings.addDictionaryEntry(word: "Kept", correction: nil)
        settings.addDictionaryEntry(word: "Gone", correction: nil)
        await sync.syncNow()
        // Deleted while the key was rejected, then the key is replaced.
        server.failure = OLIVAPIError.http(401)
        settings.dictionaryEntries.removeAll { $0.word == "Gone" }
        await sync.syncNow()
        server.failure = nil
        settings.olivAPIKey = "oliv-rotated-key"
        await sync.syncNow()
        XCTAssertEqual(server.entries.map(\.word), ["Kept"])
        XCTAssertEqual(settings.dictionaryEntries.map(\.word), ["Kept"])

        // Deleted while the server briefly lost sync support (404), which recovers.
        settings.addDictionaryEntry(word: "Temp", correction: nil)
        await sync.syncNow()
        server.failure = OLIVAPIError.unsupported
        settings.dictionaryEntries.removeAll { $0.word == "Temp" }
        await sync.syncNow()
        XCTAssertEqual(sync.status, .unsupported)
        server.failure = nil
        await sync.syncNow()
        XCTAssertEqual(server.entries.map(\.word), ["Kept"])
        XCTAssertEqual(settings.dictionaryEntries.map(\.word), ["Kept"])
    }

    func testServerAppliesDictionaryOnlyWhenItHoldsThisMacsCopy() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        XCTAssertFalse(sync.serverAppliesDictionary, "not confirmed yet")
        await sync.syncNow()
        XCTAssertTrue(sync.serverAppliesDictionary)
        settings.addDictionaryEntry(word: "Grafana", correction: "grafannah")
        XCTAssertFalse(sync.serverAppliesDictionary, "an edit is still queued")
        await sync.syncNow()
        XCTAssertTrue(sync.serverAppliesDictionary)
        settings.olivAPIKey = "oliv-other-key"
        XCTAssertFalse(sync.serverAppliesDictionary, "another account has not been synced")
    }

    func testAnAnswerForTheOldAccountIsIgnored() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        settings.addDictionaryEntry(word: "Mine", correction: nil)
        await sync.syncNow()
        let other = FakeDictionaryServer()
        other.entries = [DictionaryEntry(id: "x", word: "Theirs")]
        // The key changes while the old account's request is in flight; its
        // (empty) answer must not replace the dictionary.
        server.entries = []
        let current = Box(server!)
        let switching = DictionarySync(defaults: defaults, autoSync: false, makeRemote: { _ in current.value })
        switching.attach(to: settings)
        server.duringRequest = { @MainActor in
            settings.olivAPIKey = "oliv-other-key"
            current.value = other
        }
        await switching.syncNow()
        XCTAssertEqual(Set(settings.dictionaryEntries.map(\.word)), ["Mine", "Theirs"])
        XCTAssertEqual(Set(other.entries.map(\.word)), ["Mine", "Theirs"])
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

    func testLocalOnlyEditsDoNotPileUpButDeletionsAfterSyncAreKept() async {
        let settings = makeSettings(apiEnabled: false)
        let sync = makeSync()
        sync.attach(to: settings)
        for i in 0..<20 { settings.addDictionaryEntry(word: "Word\(i)", correction: nil) }
        XCTAssertTrue(sync.state.pending.isEmpty, "never synced: nothing to queue")

        // Synced once, then the key is removed and an entry deleted: only the
        // deletion is remembered, and the next sync re-uploads the rest.
        settings.olivAPIKey = "oliv-test-key"
        settings.olivAPIEnabled = true
        await sync.syncNow()
        XCTAssertEqual(server.entries.count, 20)
        settings.olivAPIEnabled = false
        settings.dictionaryEntries.removeAll { $0.word == "Word0" }
        settings.addDictionaryEntry(word: "Offline", correction: nil)
        XCTAssertEqual(sync.state.pending, [.delete(id: server.entries[0].id)])
        settings.olivAPIEnabled = true
        await sync.syncNow()
        XCTAssertFalse(server.entries.contains { $0.word == "Word0" })
        XCTAssertTrue(server.entries.contains { $0.word == "Offline" })
    }

    func testTurningTheAPIOffAndOnDuringARequestKeepsEveryEdit() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        settings.addDictionaryEntry(word: "First", correction: nil)
        await sync.syncNow()
        settings.addDictionaryEntry(word: "Second", correction: nil)
        // Mid-request: API off, an edit and a delete, API back on; then the
        // (late) answer for the same account lands.
        server.duringRequest = { @MainActor in
            settings.olivAPIEnabled = false
            settings.addDictionaryEntry(word: "Third", correction: nil)
            settings.dictionaryEntries.removeAll { $0.word == "First" }
            settings.olivAPIEnabled = true
        }
        await sync.syncNow()
        XCTAssertEqual(Set(settings.dictionaryEntries.map(\.word)), ["Second", "Third"])
        XCTAssertEqual(Set(server.entries.map(\.word)), ["Second", "Third"])
        XCTAssertTrue(sync.state.pending.isEmpty)
    }

    func testANormalizationOnlyEditSyncsBothWays() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        settings.addDictionaryEntry(word: "Résumé", correction: "re\u{301}zume")
        await sync.syncNow()
        let nfc = "r\u{E9}zume", id = settings.dictionaryEntries[0].id
        // Out: an NFD → NFC edit is an edit, and survives a later refresh.
        settings.dictionaryEntries[0].correction = nfc
        XCTAssertEqual(sync.state.pending.count, 1)
        await sync.syncNow()
        server.entries.append(DictionaryEntry(id: "other", word: "Kafka"))
        await sync.syncNow()
        XCTAssertEqual(settings.dictionaryEntries.first { $0.id == id }?.correction.map { Array($0.unicodeScalars) },
                       Array(nfc.unicodeScalars))
        // In: a server change that only renormalizes is applied locally.
        let nfd = "re\u{301}zume"
        server.entries[0].correction = nfd
        server.revision += 1
        await sync.syncNow()
        XCTAssertEqual(settings.dictionaryEntries.first { $0.id == id }?.correction.map { Array($0.unicodeScalars) },
                       Array(nfd.unicodeScalars))
    }

    func testAQueuedEditMissingLocallyAfterACrashIsReplayed() async {
        let settings = makeSettings()
        let sync = makeSync()
        sync.attach(to: settings)
        await sync.syncNow()
        settings.addDictionaryEntry(word: "Grafana", correction: nil)
        XCTAssertEqual(sync.state.pending.count, 1)
        // Simulate dying after the outbox write but before the dictionary write.
        defaults.set(try? JSONEncoder().encode([DictionaryEntry]()), forKey: "oliv.dictionaryEntries")
        let relaunchedSettings = makeSettings()
        XCTAssertTrue(relaunchedSettings.dictionaryEntries.isEmpty)
        let relaunched = makeSync()
        relaunched.attach(to: relaunchedSettings)
        XCTAssertEqual(relaunchedSettings.dictionaryEntries.map(\.word), ["Grafana"])
        // Even if the account changes before the next sync, the upload has it.
        relaunchedSettings.olivAPIKey = "oliv-other-key"
        await relaunched.syncNow()
        XCTAssertEqual(server.entries.map(\.word), ["Grafana"])
    }

    func testARefusalNeverOverridesANewerEdit() async {
        let settings = makeSettings()
        server.limit = 1
        let sync = makeSync()
        sync.attach(to: settings)
        settings.addDictionaryEntry(word: "Existing", correction: nil)
        await sync.syncNow()
        // Refused for space, but deleted while the request was in flight.
        settings.addDictionaryEntry(word: "Old", correction: nil)
        server.duringRequest = { @MainActor in settings.dictionaryEntries.removeAll { $0.word == "Old" } }
        await sync.syncNow()
        XCTAssertEqual(settings.dictionaryEntries.map(\.word), ["Existing"])
        XCTAssertTrue(sync.state.held.isEmpty)

        // Added then deleted in the same offline batch: refused, but gone.
        server.failure = OLIVAPIError.network
        settings.addDictionaryEntry(word: "Abandoned", correction: nil)
        await sync.syncNow()
        settings.dictionaryEntries.removeAll { $0.word == "Abandoned" }
        settings.addDictionaryEntry(word: "Other", correction: nil)
        server.failure = nil
        await sync.syncNow()
        XCTAssertFalse(settings.dictionaryEntries.contains { $0.word == "Abandoned" })
        XCTAssertEqual(sync.state.held.map(\.word), ["Other"], "the live refusal is still held")

        // A duplicate refusal edited in flight: the newer word wins.
        server.limit = 10
        server.entries.append(DictionaryEntry(id: "phone", word: "Taken"))
        settings.addDictionaryEntry(word: "Taken2", correction: nil)
        let id = settings.dictionaryEntries.last!.id
        settings.dictionaryEntries[settings.dictionaryEntries.count - 1].word = "taken"
        server.duringRequest = { @MainActor in
            if let i = settings.dictionaryEntries.firstIndex(where: { $0.id == id }) {
                settings.dictionaryEntries[i].word = "New"
            }
        }
        await sync.syncNow()
        XCTAssertTrue(settings.dictionaryEntries.contains { $0.word == "New" })
        XCTAssertTrue(server.entries.contains { $0.word == "New" })
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

/// A mutable reference for fakes swapped mid-test.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
