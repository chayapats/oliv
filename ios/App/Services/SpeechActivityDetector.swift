import AVFoundation
import CoreML
import Foundation
import OlivCore

struct AudioSpeechObservation: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isSpeech: Bool
}

/// The bundled Silero detector is confined to the capture worker and explicitly
/// uses CPU-only Core ML. There is no download, GPU, Speech permission, network
/// request or idle microphone. Only its locked result mailbox crosses threads.
final class SpeechActivityDetector: @unchecked Sendable {
    private static let sampleRate = 16_000
    private static let frameSamples = 512
    private static let contextSamples = 64
    private static let stateSamples = 256

    private let model: MLModel
    private let audioInput: MLMultiArray
    private let recurrentState: MLMultiArray
    private let speechThreshold: Float
    private let lock = NSLock()
    private var observations: [AudioSpeechObservation] = []
    private var failed = false
    // All state below is confined to SpeechAudioPipeline's serial worker.
    private var finished = false
    private var nextInputSample: AVAudioFramePosition = 0
    private var processedSamples: AVAudioFramePosition = 0
    private var pendingSamples: [Float] = []
    private var context = [Float](repeating: 0, count: SpeechActivityDetector.contextSamples)

    init(format: AVAudioFormat, speechThreshold: Float = 0.6) throws {
        guard format.sampleRate == Double(Self.sampleRate), format.channelCount == 1,
              format.commonFormat == .pcmFormatInt16,
              speechThreshold.isFinite, (0...1).contains(speechThreshold) else {
            throw SpeechAudioPipeline.Failure.invalidFormat
        }
        self.speechThreshold = speechThreshold
        do {
            guard let modelURL = Bundle.main.url(forResource: "SileroVAD", withExtension: "mlmodelc") else {
                throw SpeechAudioPipeline.Failure.classifierUnavailable
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
            audioInput = try MLMultiArray(shape: [1, 576], dataType: .float32)
            recurrentState = try MLMultiArray(shape: [2, 1, 128], dataType: .float32)
            for index in 0..<Self.stateSamples { recurrentState[index] = 0 }
            let description = model.modelDescription
            guard Self.matches(description.inputDescriptionsByName["audio"], shape: [1, 576]),
                  Self.matches(description.inputDescriptionsByName["recurrent_state"], shape: [2, 1, 128]),
                  Self.matches(description.outputDescriptionsByName["probability"], shape: [1, 1]),
                  Self.matches(description.outputDescriptionsByName["next_state"], shape: [2, 1, 128]) else {
                throw SpeechAudioPipeline.Failure.classifierUnavailable
            }
        } catch {
            CaptureDiagnostics.recordClassifierFailure(error)
            throw error
        }
        pendingSamples.reserveCapacity(Self.frameSamples)
    }

    var analysisFailed: Bool { lock.withLock { failed } }
    var computeUnits: MLComputeUnits { model.configuration.computeUnits }

    func takeObservations() -> [AudioSpeechObservation] {
        lock.withLock {
            let result = observations
            observations.removeAll(keepingCapacity: true)
            return result
        }
    }

    // Called only on SpeechAudioPipeline's serial worker, never on the audio tap.
    func analyze(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition) {
        guard !analysisFailed, !finished else { return }
        guard buffer.format.sampleRate == Double(Self.sampleRate), buffer.format.channelCount == 1,
              buffer.format.commonFormat == .pcmFormatInt16,
              buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else {
            fail(.invalidFormat)
            return
        }
        guard frame == nextInputSample,
              Int64(buffer.frameLength) <= 1_920_000 - nextInputSample else {
            fail(.discontinuousAudio)
            return
        }
        nextInputSample += AVAudioFramePosition(buffer.frameLength)
        do {
            var results: [AudioSpeechObservation] = []
            for index in 0..<Int(buffer.frameLength) {
                pendingSamples.append(Float(samples[index]) / 32_768)
                if pendingSamples.count == Self.frameSamples {
                    results.append(try autoreleasepool { try classifyFrame() })
                    pendingSamples.removeAll(keepingCapacity: true)
                }
            }
            append(results)
        } catch {
            CaptureDiagnostics.recordClassifierFailure(error)
            fail(.voiceDetectionFailed)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        // At most 31.94 ms remains. Do not invent silence or speech evidence by
        // padding the last partial frame beyond the captured samples.
        pendingSamples.removeAll(keepingCapacity: false)
    }

    private func classifyFrame() throws -> AudioSpeechObservation {
        // Input arrays are created contiguous and owned only by this worker.
        let audio = audioInput.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<Self.contextSamples { audio[index] = context[index] }
        for index in 0..<Self.frameSamples { audio[Self.contextSamples + index] = pendingSamples[index] }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio": audioInput, "recurrent_state": recurrentState
        ])
        let output = try model.prediction(from: input)
        guard let probability = output.featureValue(for: "probability")?.multiArrayValue,
              probability.dataType == .float32, probability.shape.map(\.intValue) == [1, 1],
              let nextState = output.featureValue(for: "next_state")?.multiArrayValue,
              nextState.dataType == .float32, nextState.shape.map(\.intValue) == [2, 1, 128] else {
            throw SpeechAudioPipeline.Failure.voiceDetectionInvalidResult
        }
        let confidence = probability[0].floatValue
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw SpeechAudioPipeline.Failure.voiceDetectionInvalidResult
        }
        // Indexed access respects Core ML's output strides; no borrowed state
        // or output array is shared with the next prediction.
        for index in 0..<Self.stateSamples {
            let value = nextState[index].floatValue
            guard value.isFinite else { throw SpeechAudioPipeline.Failure.voiceDetectionInvalidResult }
            recurrentState[index] = NSNumber(value: value)
        }
        context = Array(pendingSamples.suffix(Self.contextSamples))
        let start = Double(processedSamples) / Double(Self.sampleRate)
        processedSamples += AVAudioFramePosition(Self.frameSamples)
        return AudioSpeechObservation(startTime: start,
                                      endTime: Double(processedSamples) / Double(Self.sampleRate),
                                      isSpeech: confidence >= speechThreshold)
    }

    private static func matches(_ feature: MLFeatureDescription?, shape: [Int]) -> Bool {
        guard let constraint = feature?.multiArrayConstraint else { return false }
        return constraint.dataType == .float32 && constraint.shape.map(\.intValue) == shape
    }

    private func append(_ results: [AudioSpeechObservation]) {
        guard !analysisFailed else { return }
        let overflowed = lock.withLock {
            // Full 120 second captures have 3,750 non-overlapping 32 ms frames.
            // A stalled consumer cannot cause unbounded memory growth.
            guard results.count <= 3_750 - observations.count else { return true }
            observations.append(contentsOf: results)
            return false
        }
        if overflowed { fail(.voiceDetectionResultsOverflow) }
    }

    private func fail(_ error: SpeechAudioPipeline.Failure) {
        let firstFailure = lock.withLock {
            guard !failed else { return false }
            failed = true
            return true
        }
        if firstFailure { CaptureDiagnostics.record(event: .audioPipelineFailed, error: error) }
    }
}

