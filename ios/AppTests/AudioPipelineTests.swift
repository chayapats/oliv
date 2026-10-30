import AVFoundation
import Foundation
import OlivCore
import XCTest
@testable import Oliv

final class AudioPipelineTests: XCTestCase {
    @MainActor
    func testRealAutomaticCaptureEngineRecordsAnalyzesAndRestartsWithoutNetworking() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AudioCaptureService(directory: directory)
        guard service.hasPermission else {
            throw XCTSkip("Microphone permission must already be granted for the live engine check.")
        }
        defer { service.discard() }
        for _ in 0..<2 {
            try await service.start(detectSpeech: true)
            try await Task.sleep(for: .milliseconds(1_200))
            XCTAssertGreaterThan(service.meter().duration, 0)
            XCTAssertFalse(service.analysisFailed)
            XCTAssertFalse(service.takeSpeechObservations().isEmpty,
                           "The actual engine must supply CPU-detected speech windows")
            let wav = try service.stop()
            let metadata = try WAVMetadata(data: wav)
            XCTAssertEqual(metadata.sampleRate, 16_000)
            XCTAssertEqual(metadata.channelCount, 1)
            XCTAssertEqual(metadata.bitsPerSample, 16)
            XCTAssertGreaterThan(metadata.duration, 0)
            XCTAssertEqual(wav.count, 44 + metadata.dataByteCount)
            XCTAssertEqual(service.meter().duration, 0)
            XCTAssertTrue(service.takeSpeechObservations().isEmpty)
            try service.removeRecoveredAudio()
        }
    }

    @MainActor
    func testIdleServiceDoesNotCreateRecordingOrSpeechWork() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AudioCaptureService(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.recoveryURL.path))
        XCTAssertEqual(service.meter().duration, 0)
        XCTAssertFalse(service.analysisFailed)
        XCTAssertTrue(service.takeSpeechObservations().isEmpty)
    }

    func testOwnedBufferDoesNotShareEngineMemory() throws {
        let source = try pcm(sampleRate: 48_000, channels: 2, duration: 0.01, amplitude: 0.25)
        let copy = try OwnedAudioBuffer(copying: source)
        let original = copy.buffer.floatChannelData![1][17]
        source.floatChannelData![1][17] = -1
        source.frameLength = 1
        XCTAssertEqual(copy.buffer.frameLength, 480)
        XCTAssertEqual(copy.buffer.floatChannelData![1][17], original)
        XCTAssertNotEqual(copy.buffer.floatChannelData![1][17], source.floatChannelData![1][17])
    }

    func testNativeStereoIsConvertedToCanonicalMono16KWithoutNetworking() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcm(sampleRate: 48_000, channels: 2, duration: 1, amplitude: 0.25)
        let url = directory.appendingPathComponent("conversion.wav")
        let pipeline = try SpeechAudioPipeline(url: url, inputFormat: source.format, detectSpeech: false)
        XCTAssertTrue(pipeline.submit(source, atAudioFramePosition: 0))
        try pipeline.finish()
        let wav = try Data(contentsOf: url)
        let metadata = try WAVMetadata(data: wav)
        XCTAssertEqual(metadata.sampleRate, 16_000)
        XCTAssertEqual(metadata.channelCount, 1)
        XCTAssertEqual(metadata.bitsPerSample, 16)
        XCTAssertEqual(metadata.duration, 1, accuracy: 0.01)
        XCTAssertEqual(wav.count, 44 + metadata.dataByteCount)
        XCTAssertEqual(try WAVEncoder.canonicalize(wav), wav)
        XCTAssertGreaterThan(pipeline.meter.decibels, -25)
        XCTAssertLessThan(pipeline.meter.decibels, -10)
        XCTAssertEqual(pipeline.meter.duration, metadata.duration)
        XCTAssertFalse(pipeline.analysisFailed)
    }

    func testMonoPCM16PreservesSamplesAtMatchingRate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_200))
        buffer.frameLength = 3_200
        let samples = (0..<3_200).map { Int16(($0 % 200) * 200 - 20_000) }
        for index in samples.indices { buffer.int16ChannelData![0][index] = samples[index] }
        let url = directory.appendingPathComponent("exact.wav")
        let pipeline = try SpeechAudioPipeline(url: url, inputFormat: format, detectSpeech: false)
        XCTAssertTrue(pipeline.submit(buffer))
        try pipeline.finish()
        XCTAssertEqual(try Data(contentsOf: url), try WAVEncoder.encode(samples: samples))
    }

    func testSampleRateConversionHandles44100AndMultipleBuffers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcm(sampleRate: 44_100, channels: 1, duration: 0.1, amplitude: 0.2)
        let url = directory.appendingPathComponent("fractional.wav")
        let pipeline = try SpeechAudioPipeline(url: url, inputFormat: source.format, detectSpeech: false)
        for index in 0..<10 {
            XCTAssertTrue(pipeline.submit(source, atAudioFramePosition: AVAudioFramePosition(index * 4_410)))
        }
        try pipeline.finish()
        let metadata = try WAVMetadata(data: Data(contentsOf: url))
        XCTAssertEqual(metadata.duration, 1, accuracy: 0.01)
        XCTAssertFalse(pipeline.analysisFailed)
    }

    func testRecordingCannotExceedMaximumSampleCount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcm(sampleRate: 48_000, channels: 1, duration: 1, amplitude: 0.2)
        let url = directory.appendingPathComponent("limited.wav")
        let pipeline = try SpeechAudioPipeline(url: url, inputFormat: source.format,
                                              detectSpeech: false, maximumDuration: 0.12)
        XCTAssertTrue(pipeline.submit(source))
        try pipeline.finish()
        XCTAssertEqual(try WAVMetadata(data: Data(contentsOf: url)).sampleCount, 1_920)
        XCTAssertEqual(pipeline.meter.duration, 0.12, accuracy: 0.0001)
    }

    func testOverloadedQueueFailsExplicitlyInsteadOfDroppingSpeech() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcm(sampleRate: 16_000, channels: 1, duration: 0.1, amplitude: 0.2)
        let url = directory.appendingPathComponent("overloaded.wav")
        let pipeline = try SpeechAudioPipeline(url: url, inputFormat: source.format,
                                              detectSpeech: false, maximumQueuedDuration: 0.01)
        XCTAssertFalse(pipeline.submit(source))
        XCTAssertTrue(pipeline.analysisFailed)
        XCTAssertThrowsError(try pipeline.finish()) {
            XCTAssertEqual($0 as? SpeechAudioPipeline.Failure, .overloaded)
        }
        XCTAssertTrue(pipeline.takeSpeechObservations().isEmpty)
        XCTAssertEqual(try WAVMetadata(data: Data(contentsOf: url)).sampleCount, 0)
    }

    func testTimestampGapCannotMasqueradeAsContinuousSpeechEvidence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcm(sampleRate: 16_000, channels: 1, duration: 0.1, amplitude: 0.2)
        let url = directory.appendingPathComponent("gap.wav")
        let pipeline = try SpeechAudioPipeline(url: url, inputFormat: source.format, detectSpeech: false)
        XCTAssertTrue(pipeline.submit(source, atAudioFramePosition: 0))
        XCTAssertTrue(pipeline.submit(source, atAudioFramePosition: 3_200))
        XCTAssertThrowsError(try pipeline.finish()) {
            XCTAssertEqual($0 as? SpeechAudioPipeline.Failure, .discontinuousAudio)
        }
        XCTAssertTrue(pipeline.analysisFailed)
        let metadata = try WAVMetadata(data: Data(contentsOf: url))
        XCTAssertGreaterThan(metadata.sampleCount, 0)
        XCTAssertLessThanOrEqual(metadata.sampleCount, 1_600)
    }

    func testFinishRejectsLateBuffersAndPreservesCompletedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcm(sampleRate: 16_000, channels: 1, duration: 0.1, amplitude: 0.2)
        let url = directory.appendingPathComponent("finished.wav")
        let pipeline = try SpeechAudioPipeline(url: url, inputFormat: source.format, detectSpeech: false)
        XCTAssertTrue(pipeline.submit(source))
        try pipeline.finish()
        let original = try Data(contentsOf: url)
        XCTAssertFalse(pipeline.submit(source))
        XCTAssertThrowsError(try pipeline.finish()) {
            XCTAssertEqual($0 as? SpeechAudioPipeline.Failure, .alreadyFinished)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testStartingPipelineCannotOverwriteRecoveryFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcm(sampleRate: 16_000, channels: 1, duration: 0.1, amplitude: 0)
        let url = directory.appendingPathComponent("recovery.wav")
        let original = try WAVEncoder.encode(samples: [1, 2, 3, 4])
        try original.write(to: url)
        XCTAssertThrowsError(try SpeechAudioPipeline(url: url, inputFormat: source.format, detectSpeech: false))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCPUVoiceDetectorEmitsTimedNonSpeechForSyntheticSilence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcm(sampleRate: 16_000, channels: 1, duration: 2, amplitude: 0)
        let pipeline = try SpeechAudioPipeline(url: directory.appendingPathComponent("silence.wav"),
                                              inputFormat: source.format)
        XCTAssertTrue(pipeline.submit(source, atAudioFramePosition: 0))
        try pipeline.finish()
        XCTAssertFalse(pipeline.analysisFailed)
        let observations = pipeline.takeSpeechObservations()
        XCTAssertFalse(observations.isEmpty, "Exercise the actual CPU detector, not a fake observation source")
        XCTAssertTrue(observations.allSatisfy { !$0.isSpeech && $0.startTime >= 0 && $0.endTime > $0.startTime })
        XCTAssertTrue(observations.allSatisfy { $0.endTime <= 2.01 })
        XCTAssertTrue(pipeline.takeSpeechObservations().isEmpty, "Results must be consumed only once")
    }

    func testCPUDetectorRejectsDiscontinuousInputWithoutManufacturingSilence() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        buffer.int16ChannelData![0].initialize(repeating: 0, count: 1_600)
        let detector = try SpeechActivityDetector(format: format)
        detector.analyze(buffer, at: 0)
        let initial = detector.takeObservations()
        XCTAssertFalse(initial.isEmpty)
        detector.analyze(buffer, at: 3_200)
        XCTAssertTrue(detector.analysisFailed)
        XCTAssertTrue(detector.takeObservations().isEmpty)
        detector.finish()
        XCTAssertTrue(detector.analysisFailed)
        XCTAssertTrue(detector.takeObservations().isEmpty)
    }

    func testCPUDetectorDoesNotInventSilenceForPartialFrameAtFinish() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 511))
        buffer.frameLength = 511
        buffer.int16ChannelData![0].initialize(repeating: 0, count: 511)
        let detector = try SpeechActivityDetector(format: format)
        detector.analyze(buffer, at: 0)
        XCTAssertTrue(detector.takeObservations().isEmpty)
        detector.finish()
        XCTAssertFalse(detector.analysisFailed)
        XCTAssertTrue(detector.takeObservations().isEmpty,
                      "A partial frame must never be padded into false silence evidence")
        detector.analyze(buffer, at: 511)
        XCTAssertTrue(detector.takeObservations().isEmpty, "Finish closes the detector")
    }

    func testCPUDetectorCarriesResidualSamplesAcrossIrregularBuffers() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: true))
        let detector = try SpeechActivityDetector(format: format)
        var position: AVAudioFramePosition = 0
        for count in [127, 383, 257, 257] {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            buffer.int16ChannelData![0].initialize(repeating: 0, count: count)
            detector.analyze(buffer, at: position)
            position += AVAudioFramePosition(count)
        }
        detector.finish()
        XCTAssertFalse(detector.analysisFailed)
        XCTAssertEqual(detector.takeObservations(), [
            AudioSpeechObservation(startTime: 0, endTime: 0.032, isSpeech: false),
            AudioSpeechObservation(startTime: 0.032, endTime: 0.064, isSpeech: false)
        ])
    }

    func testCPUDetectorHasNoCrossSessionSpeechState() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        buffer.int16ChannelData![0].initialize(repeating: 0, count: 8_000)
        var baseline: [AudioSpeechObservation]?
        for _ in 0..<2 {
            let detector = try SpeechActivityDetector(format: format)
            XCTAssertEqual(detector.computeUnits, .cpuOnly, "The loaded model must never request background GPU work")
            detector.analyze(buffer, at: 0)
            detector.finish()
            let result = detector.takeObservations()
            XCTAssertFalse(result.isEmpty)
            XCTAssertFalse(detector.analysisFailed)
            XCTAssertTrue(result.allSatisfy { !$0.isSpeech })
            if let baseline { XCTAssertEqual(result, baseline) }
            else { baseline = result }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pcm(sampleRate: Double, channels: AVAudioChannelCount,
                     duration: TimeInterval, amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                               channels: channels, interleaved: false))
        let count = AVAudioFrameCount(sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(count) {
                samples[frame] = amplitude * Float(sin(Double(frame) * 2 * .pi * 440 / sampleRate))
            }
        }
        return buffer
    }
}
