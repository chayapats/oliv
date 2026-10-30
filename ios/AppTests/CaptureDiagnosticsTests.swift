import Foundation
import XCTest
@testable import Oliv

final class CaptureDiagnosticsTests: XCTestCase {
    func testKeepsOnlyNewestEventsAcrossStoreInstances() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let limit = CaptureDiagnostics.Store.maximumEvents
        for index in 0..<(limit + 15) {
            // A new instance proves the bound survives reopening the log.
            try CaptureDiagnostics.Store(directory: directory).record(
                event: .startRequested, now: start.addingTimeInterval(Double(index)))
        }
        let entries = try readEntries(directory)
        XCTAssertEqual(entries.count, limit)
        XCTAssertEqual(entries.first?.timestamp, start.addingTimeInterval(15))
        XCTAssertEqual(entries.last?.timestamp, start.addingTimeInterval(Double(limit + 14)))
        XCTAssertTrue(entries.allSatisfy { $0.event == .startRequested })
        XCTAssertTrue(entries.allSatisfy { $0.detail == nil && $0.errorCode == nil && $0.errorDomain == nil })
    }

    func testErrorSanitizationDropsArbitraryDomainMessagesAndUserInfo() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureDiagnostics.Store(directory: directory)
        let privateMarker = "synthetic-private-marker-never-store"
        let error = NSError(domain: privateMarker, code: -1_234, userInfo: [
            NSLocalizedDescriptionKey: privateMarker,
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -50,
                                          userInfo: [NSLocalizedDescriptionKey: privateMarker]),
            "transcript": privateMarker, "token": privateMarker, "url": privateMarker
        ])
        try store.record(event: .startFailed, error: error, detail: .background)
        try store.record(event: .microphoneStarting,
                         error: NSError(domain: NSOSStatusErrorDomain, code: -50))
        let entries = try readEntries(directory)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].errorDomain, .other)
        XCTAssertEqual(entries[0].errorCode, -1_234)
        XCTAssertEqual(entries[0].detail, .background)
        XCTAssertEqual(entries[1].errorDomain, .osStatus)
        XCTAssertEqual(entries[1].errorCode, -50)
        let serialized = try String(contentsOf: directory.appendingPathComponent("events.json"), encoding: .utf8)
        XCTAssertFalse(serialized.contains(privateMarker))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [[String: Any]])
        let permitted: Set<String> = ["timestamp", "event", "detail", "errorCode", "errorDomain"]
        XCTAssertTrue(json.allSatisfy { Set($0.keys).isSubset(of: permitted) })
    }

    func testClassifierErrorChainKeepsOnlyFourSanitizedNumericIdentities() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "synthetic-sensitive-classifier-detail-never-store"
        let beyondLimit = NSError(domain: NSOSStatusErrorDomain, code: -50,
                                  userInfo: [NSLocalizedDescriptionKey: marker])
        let unknown = NSError(domain: marker, code: -99, userInfo: [
            NSUnderlyingErrorKey: beyondLimit, NSLocalizedDescriptionKey: marker,
            "audio": marker, "transcript": marker
        ])
        let metal = NSError(domain: "MTLCommandBufferErrorDomain", code: 6, userInfo: [
            NSUnderlyingErrorKey: unknown, NSLocalizedDescriptionKey: marker
        ])
        let model = NSError(domain: "com.apple.CoreML", code: 0, userInfo: [
            NSUnderlyingErrorKey: metal, NSLocalizedDescriptionKey: marker, "modelPath": marker
        ])
        let classifier = NSError(domain: "com.apple.SoundAnalysis", code: 2, userInfo: [
            NSUnderlyingErrorKey: model, NSLocalizedDescriptionKey: marker, "token": marker
        ])

        try CaptureDiagnostics.Store(directory: directory).recordClassifierFailure(classifier)
        let entries = try readEntries(directory)
        XCTAssertEqual(entries.count, 4, "Only the outer error and three causes may be persisted")
        XCTAssertEqual(entries.map(\.errorCode), [2, 0, 6, -99])
        XCTAssertEqual(entries.map(\.errorDomain), [.soundAnalysis, .coreML, .metal, .other])
        XCTAssertEqual(entries.map(\.event), [.speechClassifierFailed,
                                             .speechClassifierUnderlyingFailure,
                                             .speechClassifierUnderlyingFailure,
                                             .speechClassifierUnderlyingFailure])
        let data = try Data(contentsOf: directory.appendingPathComponent("events.json"))
        let serialized = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(serialized.contains(marker), "No descriptions, paths, arbitrary domains or payloads may leak")
        XCTAssertFalse(serialized.contains("NSUnderlyingError"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let permitted: Set<String> = ["timestamp", "event", "detail", "errorCode", "errorDomain"]
        XCTAssertTrue(json.allSatisfy { Set($0.keys).isSubset(of: permitted) })
    }

    func testPipelineFailureUsesStableCodeInsteadOfSwiftErrorText() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try CaptureDiagnostics.Store(directory: directory).record(
            event: .audioPipelineFailed, error: SpeechAudioPipeline.Failure.discontinuousAudio)
        let entry = try XCTUnwrap(try readEntries(directory).first)
        XCTAssertEqual(entry.errorDomain, .audioPipeline)
        XCTAssertEqual(entry.errorCode, 5)
    }

    func testCorruptAndOversizedLogsAreReplacedByOneBoundedEvent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("events.json")
        let store = CaptureDiagnostics.Store(directory: directory)
        for badData in [Data("not-json".utf8), Data(repeating: 65, count: 64 * 1_024 + 1)] {
            try badData.write(to: file)
            try store.record(event: .intentToggle)
            let entries = try readEntries(directory)
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.event, .intentToggle)
            XCTAssertLessThan(try Data(contentsOf: file).count, 1_024)
        }
    }

    func testDiagnosticFilesHavePrivatePermissionsAndAreExcludedFromBackup() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try CaptureDiagnostics.Store(directory: directory).record(event: .intentToggle)
        let file = directory.appendingPathComponent("events.json")
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #if os(iOS) && !targetEnvironment(simulator)
        XCTAssertEqual(folderAttributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(fileAttributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CaptureDiagnostics-" + UUID().uuidString,
                                                                       isDirectory: true)
    }

    private func readEntries(_ directory: URL) throws -> [CaptureDiagnostics.Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([CaptureDiagnostics.Entry].self,
            from: Data(contentsOf: directory.appendingPathComponent("events.json")))
    }
}
