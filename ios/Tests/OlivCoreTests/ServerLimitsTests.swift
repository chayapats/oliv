import Foundation
import XCTest
@testable import OlivCore

/// Mirrors oliv-api `validate_options`: at most 128 vocabulary entries and
/// 128 replacement rules, each string at most 256 UTF-8 bytes.
final class ServerLimitsTests: XCTestCase {
    private func rule(_ spoken: String, _ written: String = "x") -> ReplacementRule {
        ReplacementRule(spoken: spoken, written: written)
    }

    func testLimitsAcceptTheServerMaximum() throws {
        let options = OlivOptions(vocabulary: (0..<128).map { "word\($0)" },
            replacements: (0..<128).map { rule("spoken\($0)", String(repeating: "w", count: 256)) })
        XCTAssertNoThrow(try options.validateServerLimits())
        XCTAssertNoThrow(try OlivOptions(vocabulary: [String(repeating: "a", count: 256)]).validateServerLimits())
    }

    func testLimitsRejectEachValueTheServerRejects() {
        let thai = String(repeating: "ก", count: 86) // 258 UTF-8 bytes
        let cases: [OlivOptions] = [
            OlivOptions(vocabulary: (0..<129).map { "word\($0)" }),
            OlivOptions(vocabulary: [thai]),
            OlivOptions(replacements: (0..<129).map { rule("spoken\($0)") }),
            OlivOptions(replacements: [rule(thai)]),
            OlivOptions(replacements: [rule("ok", thai)]),
        ]
        for options in cases {
            XCTAssertThrowsError(try options.validateServerLimits()) { error in
                guard case OlivError.invalidOptions = error else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try RequestBody.encode(audio: nil, text: "t", options: options),
                                 "Encoding must fail locally instead of earning a generic HTTP 400")
        }
    }

    func testEnqueueKeepsAudioEvenWhenSettingsExceedTheServerLimits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PendingRecordingStore(directory: directory)
        let wav = try WAVEncoder.encode(samples: .init(repeating: 0, count: 1_600))
        let options = OlivOptions(vocabulary: (0..<129).map { "word\($0)" })
        XCTAssertNoThrow(try store.enqueue(wav: wav, options: options))
    }
}