/// An owned copy leaves the engine's callback without sharing its reused memory.
/// After construction the buffer is accessed exclusively by the serial worker.
final class OwnedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(copying source: AVAudioPCMBuffer) throws {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format,
                                         frameCapacity: source.frameLength) else {
            throw SpeechAudioPipeline.Failure.invalidFormat
        }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { throw SpeechAudioPipeline.Failure.invalidFormat }
        for index in from.indices {
            guard let sourceBytes = from[index].mData, let destinationBytes = to[index].mData,
                  from[index].mDataByteSize <= to[index].mDataByteSize else {
                throw SpeechAudioPipeline.Failure.invalidFormat
            }
            destinationBytes.copyMemory(from: sourceBytes, byteCount: Int(from[index].mDataByteSize))
        }
        buffer = copy
    }
}

/// Captures one bounded stream. Converter, writer and CPU VAD are only used
/// on queue after initialization. Admission and meter state are protected by
/// lock; stop closes admission before draining every accepted buffer.
final class SpeechAudioPipeline: @unchecked Sendable {
    enum Failure: Int, Error, CustomNSError, Equatable {
        // Stable, content-free diagnostic codes. Do not renumber existing cases.
        case invalidFormat = 1, classifierUnavailable = 2, overloaded = 3, conversionFailed = 4
        case discontinuousAudio = 5, writeFailed = 6, alreadyFinished = 7
        case bufferCopyFailed = 8, invalidTimestamp = 9
        case voiceDetectionFailed = 10, voiceDetectionInvalidResult = 11, voiceDetectionResultsOverflow = 12
        static var errorDomain: String { "OLIVAudioPipeline" }
        var errorCode: Int { rawValue }
    }

