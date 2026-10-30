import Foundation
import XCTest
@testable import OlivCore

final class AudioTests: XCTestCase {
    func testCanonicalWAVPreservesSignedSamplesAndDuration() throws {
        let wav = try WAVEncoder.encode(samples: [0, 1, -1, .max, .min])
        XCTAssertEqual(wav.count, 54)
        XCTAssertEqual(Array(wav.suffix(10)), [0, 0, 1, 0, 255, 255, 255, 127, 0, 128])
        let metadata = try WAVMetadata(data: wav)
        XCTAssertEqual(metadata.sampleRate, 16_000)
        XCTAssertEqual(metadata.channelCount, 1)
        XCTAssertEqual(metadata.bitsPerSample, 16)
        XCTAssertEqual(metadata.sampleCount, 5)
        XCTAssertEqual(metadata.duration, 5 / 16_000.0)
        XCTAssertEqual(try WAVMetadata(data: WAVEncoder.encode(samples: .init(repeating: 0, count: 16_000))).duration, 1)
    }

    func testUnknownOddSizedChunkIsSkippedWithPadding() throws {
        let canonical = try WAVEncoder.encode(samples: [10, 20])
        var original = [UInt8](canonical)
        let chunk: [UInt8] = Array("LIST".utf8) + [3, 0, 0, 0, 1, 2, 3, 0]
        original.insert(contentsOf: chunk, at: 36)
        setUInt32(&original, at: 4, value: original.count - 8)
        let result = try WAVMetadata(data: Data(original))
        XCTAssertEqual(result.sampleCount, 2)
        XCTAssertEqual(result.dataByteCount, 4)
        XCTAssertEqual(try WAVEncoder.canonicalize(Data(original)), canonical)
    }

    func testExtendedPCMFormatLikeAudioRecorderIsAccepted() throws {
        var wav = [UInt8](try WAVEncoder.encode(samples: [1, 2, 3]))
        wav.insert(contentsOf: [0, 0], at: 36)
        setUInt32(&wav, at: 16, value: 18)
        setUInt32(&wav, at: 4, value: wav.count - 8)
        XCTAssertEqual(try WAVMetadata(data: Data(wav)).sampleCount, 3)
        XCTAssertEqual(try WAVEncoder.canonicalize(Data(wav)), try WAVEncoder.encode(samples: [1, 2, 3]))
    }

