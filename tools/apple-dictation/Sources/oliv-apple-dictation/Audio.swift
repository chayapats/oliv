import AVFoundation
import Foundation

/// One clip, converted once into the analyzer's preferred format.
struct Clip {
    let buffer: AVAudioPCMBuffer
    /// Audio length in seconds.
    let duration: Double
    /// First 20 ms frame whose energy clears the clip's noise floor, in seconds:
    /// an approximate "speech started" for first-result latency.
    let onset: Double
}

enum AudioError: Error, CustomStringConvertible {
    case unreadable(String), conversion(String), empty(String)
    var description: String {
        switch self {
        case .unreadable(let p): "cannot read audio \(p)"
        case .conversion(let p): "cannot convert audio \(p)"
        case .empty(let p): "empty audio \(p)"
        }
    }
}

func loadClip(_ url: URL, as target: AVAudioFormat) throws -> Clip {
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: url) } catch { throw AudioError.unreadable(url.path) }
    let length = AVAudioFrameCount(file.length)
    guard length > 0,
          let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: length)
    else { throw AudioError.empty(url.path) }
    try file.read(into: source)
    let onset = energyOnset(source)
    let duration = Double(source.frameLength) / source.format.sampleRate
    if source.format == target {
        return Clip(buffer: source, duration: duration, onset: onset)
    }
    guard let converter = AVAudioConverter(from: source.format, to: target) else {
        throw AudioError.conversion(url.path)
    }
    let capacity = AVAudioFrameCount(
        (Double(source.frameLength) * target.sampleRate / source.format.sampleRate).rounded(.up)) + 4096
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw AudioError.conversion(url.path)
    }
    var fed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
        if fed {
            inputStatus.pointee = .endOfStream
            return nil
        }
        fed = true
        inputStatus.pointee = .haveData
        return source
    }
    guard status != .error, error == nil, out.frameLength > 0 else { throw AudioError.conversion(url.path) }
    return Clip(buffer: out, duration: duration, onset: onset)
}

/// Frames `[from, from + count)` of `buffer` as a new buffer in the same format.
func slice(_ buffer: AVAudioPCMBuffer, from: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count)!
    out.frameLength = count
    let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
    for i in 0..<min(src.count, dst.count) {
        memcpy(dst[i].mData!, src[i].mData!.advanced(by: Int(from) * bytesPerFrame), Int(count) * bytesPerFrame)
        dst[i].mDataByteSize = UInt32(Int(count) * bytesPerFrame)
    }
    return out
}

/// Energy onset on channel 0 (float processing format): the first 20 ms frame
/// above max(4 x the 10th-percentile frame RMS, 10% of the loudest frame).
func energyOnset(_ buffer: AVAudioPCMBuffer) -> Double {
    guard let samples = buffer.floatChannelData?[0] else { return 0 }
    let hop = max(1, Int(buffer.format.sampleRate * 0.02))
    let n = Int(buffer.frameLength)
    var rms: [Float] = []
    var start = 0
    while start + hop <= n {
        var sum: Float = 0
        for i in start..<(start + hop) { sum += samples[i] * samples[i] }
        rms.append((sum / Float(hop)).squareRoot())
        start += hop
    }
    guard let peak = rms.max(), peak > 0 else { return 0 }
    let floor = rms.sorted()[rms.count / 10]
    let threshold = max(floor * 4, peak * 0.1)
    let first = rms.firstIndex { $0 >= threshold } ?? 0
    return Double(first * hop) / buffer.format.sampleRate
}
