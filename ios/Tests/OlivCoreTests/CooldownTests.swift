import Foundation
import XCTest
@testable import OlivCore

final class CooldownTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OlivCooldownTests-\(UUID())")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testCooldownSurvivesReopeningAndExpiresWithoutSleeping() throws {
        let store = try RetryCooldownStore(directory: directory)
        XCTAssertNoThrow(try store.check(now: now))
        XCTAssertNil(try store.until(now: now))
        let date = now.addingTimeInterval(60)
        try store.record(until: date)
        let reopened = try RetryCooldownStore(directory: directory)
        XCTAssertEqual(try reopened.until(now: now), date)
        XCTAssertThrowsError(try reopened.check(now: now.addingTimeInterval(59))) {
            XCTAssertEqual($0 as? OlivError, .rateLimited(retryAfter: date))
        }
        XCTAssertNoThrow(try reopened.check(now: date))
        XCTAssertNil(try reopened.until(now: now.addingTimeInterval(61)))
    }

    func testLaterResponsesCannotShortenExistingCooldown() throws {
        let store = try RetryCooldownStore(directory: directory)
        try store.record(until: now.addingTimeInterval(120))
        try store.record(until: now.addingTimeInterval(5))
        XCTAssertEqual(try store.until(now: now), now.addingTimeInterval(120))
        try store.record(until: now.addingTimeInterval(180))
        XCTAssertEqual(try store.until(now: now), now.addingTimeInterval(180))
    }

    func testStorageContainsOnlyDateAndUsesPrivatePermissionsAndBackupExclusion() throws {
        let store = try RetryCooldownStore(directory: directory)
        try store.record(until: now.addingTimeInterval(60))
        let file = directory.appendingPathComponent("retry-cooldown.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["until"])
        XCTAssertTrue(object["until"] is NSNumber)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testCorruptedOrOversizedCooldownIsPreservedAndFailsClosed() throws {
        let store = try RetryCooldownStore(directory: directory)
        let file = directory.appendingPathComponent("retry-cooldown.json")
        for data in [Data("broken".utf8), Data(#"{"until":null}"#.utf8), Data(#"{"until":"tomorrow"}"#.utf8),
                     Data(repeating: 0, count: 1_025)] {
            try data.write(to: file)
            XCTAssertThrowsError(try store.check(now: now)) {
                XCTAssertEqual($0 as? OlivError, .corruptedStore)
            }
            XCTAssertThrowsError(try store.record(until: now.addingTimeInterval(60)))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testInvalidDatesCannotEraseValidCooldown() throws {
        let store = try RetryCooldownStore(directory: directory)
        let expiry = now.addingTimeInterval(60)
        try store.record(until: expiry)
        XCTAssertThrowsError(try store.record(until: Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try store.check(now: Date(timeIntervalSince1970: .nan)))
        XCTAssertEqual(try store.until(now: now), expiry)
    }

    func testCooldownErrorsShowConcreteLocalRetryTime() {
        let date = now.addingTimeInterval(60)
        let formatted = date.formatted(date: .abbreviated, time: .standard)
        XCTAssertTrue(OlivError.rateLimited(retryAfter: date).localizedDescription.contains(formatted))
        XCTAssertTrue(OlivError.serviceUnavailable(statusCode: 503, retryAfter: date).localizedDescription.contains(formatted))
        XCTAssertNil(OlivError.serviceUnavailable(statusCode: 503, retryAfter: nil).retryAfter)
    }
}