    struct Meter: Sendable {
        var duration: TimeInterval = 0
        var decibels: Float = -160
        var level: Double { max(0, min(1, (Double(decibels) + 55) / 55)) }
    }

    private let queue = DispatchQueue(label: "com.chayapat.oliv.audio-pipeline", qos: .userInitiated)
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let detector: SpeechActivityDetector?
    private let file: FileHandle
    private let maximumFrames: Int
    private let maximumQueuedFrames: Int
    private var accepting = true
    private var queuedFrames = 0
    private var failure: Failure?
    private var reportedFailure = false
    private var meterValue = Meter()
    // Worker-only state follows.
    private var writtenFrames = 0
    private var nextInputFrame: AVAudioFramePosition?
    private var finished = false
    private var header: Data

    init(url: URL, inputFormat: AVAudioFormat, detectSpeech: Bool = true,
         maximumDuration: TimeInterval = 120, maximumQueuedDuration: TimeInterval = 2) throws {
        guard inputFormat.sampleRate.isFinite, (8_000...192_000).contains(inputFormat.sampleRate),
              (1...8).contains(inputFormat.channelCount), maximumDuration.isFinite,
              maximumDuration > 0, maximumDuration <= 120,
              maximumQueuedDuration.isFinite, maximumQueuedDuration > 0,
              maximumQueuedDuration <= 4,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw Failure.invalidFormat
        }
        self.inputFormat = inputFormat
        outputFormat = output
        self.converter = converter
        converter.primeMethod = .none
        converter.downmix = true
        maximumFrames = Int(maximumDuration * 16_000)
        maximumQueuedFrames = Int(maximumQueuedDuration * inputFormat.sampleRate)
        detector = try detectSpeech ? SpeechActivityDetector(format: output) : nil
        header = try WAVEncoder.encode(samples: [])
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path,
                                             contents: header,
                                             attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                                          .posixPermissions: 0o600]) else {
            detector?.finish()
            throw Failure.writeFailed
        }
        do { file = try FileHandle(forUpdating: url) }
        catch {
            CaptureDiagnostics.record(event: .audioWriteFailed, error: error)
            detector?.finish()
            try? FileManager.default.removeItem(at: url)
            throw Failure.writeFailed
        }
    }

    var analysisFailed: Bool {
        let state = lock.withLock { () -> (Failure?, Bool) in
            let shouldReport = failure != nil && !reportedFailure
            if shouldReport { reportedFailure = true }
            return (failure, shouldReport)
        }
        // Report from the caller's normal thread, never from the input tap.
        if state.1, let error = state.0 { CaptureDiagnostics.record(event: .audioPipelineFailed, error: error) }
        return state.0 != nil || detector?.analysisFailed == true
    }
    var meter: Meter { lock.withLock { meterValue } }
    func takeSpeechObservations() -> [AudioSpeechObservation] { detector?.takeObservations() ?? [] }

    /// Returns false on an explicit failure or after stop. There is no silent
    /// dropping: an overloaded queue invalidates automatic endpoint detection.
    @discardableResult
    func submit(_ source: AVAudioPCMBuffer, atAudioFramePosition frame: AVAudioFramePosition? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, failure == nil else { return false }
        guard source.format == inputFormat, source.frameLength > 0 else {
            failure = .invalidFormat
            return false
        }
        let frames = Int(source.frameLength)
        guard frames <= maximumQueuedFrames - queuedFrames else {
            failure = .overloaded
            return false
        }
        let owned: OwnedAudioBuffer
        do { owned = try OwnedAudioBuffer(copying: source) }
        catch { failure = .bufferCopyFailed; return false }
        queuedFrames += frames
        // Enqueue while holding admission lock so finish cannot overtake a copy
        // which was accepted but has not reached the worker yet.
        queue.async { [self, owned] in
            defer { lock.withLock { queuedFrames -= frames } }
            guard lock.withLock({ failure == nil }) else { return }
            do { try process(owned.buffer, at: frame) }
            catch {
                lock.withLock { failure = (error as? Failure) ?? .writeFailed }
                if !(error is Failure) { CaptureDiagnostics.record(event: .audioWriteFailed, error: error) }
            }
        }
        return true
    }

    /// The microphone must already be stopped before this drains file/VAD work.
    /// It neither starts an engine nor activates an audio session.
    func finish() throws {
        lock.withLock { accepting = false }
        try queue.sync {
            guard !finished else { throw Failure.alreadyFinished }
            finished = true
            var closeError: (any Error)?
            do {
                if lock.withLock({ failure == nil }) { try flushConverter() }
                try file.synchronize()
            } catch { closeError = error }
            detector?.finish()
            do { try file.close() } catch { closeError = closeError ?? error }
            if let failure = lock.withLock({ failure }) { throw failure }
            if let closeError { throw closeError }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition?) throws {
        if let frame {
            guard frame >= 0 else { throw Failure.invalidTimestamp }
            guard nextInputFrame == nil || nextInputFrame == frame else {
                throw Failure.discontinuousAudio
            }
            nextInputFrame = frame + AVAudioFramePosition(buffer.frameLength)
        }
        guard writtenFrames < maximumFrames else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate)) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw Failure.conversionFailed
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else {
            CaptureDiagnostics.record(event: .audioConversionFailed, error: conversionError)
            throw Failure.conversionFailed
        }
        try append(output)
    }

    private func flushConverter() throws {
        // Bound the tail drain even if a converter fails to report endOfStream.
        for _ in 0..<32 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1_024) else {
                throw Failure.conversionFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, conversionError == nil else {
                CaptureDiagnostics.record(event: .audioConversionFailed, error: conversionError)
                throw Failure.conversionFailed
            }
            try append(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        throw Failure.conversionFailed
    }

    private func append(_ buffer: AVAudioPCMBuffer) throws {
        let count = min(Int(buffer.frameLength), maximumFrames - writtenFrames)
        guard count > 0, let samples = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        try file.seek(toOffset: UInt64(44 + writtenFrames * 2))
        try file.write(contentsOf: data)
        let startingFrame = writtenFrames
        writtenFrames += count
        // Publish both sizes in one header write after the samples. Before this
        // write, the previous header still describes a complete shorter WAV.
        updateHeaderSize(UInt32(36 + writtenFrames * 2), at: 4)
        updateHeaderSize(UInt32(writtenFrames * 2), at: 40)
        try file.seek(toOffset: 0)
        try file.write(contentsOf: header)
        var sum: Double = 0
        for index in 0..<count {
            let value = Double(samples[index]) / 32_768
            sum += value * value
        }
        let rms = sqrt(sum / Double(count))
        let db: Float = rms > 0 ? Float(max(-160, 20 * log10(rms))) : -160
        lock.withLock {
            meterValue = Meter(duration: Double(writtenFrames) / 16_000, decibels: db)
        }
        detector?.analyze(buffer, at: AVAudioFramePosition(startingFrame))
    }

    private func updateHeaderSize(_ size: UInt32, at offset: Int) {
        var value = size.littleEndian
        let data = withUnsafeBytes(of: &value) { Data($0) }
        header.replaceSubrange(offset..<(offset + 4), with: data)
    }
}
