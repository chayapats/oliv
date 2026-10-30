import Foundation

public enum RecordingLimits {
    public static let sampleRate = 16_000
    public static let maximumDuration: TimeInterval = 120
    public static let minimumHoldDuration: TimeInterval = 0.3
    public static let minimumAudioDuration: TimeInterval = 0.1

    public enum Verdict: Equatable, Sendable { case tooShort, silent, send }

    public static func verdict(heldDuration: TimeInterval, audioDuration: TimeInterval) -> Verdict {
        if heldDuration < minimumHoldDuration { return .tooShort }
        if audioDuration < minimumAudioDuration { return .silent }
        return .send
    }
}

public enum WAVEncoder {
    public static func encode(samples: [Int16], sampleRate: Int = RecordingLimits.sampleRate) throws -> Data {
        guard sampleRate > 0, sampleRate <= Int(UInt32.max / 2),
              samples.count <= (Int(UInt32.max) - 36) / 2 else {
            throw OlivError.invalidAudio(String(localized: "The PCM sample rate or recording size is invalid.", bundle: .main))
        }
        var data = try header(sampleRate: sampleRate, byteCount: samples.count * 2)
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Removes recorder-specific RIFF chunks without resampling or changing any
    /// PCM bytes. The server accepts the same minimal WAV container as Linux.
    public static func canonicalize(_ data: Data) throws -> Data {
        let layout = try PCMLayout(data: data)
        guard layout.sampleRate == RecordingLimits.sampleRate,
              layout.channelCount == 1, layout.bitsPerSample == 16 else {
            throw OlivError.invalidAudio(String(localized: "OLIV expects 16 kHz mono 16-bit PCM WAV audio.", bundle: .main))
        }
        var result = try header(sampleRate: layout.sampleRate, byteCount: layout.dataRange.count)
        let start = data.index(data.startIndex, offsetBy: layout.dataRange.lowerBound)
        let end = data.index(data.startIndex, offsetBy: layout.dataRange.upperBound)
        result.append(contentsOf: data[start..<end])
        return result
    }

    private static func header(sampleRate: Int, byteCount: Int) throws -> Data {
        guard sampleRate > 0, sampleRate <= Int(UInt32.max / 2),
              byteCount >= 0, byteCount <= Int(UInt32.max) - 36,
              byteCount.isMultiple(of: 2) else {
            throw OlivError.invalidAudio(String(localized: "The PCM sample rate or recording size is invalid.", bundle: .main))
        }
        var data = Data(capacity: 44 + byteCount)
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        word(UInt32(36 + byteCount))
        ascii("WAVEfmt ")
        word(UInt32(16))
        word(UInt16(1)) // Linear PCM.
        word(UInt16(1)) // Mono.
        word(UInt32(sampleRate))
        word(UInt32(sampleRate * 2))
        word(UInt16(2))
        word(UInt16(16))
        ascii("data")
        word(UInt32(byteCount))
        return data
    }
}

/// Reads RIFF chunks rather than assuming a 44-byte header. AVAudioRecorder can
/// include additional chunks such as FLLR, LIST, and extended PCM format data.
public struct WAVMetadata: Equatable, Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let bitsPerSample: Int
    public let sampleCount: Int
    public let dataByteCount: Int
    public var duration: TimeInterval { Double(sampleCount) / Double(sampleRate) }

    public init(data: Data) throws {
        let layout = try PCMLayout(data: data)
        self.sampleRate = layout.sampleRate
        self.channelCount = layout.channelCount
        self.bitsPerSample = layout.bitsPerSample
        self.sampleCount = layout.sampleCount
        self.dataByteCount = layout.dataRange.count
    }
}

/// Offsets belong to this parsed container, not to the semantic audio metadata.
/// Validate every chunk, including any after data, before exposing its PCM range.
private struct PCMLayout {
    let sampleRate: Int
    let channelCount: Int
    let bitsPerSample: Int
    let sampleCount: Int
    let dataRange: Range<Int>

    init(data: Data) throws {
        let bytes = [UInt8](data)
        func fail() -> OlivError { .invalidAudio(String(localized: "The recording is not a complete PCM WAV file.", bundle: .main)) }
        func matches(_ offset: Int, _ value: String) -> Bool {
            Array(bytes[offset..<(offset + value.utf8.count)]) == Array(value.utf8)
        }
        func u16(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        guard bytes.count >= 12, matches(0, "RIFF"), matches(8, "WAVE") else { throw fail() }
        let end = u32(4) + 8
        guard end >= 12, end <= bytes.count else { throw fail() }
        var rate: Int?
        var channels: Int?
        var bits: Int?
        var alignment: Int?
        var audioRange: Range<Int>?
        var offset = 12
        while offset < end {
            guard end - offset >= 8 else { throw fail() }
            let size = u32(offset + 4)
            let start = offset + 8
            guard size <= end - start else { throw fail() }
            if matches(offset, "fmt ") {
                guard rate == nil, size >= 16, u16(start) == 1 else { throw fail() }
                let readChannels = u16(start + 2)
                let readRate = u32(start + 4)
                let readByteRate = u32(start + 8)
                let readAlignment = u16(start + 12)
                let readBits = u16(start + 14)
                guard readChannels > 0, readRate > 0, [8, 16, 24, 32].contains(readBits),
                      readAlignment == readChannels * readBits / 8,
                      readByteRate == readRate * readAlignment else { throw fail() }
                rate = readRate
                channels = readChannels
                bits = readBits
                alignment = readAlignment
            } else if matches(offset, "data") {
                guard audioRange == nil else { throw fail() }
                audioRange = start..<(start + size)
            }
            offset = start + size + (size % 2)
            guard offset <= end else { throw fail() }
        }
        guard let rate, let channels, let bits, let alignment, let audioRange,
              audioRange.count.isMultiple(of: alignment) else { throw fail() }
        self.sampleRate = rate
        self.channelCount = channels
        self.bitsPerSample = bits
        self.dataRange = audioRange
        self.sampleCount = audioRange.count / alignment
    }
}
