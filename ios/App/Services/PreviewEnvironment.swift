#if DEBUG
import Foundation
import Observation
import OlivCore
import UIKit

/// Explicitly labelled Debug fixtures: no real token, microphone, or network.
@MainActor
enum PreviewEnvironment {
    static func makeModel() -> AppModel {
        let args = ProcessInfo.processInfo.arguments
        let realAudioFixture = args.contains("--real-audio-background-test")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            realAudioFixture ? "OLIV-Audio-Probe-Model-\(UUID().uuidString)" : "OLIV-UI-Fixtures")
        if !args.contains("--preserve-test-data") { try? FileManager.default.removeItem(at: directory) }
        let mode: FixtureOlivService.Mode = args.contains("--fail-once") ? .failOnce
            : args.contains("--no-speech") ? .noSpeech
            : args.contains("--slow") ? .slow : .success
        let service = FixtureOlivService(mode: mode)
        let automaticKeyboardFixture = args.contains("--keyboard-test-host")
            && args.contains("--keyboard-auto-finish-fixture")
        let firstRun = args.contains("--first-run")
        let model = AppModel(directory: directory,
            credentials: MemoryCredentialStore(token: firstRun ? nil : "fixture-token"),
            capture: FixtureAudioCapture(directory: directory,
                                         synthesizesSpeechObservations: automaticKeyboardFixture),
            liveActivitiesEnabled: false,
            keyboardDelivery: !realAudioFixture && (args.contains("--keyboard-test-host") || args.contains("--keyboard-integration-demo"))
                ? KeyboardDeliveryCoordinator.makeDefault() : nil,
            clientFactory: { _ in service },
            requestTrialKey: { _ in TrialKey(token: "fixture-trial", expiresAt: Date().addingTimeInterval(604_800)) })
        if firstRun {
            model.isDemo = true
            model.trialServerURL = "https://oliv.example"
            return model
        }
        model.settings.serverURL = "https://oliv.example"
        model.tokenInput = "fixture-token"
        if args.contains("--keyboard-test-host") {
            // Existing handoff tests deliberately finish/cancel by explicit UI
            // actions. Only the separately named fixture emits synthetic VAD.
            model.settings.automaticActionButtonFinish = automaticKeyboardFixture
        }
        model.saveSettings()
        model.finishSetup()
        model.isDemo = true
        if args.contains("--unconfigured") {
            model.settings.serverURL = ""
        }
        return model
    }
}

