import Foundation
import XCTest
@testable import OlivCore

final class StoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oliv-tests-\(UUID())", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testHistorySurvivesReopeningAndRetainsNewestWithoutDuplicatingIDs() throws {
        let store = try HistoryStore(directory: directory, retentionLimit: 2)
        let first = entry(at: 1, text: "หนึ่ง")
        let second = entry(at: 2, text: "สอง")
        var third = entry(at: 3, text: "three")
        try store.append(first)
        try store.append(third)
        try store.append(second)
        XCTAssertEqual(try store.entries().map(\.id), [third.id, second.id])
        third.reply.finalText = "THREE"
        try store.append(third)
        XCTAssertEqual(try store.entries().count, 2)
        try store.markCopied(id: third.id)
        let reopened = try HistoryStore(directory: directory, retentionLimit: 2)
        XCTAssertEqual(try reopened.entries().first?.finalText, "THREE")
        XCTAssertEqual(try reopened.entries().first?.copied, true)
        try reopened.remove(id: third.id)
        XCTAssertEqual(try reopened.entries().map(\.id), [second.id])
        try reopened.removeAll()
        XCTAssertEqual(try reopened.entries(), [])
    }

    func testNoSpeechAndCleanupFallbackMetadataSurviveRoundTrip() throws {
        let store = try HistoryStore(directory: directory)
        let reply = DictationReply(raw: "เอ่อ", noSpeech: true, sttRedecoded: true,
                                   tSTT: 0.71, tCleanup: 0.14, llmRan: true,
                                   gateReason: "hallucination", guardrailFlag: "llmError->dict",
                                   cleanupError: "timeout", dictionaryHits: 2, fillersRemoved: 1)
        let item = HistoryEntry(createdAt: Date(timeIntervalSince1970: 1_000), source: .retry,
                                audioDuration: 1.2, totalDuration: 0.9, reply: reply)
        try store.append(item)
        XCTAssertEqual(try HistoryStore(directory: directory).entries(), [item])
    }

    func testCorruptHistoryIsPreservedInsteadOfOverwritten() throws {
        let store = try HistoryStore(directory: directory)
        let file = directory.appendingPathComponent("history.json")
        let invalid = Data("incomplete data".utf8)
        try invalid.write(to: file)
        XCTAssertThrowsError(try store.entries()) { XCTAssertEqual($0 as? OlivError, .corruptedStore) }
        XCTAssertThrowsError(try store.append(entry(at: 1, text: "new")))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testFutureHistoryVersionIsNotSilentlyOverwritten() throws {
        let store = try HistoryStore(directory: directory)
        let file = directory.appendingPathComponent("history.json")
        try Data(#"{"version":99,"entries":[]}"#.utf8).write(to: file)
        XCTAssertThrowsError(try store.append(entry(at: 1, text: "new")))
    }

    func testPendingAudioAndOptionsSnapshotSurviveRestartAndFailedRetry() throws {
        let store = try PendingRecordingStore(directory: directory)
        let wav = try WAVEncoder.encode(samples: .init(repeating: 10, count: 16_000))
        var options = OlivOptions(cleanup: false, vocabulary: ["Grafana"], replacements: [.init(spoken: "ซี", written: "C")])
        let pending = try store.enqueue(wav: wav, options: options, createdAt: Date(timeIntervalSince1970: 1_000))
        options.vocabulary = ["Changed later"]
        XCTAssertEqual(pending.audioDuration, 1)
        XCTAssertEqual(try store.audio(for: pending.id), wav)
        try store.recordAttempt(id: pending.id, errorDescription: "Server unavailable")
        let reopened = try PendingRecordingStore(directory: directory)
        let saved = try XCTUnwrap(reopened.recordings().first)
        XCTAssertEqual(saved.options.vocabulary, ["Grafana"])
        XCTAssertEqual(saved.options.replacements[0].spoken, "ซี")
        XCTAssertFalse(saved.options.cleanup)
        XCTAssertEqual(saved.attemptCount, 1)
        XCTAssertEqual(saved.lastError, "Server unavailable")
        XCTAssertEqual(try reopened.audio(for: pending.id), wav)
        try reopened.remove(id: pending.id)
        XCTAssertEqual(try reopened.recordings(), [])
        XCTAssertThrowsError(try reopened.audio(for: pending.id)) { XCTAssertEqual($0 as? OlivError, .missingRecording) }
        XCTAssertNoThrow(try reopened.remove(id: pending.id))
    }

    func testPendingQueueIsOldestFirstAndIgnoresInterruptedStagingTransaction() throws {
        let store = try PendingRecordingStore(directory: directory)
        let wav = try WAVEncoder.encode(samples: [1])
        let newest = try store.enqueue(wav: wav, options: OlivOptions(), createdAt: Date(timeIntervalSince1970: 2))
        let oldest = try store.enqueue(wav: wav, options: OlivOptions(), createdAt: Date(timeIntervalSince1970: 1))
        let staging = directory.appendingPathComponent(".staging-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        XCTAssertEqual(try store.recordings().map(\.id), [oldest.id, newest.id])
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try store.removeAll()
        XCTAssertEqual(try store.recordings(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testPendingCorruptionAndInvalidAudioDoNotDisappearSilently() throws {
        let store = try PendingRecordingStore(directory: directory)
        XCTAssertThrowsError(try store.enqueue(wav: Data(), options: OlivOptions()))
        XCTAssertThrowsError(try store.enqueue(wav: WAVEncoder.encode(samples: []), options: OlivOptions()))
        let item = try store.enqueue(wav: WAVEncoder.encode(samples: [1]), options: OlivOptions())
        let audio = directory.appendingPathComponent(item.id.uuidString).appendingPathComponent("audio.wav")
        try FileManager.default.removeItem(at: audio)
        XCTAssertThrowsError(try store.recordings()) { XCTAssertEqual($0 as? OlivError, .corruptedStore) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.deletingLastPathComponent().path))
    }

    func testStoreFilesArePrivateAndExcludedFromBackup() throws {
        let store = try HistoryStore(directory: directory)
        try store.append(entry(at: 1, text: "private"))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    private func entry(at time: TimeInterval, text: String) -> HistoryEntry {
        HistoryEntry(createdAt: Date(timeIntervalSince1970: time), audioDuration: 1,
                     totalDuration: 0.8, reply: DictationReply(raw: text, finalText: text))
    }
}