    func testRecorderContainerCanonicalizationPreservesEveryPCMByte() throws {
        // Match the chunk sizes observed on iPhone, using synthetic samples.
        let samples = (0..<43_418).map { Int16(truncatingIfNeeded: $0 * 397) }
        let original = try RecorderWAVFixture.make(samples: samples)
        let untouched = original
        let expected = try WAVEncoder.encode(samples: samples)
        let result = try WAVEncoder.canonicalize(original)
        XCTAssertEqual(original.count, 90_932)
        XCTAssertEqual(result.count, 86_880)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.dropFirst(44), original.suffix(samples.count * 2))
        XCTAssertEqual(try WAVMetadata(data: result), try WAVMetadata(data: original))
        XCTAssertEqual(try WAVEncoder.canonicalize(result), result)
        XCTAssertEqual(original, untouched)
    }

    func testCanonicalizationUsesValidatedRangeForDataBeforeFormatAndSlicedData() throws {
        let canonical = try WAVEncoder.encode(samples: [.min, 0, .max])
        var reordered = [UInt8](canonical.prefix(12))
        reordered.append(contentsOf: canonical.dropFirst(36))
        reordered.append(contentsOf: Array("FLLR".utf8) + [1, 0, 0, 0, 42, 0])
        reordered.append(contentsOf: canonical[12..<36])
        setUInt32(&reordered, at: 4, value: reordered.count - 8)
        var prefixed = Data([0xFF, 0xFE, 0xFD])
        prefixed.append(contentsOf: reordered)
        let slice = prefixed.dropFirst(3)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(try WAVEncoder.canonicalize(slice), canonical)
    }

    func testCanonicalizationRejectsWrongPCMFormatAndMalformedChunksAfterAudio() throws {
        let canonical = try WAVEncoder.encode(samples: [1, 2])
        var invalidContainers = [try WAVEncoder.encode(samples: [1, 2], sampleRate: 44_100)]
        var stereo = [UInt8](canonical)
        stereo[22] = 2
        stereo[32] = 4
        setUInt32(&stereo, at: 28, value: 64_000)
        invalidContainers.append(Data(stereo))
        var eightBit = [UInt8](canonical)
        eightBit[32] = 1
        eightBit[34] = 8
        setUInt32(&eightBit, at: 28, value: 16_000)
        invalidContainers.append(Data(eightBit))
        for tail in [
            Array("FLLR".utf8) + [4, 0, 0, 0, 1, 2], // Truncated payload.
            Array("FLLR".utf8) + [1, 0, 0, 0, 42], // Missing odd-byte padding.
            Array(canonical[12..<36]) // Duplicate format after a complete data chunk.
        ] {
            var malformed = [UInt8](canonical) + tail
            setUInt32(&malformed, at: 4, value: malformed.count - 8)
            invalidContainers.append(Data(malformed))
        }
        for invalid in invalidContainers {
            XCTAssertThrowsError(try WAVEncoder.canonicalize(invalid)) { error in
                guard case .invalidAudio = error as? OlivError else {
                    return XCTFail("Expected invalid audio, received \(error)")
                }
            }
        }
    }

    func testMalformedWAVNeverTraps() throws {
        let valid = try WAVEncoder.encode(samples: [1, 2, 3])
        for length in 0..<valid.count {
            XCTAssertThrowsError(try WAVMetadata(data: valid.prefix(length)), "truncation at \(length)")
            XCTAssertThrowsError(try WAVEncoder.canonicalize(valid.prefix(length)), "truncation at \(length)")
        }
        for (position, value) in [(0, UInt8(0)), (20, 3), (22, 0), (24, 0), (28, 1), (32, 1), (34, 7)] {
            var malformed = valid
            malformed[position] = value
            XCTAssertThrowsError(try WAVMetadata(data: malformed), "malformed field at \(position)")
            XCTAssertThrowsError(try WAVEncoder.canonicalize(malformed), "malformed field at \(position)")
        }
        var hugeChunk = [UInt8](valid)
        setUInt32(&hugeChunk, at: 40, value: Int(UInt32.max))
        XCTAssertThrowsError(try WAVMetadata(data: Data(hugeChunk)))
        XCTAssertThrowsError(try WAVEncoder.canonicalize(Data(hugeChunk)))
        XCTAssertThrowsError(try WAVEncoder.encode(samples: [], sampleRate: 0))
        XCTAssertThrowsError(try WAVEncoder.encode(samples: [], sampleRate: Int.max))
    }

    func testDuplicateDataChunkAndIncompleteFrameAreRejected() throws {
        var wav = [UInt8](try WAVEncoder.encode(samples: [1]))
        wav.append(contentsOf: Array("data".utf8) + [0, 0, 0, 0])
        setUInt32(&wav, at: 4, value: wav.count - 8)
        XCTAssertThrowsError(try WAVMetadata(data: Data(wav)))
        XCTAssertThrowsError(try WAVEncoder.canonicalize(Data(wav)))
        var oddFrame = [UInt8](try WAVEncoder.encode(samples: [1]))
        setUInt32(&oddFrame, at: 40, value: 1)
        XCTAssertThrowsError(try WAVMetadata(data: Data(oddFrame)))
        XCTAssertThrowsError(try WAVEncoder.canonicalize(Data(oddFrame)))
    }

    func testRecordingThresholdsMatchLinux() {
        XCTAssertEqual(RecordingLimits.maximumDuration, 120)
        XCTAssertEqual(RecordingLimits.verdict(heldDuration: 0.299, audioDuration: 1), .tooShort)
        XCTAssertEqual(RecordingLimits.verdict(heldDuration: 0.3, audioDuration: 0.1), .send)
        XCTAssertEqual(RecordingLimits.verdict(heldDuration: 2, audioDuration: 0.099), .silent)
    }

    private func setUInt32(_ data: inout [UInt8], at offset: Int, value: Int) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
}

/// AVAudioRecorder's observed iPhone chunk layout, containing only test samples.
enum RecorderWAVFixture {
    static func make(samples: [Int16]) throws -> Data {
        let canonical = try WAVEncoder.encode(samples: samples)
        var result = Data(canonical.prefix(12))
        result.append(contentsOf: "JUNK".utf8)
        result.append(contentsOf: [28, 0, 0, 0])
        result.append(Data(repeating: 0, count: 28))
        result.append(canonical[12..<36])
        result.append(contentsOf: "FLLR".utf8)
        result.append(contentsOf: [168, 15, 0, 0]) // 4,008 bytes.
        result.append(Data(repeating: 0, count: 4_008))
        result.append(canonical.dropFirst(36))
        let riffSize = result.count - 8
        for i in 0..<4 { result[4 + i] = UInt8(truncatingIfNeeded: riffSize >> (8 * i)) }
        return result
    }
}