/// Explicit Debug-only hardware diagnostic. It owns no client, credentials,
/// transcript, history store, keyboard bridge or AppModel capture operation.
/// Only the audio service is real; the private temporary WAV is always discarded.
@MainActor @Observable
final class RealAudioBackgroundProbe {
    private(set) var phase = "idle"
    private(set) var failure = "none"
    private(set) var duration: TimeInterval = 0
    private(set) var observationCount = 0
    private(set) var backgroundObservationCount = 0
    private(set) var backgroundAudioSeconds: TimeInterval = 0
    private(set) var backgroundWallSeconds: TimeInterval = 0
    private(set) var backgroundSeen = false
    private(set) var hasResidualCaptureState = false
    private(set) var permissionGranted: Bool
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let capture: AudioCaptureService
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var backgroundStarted: ContinuousClock.Instant?
    @ObservationIgnored private var backgroundStartDuration: TimeInterval = 0

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OLIV-Real-Audio-Probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        capture = AudioCaptureService(directory: directory)
        permissionGranted = capture.hasPermission
        capture.onInterruption = { [weak self] in self?.finish(reason: "interrupted") }
    }

    func start() { Task { await begin() } }

    private func begin() async {
        guard phase != "recording", phase != "starting" else { return }
        // Tests must use an already-authorized device. This diagnostic never
        // requests a permission change or starts merely because its view opened.
        permissionGranted = capture.hasPermission
        guard permissionGranted else { failure = "permission_denied"; phase = "failed"; return }
        failure = "none"
        duration = 0
        observationCount = 0
        backgroundObservationCount = 0
        backgroundAudioSeconds = 0
        backgroundWallSeconds = 0
        backgroundSeen = false
        backgroundStarted = nil
        hasResidualCaptureState = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            phase = "starting"
            try await capture.start(detectSpeech: true)
            phase = "recording"
        } catch {
            // Stop already discarded a start that was waiting to retry.
            guard phase == "starting" else { return }
            capture.discard()
            failure = "start_failed"
            phase = "failed"
            return
        }
        monitor = Task { @MainActor [weak self] in
            let started = ContinuousClock.now
            var progressedAt = started
            var previousDuration: TimeInterval = 0
            while !Task.isCancelled {
                guard let self, self.phase == "recording" else { return }
                let now = ContinuousClock.now
                self.sample()
                if self.capture.analysisFailed { self.finish(reason: "analysis_failed"); return }
                if self.duration > previousDuration {
                    previousDuration = self.duration
                    progressedAt = now
                }
                if progressedAt.duration(to: now) >= .seconds(3) {
                    self.finish(reason: "audio_stalled"); return
                }
                // Independent of PCM time and classification: no diagnostic
                // recording can intentionally run beyond this eight-second cap.
                if started.duration(to: now) >= .seconds(8) {
                    self.finish(); return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
    }

    func enteredBackground() {
        guard phase == "recording", backgroundStarted == nil else { return }
        sample()
        backgroundSeen = true
        backgroundStartDuration = duration
        backgroundStarted = .now
    }

    func becameActive() {
        guard backgroundStarted != nil else { return }
        sample()
        updateBackgroundProgress()
        backgroundStarted = nil
    }

    func finish(reason: String? = nil) {
        if phase == "starting" {
            capture.discard()
            failure = reason ?? failure
            phase = failure == "none" ? "stopped" : "failed"
            return
        }
        guard phase == "recording" else { return }
        sample()
        monitor?.cancel()
        monitor = nil
        if let reason { failure = reason }
        do { _ = try capture.stop() }
        catch { if failure == "none" { failure = "stop_failed" } }
        if capture.analysisFailed { failure = "analysis_failed" }
        if observationCount == 0, failure == "none" { failure = "no_classifications" }
        capture.discard()
        hasResidualCaptureState = capture.meter().duration != 0
            || !capture.takeSpeechObservations().isEmpty
            || FileManager.default.fileExists(atPath: capture.recoveryURL.path)
        if hasResidualCaptureState { failure = "cleanup_failed" }
        phase = failure == "none" ? "stopped" : "failed"
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample() {
        if phase == "recording" {
            duration = max(duration, capture.meter().duration)
            let newObservations = capture.takeSpeechObservations().count
            observationCount += newObservations
            // Count work observed while genuinely backgrounded, not callbacks
            // that only resume after XCTest brings the app to the foreground.
            if backgroundStarted != nil, UIApplication.shared.applicationState == .background {
                backgroundObservationCount += newObservations
                backgroundAudioSeconds = max(backgroundAudioSeconds, duration - backgroundStartDuration)
            }
        }
        updateBackgroundProgress()
    }

    private func updateBackgroundProgress() {
        guard let backgroundStarted else { return }
        let elapsed = backgroundStarted.duration(to: .now)
        backgroundWallSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}

actor FixtureOlivService: OlivServing {
    enum Mode { case success, failOnce, noSpeech, slow, cleanupFallback }
    private let mode: Mode
    private(set) var dictateCalls = 0
    private(set) var cleanCalls = 0
    private(set) var lastOptions: OlivOptions?
    private var dictionaryEntries: [DictionaryEntry] = []
    private var dictionaryRevision = 0
    init(mode: Mode = .success) { self.mode = mode }

    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply {
        dictateCalls += 1
        lastOptions = options
        _ = try WAVMetadata(data: wav)
        try await Task.sleep(for: mode == .slow ? .seconds(10) : .milliseconds(250))
        if mode == .failOnce && dictateCalls == 1 { throw OlivError.networkUnavailable }
        if mode == .noSpeech { return DictationReply(noSpeech: true, gateReason: "no_speech") }
        return Self.reply(cleanupFallback: mode == .cleanupFallback)
    }
    func clean(text: String, options: OlivOptions) async throws -> DictationReply {
        cleanCalls += 1
        lastOptions = options
        if text.isEmpty { return DictationReply(noSpeech: true) }
        try await Task.sleep(for: .milliseconds(100))
        return DictationReply(raw: text, finalText: text.trimmingCharacters(in: .whitespacesAndNewlines), tCleanup: 0.1)
    }
    /// An in-memory server dictionary, so demos show sync working.
    func dictionary(ops: [DictionaryOp]?) async throws -> DictionarySnapshot {
        if let ops, !ops.isEmpty {
            dictionaryEntries = DictionaryOp.apply(ops, to: dictionaryEntries)
            dictionaryRevision += 1
        }
        return DictionarySnapshot(revision: dictionaryRevision, maxEntries: 1000, entries: dictionaryEntries)
    }
    func health() async throws -> ServerHealth {
        try JSONDecoder().decode(ServerHealth.self, from: Data(
            #"{"ok":true,"whisper":true,"gemma":true,"version":"fixture","prompt":"v5","llm_timeout":5}"#.utf8))
    }
    func verifyKey() async throws {}
    static func reply(cleanupFallback: Bool = false) -> DictationReply {
        DictationReply(raw: "เอ่อ พรุ่งนี้ส่ง design ให้ทีม review ตอนเก้าโมงนะครับ",
            finalText: "พรุ่งนี้ส่ง design ให้ทีม review ตอน 9 โมงนะครับ",
            tSTT: 0.61, tCleanup: 0.18, llmRan: true, gateReason: "cleanup",
            cleanupError: cleanupFallback ? "fixture-unavailable" : nil,
            fillersRemoved: 1, thaiFormatFired: 1)
    }
}

@MainActor
final class FixtureAudioCapture: AudioCapturing {
    let recoveryURL: URL
    var hasPermission = true
    var permissionDenied = false
    var onInterruption: (() -> Void)?
    var startedAt: Date?
    var startCount = 0
    var discardCount = 0
    var audioDuration: Double = 1.0
    var startError: (any Error)?
    private let synthesizesSpeechObservations: Bool
    private var speechDetectionEnabled = false
    private var nextSpeechWindow = 0
    init(directory: URL, synthesizesSpeechObservations: Bool = false) {
        recoveryURL = directory.appendingPathComponent("fixture-inflight.wav")
        self.synthesizesSpeechObservations = synthesizesSpeechObservations
    }
    func requestPermission() async -> Bool { hasPermission }
    func start() throws { try start(detectSpeech: false) }
    func start(detectSpeech: Bool) throws {
        if let startError { throw startError }
        startCount += 1
        startedAt = .now
        speechDetectionEnabled = detectSpeech && synthesizesSpeechObservations
        nextSpeechWindow = 0
    }
    func takeSpeechObservations() -> [AudioSpeechObservation] {
        guard speechDetectionEnabled, let startedAt else { return [] }
        let elapsed = min(120, max(0, Date().timeIntervalSince(startedAt)))
        var observations: [AudioSpeechObservation] = []
        // This is a scripted detector timeline, not SoundAnalysis or real audio:
        // overlapping half-second windows report two seconds of speech, then
        // silence. Emit each completed window once, as the live detector does.
        while Double(nextSpeechWindow) * 0.25 + 0.5 <= elapsed {
            let start = Double(nextSpeechWindow) * 0.25
            let end = start + 0.5
            observations.append(AudioSpeechObservation(startTime: start, endTime: end,
                                                       isSpeech: end <= 2))
            nextSpeechWindow += 1
        }
        return observations
    }
    func meter() -> (duration: TimeInterval, level: Double, decibels: Float) {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        return (elapsed, 0.2 + abs(sin(elapsed * 4)) * 0.6, -20)
    }
    func stop() throws -> Data {
        let duration = speechDetectionEnabled
            ? min(120, max(0.1, startedAt.map { Date().timeIntervalSince($0) } ?? 0))
            : audioDuration
        startedAt = nil
        speechDetectionEnabled = false
        let samples = (0..<Int(duration * 16_000)).map { Int16(sin(Double($0) * .pi / 20) * 3000) }
        return try WAVEncoder.encode(samples: samples)
    }
    func discard() {
        startedAt = nil
        speechDetectionEnabled = false
        nextSpeechWindow = 0
        discardCount += 1
    }
    func removeRecoveredAudio() throws {
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            try FileManager.default.removeItem(at: recoveryURL)
        }
    }
}
#endif
