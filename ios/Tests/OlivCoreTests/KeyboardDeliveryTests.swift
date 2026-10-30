import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import OlivCore

final class KeyboardDeliveryTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let contextDigest = String(repeating: "a", count: 64)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OlivKeyboardTests-\(UUID())")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testDeliveryIsConsumedExactlyOnceAcrossStoreInstances() throws {
        let producer = try KeyboardDeliveryStore(directory: directory)
        let consumer = try KeyboardDeliveryStore(directory: directory)
        let lease = try focus(in: producer)
        let session = UUID()
        XCTAssertTrue(try producer.publish(text: "ส่งให้ทีม review", for: lease, sessionID: session, now: now))
        let delivery = try XCTUnwrap(consumer.consume(for: lease, now: now))
        XCTAssertEqual(delivery.sessionID, session)
        XCTAssertEqual(delivery.text, "ส่งให้ทีม review")
        XCTAssertEqual(delivery.target, lease)
        XCTAssertEqual(delivery.expiresAt.timeIntervalSince(delivery.createdAt), 60)
        XCTAssertNil(try producer.consume(for: lease, now: now))
        XCTAssertFalse(try producer.publish(text: "repeated", for: lease, sessionID: session, now: now))
        XCTAssertNil(try consumer.consume(for: lease, now: now))
    }

    func testConcurrentConsumersHaveOneWinner() throws {
        let stores = try (0..<8).map { _ in try KeyboardDeliveryStore(directory: directory) }
        let lease = try focus(in: stores[0])
        let time = now
        XCTAssertTrue(try stores[0].publish(text: "one delivery", for: lease, sessionID: UUID(), now: time))
        let results = ConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                if let delivery = try stores[index % stores.count].consume(for: lease, now: time) {
                    results.append(delivery.text)
                }
            } catch KeyboardDeliveryError.storageUnavailable {
                // Lock contention fails closed without blocking the keyboard.
            } catch { results.recordError() }
        }
        XCTAssertEqual(results.texts, ["one delivery"])
        XCTAssertEqual(results.errorCount, 0)
    }

    func testUnchangedFocusReadsDoNotReplaceOrModifyStateFile() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let lease = try focus(in: store)
        let file = directory.appendingPathComponent("keyboard-delivery.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: file.path)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        for _ in 0..<25 { XCTAssertEqual(try store.activeFocus(now: now), lease) }
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
    }

    func testContendedLockFailsClosedPromptly() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        _ = try focus(in: store)
        let lockFile = directory.appendingPathComponent("keyboard-delivery.lock")
        let descriptor = open(lockFile.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return XCTFail("Could not open test lock") }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let completion = expectation(description: "Contended read returns without waiting for unlock")
        let time = now
        DispatchQueue.global().async {
            do {
                _ = try store.activeFocus(now: time)
                XCTFail("Contended read must fail closed")
            } catch {
                XCTAssertEqual(error as? KeyboardDeliveryError, .storageUnavailable)
            }
            completion.fulfill()
        }
        let result = XCTWaiter.wait(for: [completion], timeout: 0.5)
        // Release even on regression so a blocked worker can finish.
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(result, .completed)
        XCTAssertNotNil(try store.activeFocus(now: now))
    }

    func testStaleFocusFailsClosedAndHasNoFutureTimestampTolerance() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let lease = try focus(in: store)
        XCTAssertEqual(try store.activeFocus(now: now), lease)
        XCTAssertNotNil(try store.activeFocus(now: now.addingTimeInterval(5.999)))
        XCTAssertNil(try store.activeFocus(now: now.addingTimeInterval(6)))
        XCTAssertFalse(try store.publish(text: "stale", for: lease, sessionID: UUID(), now: now.addingTimeInterval(6)))
        _ = try focus(in: store)
        XCTAssertNil(try store.activeFocus(now: now.addingTimeInterval(-0.001)))
    }

    func testExplicitVerifiedRefreshAllowsLongDictationWithOriginalSnapshot() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let snapshot = try focus(in: store)
        let completion = now.addingTimeInterval(120)
        let verified = try store.publishFocus(id: snapshot.id, documentID: snapshot.documentID,
            revision: snapshot.revision, contextHash: snapshot.contextHash, now: completion)
        XCTAssertGreaterThan(verified.updatedAt, snapshot.expiresAt)
        XCTAssertTrue(try store.publish(text: "long dictation", for: snapshot, sessionID: UUID(), now: completion))
        XCTAssertEqual(try store.consume(for: verified, now: completion)?.text, "long dictation")
    }

    func testDelayedHeartbeatAndOldInvalidationCannotReplaceNewView() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let old = try focus(in: store)
        let newer = try focus(in: store, time: now.addingTimeInterval(1))
        XCTAssertNil(try store.refreshFocus(old, now: now.addingTimeInterval(2)))
        try store.invalidateFocus(id: old.id, now: now.addingTimeInterval(2))
        XCTAssertEqual(try store.activeFocus(now: now.addingTimeInterval(2)), newer)
        XCTAssertFalse(try store.publish(text: "old field", for: old, sessionID: UUID(), now: now.addingTimeInterval(2)))
        let refreshed = try XCTUnwrap(store.refreshFocus(newer, now: now.addingTimeInterval(2)))
        XCTAssertEqual(refreshed.id, newer.id)
        XCTAssertEqual(refreshed.updatedAt, now.addingTimeInterval(2))
        XCTAssertNil(try store.refreshFocus(refreshed, now: now.addingTimeInterval(8)))
    }

    func testEveryFocusIdentityComponentMustMatch() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let target = try focus(in: store)
        let alternatives = [
            KeyboardFocusLease(id: UUID(), documentID: target.documentID, revision: target.revision, contextHash: contextDigest,
                               updatedAt: now, expiresAt: target.expiresAt),
            KeyboardFocusLease(id: target.id, documentID: UUID(), revision: target.revision, contextHash: contextDigest,
                               updatedAt: now, expiresAt: target.expiresAt),
            KeyboardFocusLease(id: target.id, documentID: target.documentID, revision: target.revision + 1, contextHash: contextDigest,
                               updatedAt: now, expiresAt: target.expiresAt),
            KeyboardFocusLease(id: target.id, documentID: target.documentID, revision: target.revision,
                               contextHash: String(repeating: "b", count: 64), updatedAt: now, expiresAt: target.expiresAt)
        ]
        XCTAssertTrue(try store.publish(text: "correct field only", for: target, sessionID: UUID(), now: now))
        for wrong in alternatives {
            XCTAssertFalse(try store.publish(text: "wrong field", for: wrong, sessionID: UUID(), now: now))
            XCTAssertNil(try store.consume(for: wrong, now: now))
        }
        XCTAssertEqual(try store.consume(for: target, now: now)?.text, "correct field only")
    }

    func testContextChangeAndInvalidationRemoveUnconsumedText() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let old = try focus(in: store)
        XCTAssertTrue(try store.publish(text: "before editing", for: old, sessionID: UUID(), now: now))
        let changed = try store.publishFocus(id: old.id, documentID: old.documentID, revision: old.revision + 1,
            contextHash: String(repeating: "b", count: 64), now: now)
        XCTAssertNil(try store.consume(for: old, now: now))
        XCTAssertNil(try store.consume(for: changed, now: now))
        XCTAssertThrowsError(try store.publishFocus(id: old.id, documentID: old.documentID,
            revision: old.revision, contextHash: old.contextHash, now: now))
        XCTAssertTrue(try store.publish(text: "after editing", for: changed, sessionID: UUID(), now: now))
        try store.invalidateFocus(id: changed.id, now: now)
        XCTAssertNil(try store.activeFocus(now: now))
        XCTAssertNil(try store.consume(for: changed, now: now))
    }

    func testCancellationBeforeOrAfterPublicationAndUnrelatedSessionIsolation() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let lease = try focus(in: store)
        let cancelled = UUID()
        try store.cancel(sessionID: cancelled, now: now)
        XCTAssertFalse(try store.publish(text: "cancelled", for: lease, sessionID: cancelled, now: now))
        let active = UUID()
        XCTAssertTrue(try store.publish(text: "active", for: lease, sessionID: active, now: now))
        try store.cancel(sessionID: cancelled, now: now)
        XCTAssertEqual(try store.consume(for: lease, now: now)?.text, "active")
        let next = UUID()
        XCTAssertTrue(try store.publish(text: "cancel after upload", for: lease, sessionID: next, now: now))
        try store.cancel(sessionID: next, now: now)
        XCTAssertNil(try store.consume(for: lease, now: now))
        XCTAssertFalse(try store.publish(text: "retry duplicate", for: lease, sessionID: next, now: now))
        XCTAssertEqual(try store.activeFocus(now: now), lease)
    }

    func testDeliveryExpiryEvenWhenFocusIsContinuouslyVerified() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let original = try focus(in: store)
        let session = UUID()
        XCTAssertTrue(try store.publish(text: "expires", for: original, sessionID: session, now: now))
        var current = original
        for second in stride(from: 5, through: 60, by: 5) {
            current = try store.publishFocus(id: original.id, documentID: original.documentID,
                revision: original.revision, contextHash: original.contextHash, now: now.addingTimeInterval(Double(second)))
        }
        XCTAssertNil(try store.consume(for: current, now: now.addingTimeInterval(60)))
        XCTAssertFalse(try store.publish(text: "expired replay", for: original, sessionID: session, now: now.addingTimeInterval(60)))
    }

    func testTextAndDigestBoundsRejectContextContentAndOversizedPayloads() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        XCTAssertThrowsError(try store.publishFocus(id: UUID(), documentID: UUID(), revision: 0,
            contextHash: "never persist typed context", now: now))
        let lease = try focus(in: store)
        for invalid in ["", " \n\t ", String(repeating: "x", count: KeyboardDeliveryStore.maximumTextBytes + 1)] {
            XCTAssertThrowsError(try store.publish(text: invalid, for: lease, sessionID: UUID(), now: now)) {
                XCTAssertEqual($0 as? KeyboardDeliveryError, .invalidText)
            }
        }
        let maxText = String(repeating: "x", count: KeyboardDeliveryStore.maximumTextBytes)
        XCTAssertTrue(try store.publish(text: maxText, for: lease, sessionID: UUID(), now: now))
        XCTAssertEqual(try store.consume(for: lease, now: now)?.text, maxText)
        let invalidLease = KeyboardFocusLease(documentID: UUID(), contextHash: contextDigest,
            updatedAt: now, expiresAt: now.addingTimeInterval(7))
        XCTAssertThrowsError(try store.publish(text: "x", for: invalidLease, sessionID: UUID(), now: now))
    }

    func testCorruptOversizedAndFutureVersionFilesFailClosedWithoutOverwrite() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let lease = try focus(in: store)
        let file = directory.appendingPathComponent("keyboard-delivery.json")
        let badFiles = [Data("incomplete".utf8), Data(#"{"version":2,"receipts":[]}"#.utf8),
                        Data(repeating: 120, count: KeyboardDeliveryStore.maximumStateBytes + 1)]
        for bad in badFiles {
            try bad.write(to: file)
            XCTAssertThrowsError(try store.activeFocus(now: now))
            XCTAssertThrowsError(try store.consume(for: lease, now: now))
            XCTAssertThrowsError(try store.publish(text: "must not publish", for: lease, sessionID: UUID(), now: now))
            XCTAssertEqual(try Data(contentsOf: file), bad)
        }
    }

    func testConsumedTranscriptRemovedAndOnlyEphemeralMetadataRemains() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        let lease = try focus(in: store)
        let text = "sensitive transcript placeholder"
        XCTAssertTrue(try store.publish(text: text, for: lease, sessionID: UUID(), now: now))
        _ = try store.consume(for: lease, now: now)
        let file = directory.appendingPathComponent("keyboard-delivery.json")
        var stored = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(stored.contains(text))
        XCTAssertFalse(stored.contains("token"))
        XCTAssertFalse(stored.contains("audio"))
        _ = try store.activeFocus(now: now.addingTimeInterval(KeyboardDeliveryStore.receiptLifetime))
        stored = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(stored.contains(lease.id.uuidString))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testReceiptBoundFailsClosedAndExpiredReceiptsArePruned() throws {
        let store = try KeyboardDeliveryStore(directory: directory)
        for _ in 0..<256 { try store.cancel(sessionID: UUID(), now: now) }
        let lease = try focus(in: store)
        XCTAssertThrowsError(try store.publish(text: "over bound", for: lease, sessionID: UUID(), now: now)) {
            XCTAssertEqual($0 as? KeyboardDeliveryError, .receiptLimit)
        }
        let future = now.addingTimeInterval(KeyboardDeliveryStore.receiptLifetime)
        let fresh = try focus(in: store, time: future)
        XCTAssertTrue(try store.publish(text: "after expiry", for: fresh, sessionID: UUID(), now: future))
    }

    private func focus(in store: KeyboardDeliveryStore, time: Date? = nil) throws -> KeyboardFocusLease {
        try store.publishFocus(id: UUID(), documentID: UUID(), revision: 0, contextHash: contextDigest, now: time ?? now)
    }
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    private var errors = 0
    var texts: [String] { lock.withLock { collected } }
    var errorCount: Int { lock.withLock { errors } }
    func append(_ text: String) { lock.withLock { collected.append(text) } }
    func recordError() { lock.withLock { errors += 1 } }
}
