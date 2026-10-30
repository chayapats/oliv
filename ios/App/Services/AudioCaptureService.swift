import AVFoundation
import Foundation
import OlivCore

/// No audio session, engine, timer, or microphone remains active while idle.
@MainActor
protocol AudioCapturing: AnyObject {
    var recoveryURL: URL { get }
    var hasPermission: Bool { get }
    var permissionDenied: Bool { get }
    var analysisFailed: Bool { get }
    var onInterruption: (() -> Void)? { get set }
    func requestPermission() async -> Bool
    func start() async throws
    func start(detectSpeech: Bool) async throws
    func takeSpeechObservations() -> [AudioSpeechObservation]
    func meter() -> (duration: TimeInterval, level: Double, decibels: Float)
    func stop() throws -> Data
    func discard()
    func removeRecoveredAudio() throws
}

extension AudioCapturing {
    var permissionDenied: Bool { false }
    var analysisFailed: Bool { false }
    func start(detectSpeech: Bool) async throws { try await start() }
    func takeSpeechObservations() -> [AudioSpeechObservation] { [] }
}

/// A cancel discarded this start while its engine waited to retry.
struct AudioStartSuperseded: Error {}

@MainActor
final class AudioCaptureService: NSObject, AVAudioRecorderDelegate, AudioCapturing {
    static let maximumDuration: TimeInterval = 120
    let recoveryURL: URL
    private var recorder: AVAudioRecorder?
    private var engine: AVAudioEngine?
    private var pipeline: SpeechAudioPipeline?
    private var stoppedAnalysisFailed = false
    private var engineHasStarted = false
    private var reportedEngineStop = false
    var onInterruption: (() -> Void)?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    init(directory: URL) {
        recoveryURL = directory.appendingPathComponent("inflight.wav")
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor [weak self] in self?.onInterruption?() }
            }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor [weak self] in self?.onInterruption?() }
            }
        }
    }

    var hasPermission: Bool { AVAudioApplication.shared.recordPermission == .granted }
    var permissionDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }
    func requestPermission() async -> Bool {
        if hasPermission { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    var analysisFailed: Bool {
        let pipelineFailed = pipeline?.analysisFailed == true
        let engineStopped = engineHasStarted && engine?.isRunning == false
        if engineStopped, !reportedEngineStop {
            reportedEngineStop = true
            CaptureDiagnostics.record(event: .audioEngineStoppedUnexpectedly)
        }
        return stoppedAnalysisFailed || pipelineFailed || engineStopped
    }

    func takeSpeechObservations() -> [AudioSpeechObservation] {
        pipeline?.takeSpeechObservations() ?? []
    }

    func start() async throws { try await start(detectSpeech: false) }

    func start(detectSpeech: Bool) async throws {
        guard hasPermission else { throw AppCaptureError.microphoneDenied }
        guard recorder == nil, engine == nil, pipeline == nil else { throw AppCaptureError.unavailable }
        stoppedAnalysisFailed = false
        reportedEngineStop = false
        guard !FileManager.default.fileExists(atPath: recoveryURL.path) else {
            throw OlivError.invalidAudio(String(localized: "An interrupted recording is still waiting to be recovered. Relaunch OLIV before recording again."))
        }
        let session = AVAudioSession.sharedInstance()
        do {
            CaptureDiagnostics.record(event: .audioSessionConfiguring)
            // A record-only session is nonmixable, so a background intent cannot
            // activate it while another app owns audio. We create no playback;
            // playAndRecord permits a non-interrupting microphone session.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setPreferredSampleRate(16_000)
            CaptureDiagnostics.record(event: .audioSessionConfigured)
            CaptureDiagnostics.record(event: .audioSessionActivating)
            try session.setActive(true)
            CaptureDiagnostics.record(event: .audioSessionActivated)
            if detectSpeech {
                try await startSpeechEngine()
                return
            }
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            CaptureDiagnostics.record(event: .recorderStarting)
            let newRecorder = try AVAudioRecorder(url: recoveryURL, settings: audioSettings)
            newRecorder.delegate = self
            newRecorder.isMeteringEnabled = true
            guard newRecorder.prepareToRecord(), newRecorder.record(forDuration: Self.maximumDuration) else {
                throw AppCaptureError.unavailable
            }
            recorder = newRecorder
            CaptureDiagnostics.record(event: .recorderStarted)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: recoveryURL.path)
        } catch is AudioStartSuperseded {
            // Whoever discarded it already cleaned up, and a newer start may own the session.
            throw CancellationError()
        } catch {
            let wasAnalysisFailed = analysisFailed
            recorder?.stop()
            recorder = nil
            stopEngine()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? pipeline?.finish()
            stoppedAnalysisFailed = wasAnalysisFailed || pipeline?.analysisFailed == true
            pipeline = nil
            // A failed start must not leave a file that blocks every subsequent attempt.
            try? FileManager.default.removeItem(at: recoveryURL)
            throw error
        }
    }

    private func startSpeechEngine() async throws {
        CaptureDiagnostics.record(event: .recorderStarting)
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let newPipeline = try SpeechAudioPipeline(url: recoveryURL, inputFormat: format)
        // Store ownership before installing the tap so any startup error can
        // stop input, drain the worker and close the private recovery file.
        engine = newEngine
        pipeline = newPipeline
        // AVAudioNodeTapBlock predates Swift concurrency. Mark this closure
        // explicitly Sendable so it does not inherit the service's MainActor;
        // AVAudioEngine invokes it on its own realtime messenger queue.
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable [newPipeline] buffer, time in
            newPipeline.submit(buffer, atAudioFramePosition: time.isSampleTimeValid ? time.sampleTime : nil)
        }
        newEngine.prepare()
        CaptureDiagnostics.record(event: .audioEngineStarting)
        try await Self.startWithRetry(isCurrent: { [weak self] in self?.engine === newEngine }) {
            try newEngine.start()
        }
        engineHasStarted = true
        CaptureDiagnostics.record(event: .recorderStarted)
    }

    /// The input can be briefly unavailable right after activation: real devices
    /// have reported 2003329396 (`what`) here while a later start succeeded.
    /// Only the engine retries: the session stays active, because a process
    /// launched in the background can't activate it again. The wait yields the
    /// main actor, so `isCurrent` must hold before touching the audio again.
    static func startWithRetry(delay: Duration = .milliseconds(250), isCurrent: () -> Bool,
                               start: () throws -> Void) async throws {
        for attempt in 1...3 {
            do { return try start() }
            catch where attempt < 3 {
                CaptureDiagnostics.record(event: .audioEngineStartRetry, error: error)
                try await Task.sleep(for: delay)
                guard isCurrent() else { throw AudioStartSuperseded() }
            }
        }
    }

    func meter() -> (duration: TimeInterval, level: Double, decibels: Float) {
        if let pipeline {
            let reading = pipeline.meter
            return (reading.duration, reading.level, reading.decibels)
        }
        recorder?.updateMeters()
        let db = recorder?.averagePower(forChannel: 0) ?? -160
        return (recorder?.currentTime ?? 0, max(0, min(1, (Double(db) + 55) / 55)), db)
    }

    func stop() throws -> Data {
        let wasAnalysisFailed = analysisFailed
        recorder?.stop()
        recorder = nil
        stopEngine()
        let completedPipeline = pipeline
        pipeline = nil
        defer {
            // The last voice-detection work can fail while finish drains it.
            // Keep that evidence available to the caller before any upload.
            stoppedAnalysisFailed = wasAnalysisFailed || completedPipeline?.analysisFailed == true
        }
        // Release the microphone before waiting for any file or CPU VAD work.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try completedPipeline?.finish()
        return try Data(contentsOf: recoveryURL)
    }

    func discard() {
        let wasAnalysisFailed = analysisFailed
        recorder?.stop()
        recorder = nil
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? pipeline?.finish()
        stoppedAnalysisFailed = wasAnalysisFailed || pipeline?.analysisFailed == true
        pipeline = nil
        try? FileManager.default.removeItem(at: recoveryURL)
    }

    private func stopEngine() {
        guard let engine else { return }
        engineHasStarted = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    func removeRecoveredAudio() throws {
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            try FileManager.default.removeItem(at: recoveryURL)
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let finishedID = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            // Explicit stop clears recorder synchronously; only a device/limit stop calls back.
            if let current = self?.recorder, ObjectIdentifier(current) == finishedID { self?.onInterruption?() }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let failedID = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            if let current = self?.recorder, ObjectIdentifier(current) == failedID { self?.onInterruption?() }
        }
    }
}
