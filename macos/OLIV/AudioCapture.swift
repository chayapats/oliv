// Push-to-talk audio capture — a Swift port of app/audio.py (W1-T3).
//
// Turns a press/record/release into a 16 kHz MONO Float32 sample buffer (the
// STT stage's array contract). start() opens an AVAudioEngine input tap and
// accumulates converted samples; stop() ends capture and returns the buffer.
//
// Samplerate: we NEVER assume the mic is natively 16 kHz (some devices only
// expose 44.1/48 kHz). We read the hardware input format and run every buffer
// through an AVAudioConverter down to 16 kHz mono Float32 — the AVFoundation
// analogue of app/audio.py's resample-on-stop path, done streaming here.
//
// The HARDENED STOP (the core Wave-1 lesson):
// Core Audio's stop() wedged >8 minutes at 0% CPU on this machine when
// coreaudiod/HAL got into a bad state, with identical code passing moments
// later. A dictation app must NEVER lose the captured utterance to that, so
// stop() is BOUNDED: the blocking engine-stop / tap-removal runs on a utility
// queue and we wait only a bounded interval (boundedTeardown, the Swift port of
// audio.py's _bounded_call). On timeout we ABANDON the wedged engine instance,
// log loudly, still return every sample captured so far, and leave this object
// reusable (start() builds a fresh engine next time). boundedTeardown is a pure,
// mic-free seam so the timeout logic unit-tests with a wedge-simulating closure,
// exactly like audio.py's _WedgedStream fake — see AudioCaptureTests.
//
// Mic permission: preflight via AVCaptureDevice.authorizationStatus(for:.audio)
// and requestAccess (mirrors app.audio.check_microphone_access). Surfaced as a
// typed MicAuthorization; never crashes when denied.
//
// LIVE LEVEL METERING (W4-T2 recording HUD): the tap ALSO computes a lightweight
// per-buffer RMS on the RAW hardware buffer, rate-limits it to ~24 Hz, maps it to
// a 0…1 display level, and hands it to `onLevel` on the MAIN queue for the
// SwiftUI waveform. This is a strictly ADDITIVE side channel — it never touches
// the 16 kHz sample accumulation (appendConverted) or decodeFile, so the captured
// utterance and the `--e2e-file` byte output are provably unchanged. The two
// testable seams (LevelThrottle cadence, normalizedLevel mapping) are pure and
// mic-free, exercised in AudioCaptureTests.

import AVFoundation
import Foundation

final class AudioCapture {
    /// macOS Microphone (TCC) authorization, mirroring app.audio's status names.
    enum MicAuthorization: Equatable {
        case authorized
        case denied
        case restricted
        case notDetermined
        case unknown
    }

    /// Stats for one start()/stop() cycle (subset of app.audio.CaptureStats).
    struct CaptureStats: Equatable {
        var durationSeconds: Double = 0
        var sampleCount: Int = 0
        var sampleRate: Double = AudioCapture.targetSampleRate
        var deviceSampleRate: Double = AudioCapture.targetSampleRate
        var peak: Float = 0
        var rms: Float = 0
        /// The engine stop wedged and was abandoned; audio salvaged. Port of
        /// CaptureStats.stop_forced.
        var stopForced: Bool = false
        /// The capture hit maxCaptureSamples and the tail was dropped — carried
        /// here so the release worker can TELL the user instead of cutting
        /// silently (same describe-the-salvage stance as stopForced).
        var capped: Bool = false
    }

    enum CaptureError: Error, CustomStringConvertible {
        case alreadyRunning
        case converterUnavailable
        case engineStartFailed(Error)

        var description: String {
            switch self {
            case .alreadyRunning:
                return "AudioCapture already started — call stop() before starting again"
            case .converterUnavailable:
                return "could not build the 16 kHz mono AVAudioConverter from the hardware format"
            case let .engineStartFailed(error):
                return "AVAudioEngine failed to start: \(error)"
            }
        }
    }

    static let targetSampleRate: Double = 16000

    // Hard ceiling on ONE capture: 10 minutes at 16 kHz (~37 MB of Float32).
    // Push-to-talk bounds a real utterance to seconds; the ceiling is defence
    // against a missed release / stuck hotkey growing the buffer — and its
    // Data/base64/JSON copies downstream — without bound. Frames past it are
    // dropped (first-N wins), logged once per capture.
    static let maxCaptureSeconds: TimeInterval = 600
    static let maxCaptureSamples = Int(maxCaptureSeconds * targetSampleRate)

    // Bounded-stop budget. audio.py staged 1s graceful + 2s + 2s forced; a
    // single 3s ceiling on the AVAudioEngine teardown is the equivalent guard
    // here — comfortably under the "never wedge the app" bar, well below the
    // >8min failure it defends against.
    static let stopTimeout: TimeInterval = 3.0

    private let lifecycleLock = NSLock()
    private var engine: AVAudioEngine?
    private var deviceSampleRate: Double = AudioCapture.targetSampleRate

    private let bufferLock = NSLock()
    private var samples: [Float] = []
    private var capReported = false   // guarded by bufferLock; reset per start()

    // Live input-level metering (W4-T2 HUD). Guarded by its own lock: the tap's
    // render thread reads the sink + throttle while the main thread sets them.
    private let levelLock = NSLock()
    private var _onLevel: ((Float) -> Void)?
    private var levelThrottle = LevelThrottle(minInterval: AudioCapture.levelInterval)

    /// ~24 Hz level cadence (min seconds between level callbacks) — smooth enough
    /// for the waveform, cheap enough to stay off the render thread's back.
    static let levelInterval: TimeInterval = 1.0 / 24.0

    /// Live 0…1 input-level sink for the recording HUD. Set before start();
    /// invoked on the MAIN queue, throttled to ~24 Hz; nil = no metering.
    /// Thread-safe (render thread reads while the main thread sets).
    var onLevel: ((Float) -> Void)? {
        get { levelLock.lock(); defer { levelLock.unlock() }; return _onLevel }
        set { levelLock.lock(); _onLevel = newValue; levelLock.unlock() }
    }

    // Teardown runs on a FRESH queue per stop so a wedged closure blocks only
    // its own (abandoned) worker: a shared serial queue would line every later
    // teardown up behind the first permanent wedge, turning one bad Core Audio
    // stop into a guaranteed timeout on every stop after it. Queues are cheap;
    // a wedged one leaks together with the engine it was tearing down.
    static func makeTeardownQueue() -> DispatchQueue {
        DispatchQueue(label: "com.oliv.audio-teardown", qos: .utility)
    }

    private(set) var stats: CaptureStats?

    var isRunning: Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return engine != nil
    }

    // MARK: Permission (mirrors app.audio.check_microphone_access)

    func authorizationStatus() -> MicAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// Trigger the system mic prompt (only if not yet determined). `granted` is
    /// delivered on an arbitrary queue, per AVFoundation.
    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    // MARK: Capture

    /// Begin accumulating 16 kHz mono Float32 samples. Non-blocking. Throws on
    /// misuse (already running) or if the mic/engine can't be opened.
    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if engine != nil { throw CaptureError.alreadyRunning }

        bufferLock.lock()
        samples = []
        capReported = false
        bufferLock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        deviceSampleRate = hardwareFormat.sampleRate

        // Always convert from the ACTUAL hardware format — do not assume 16k.
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioCapture.targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: hardwareFormat, to: outputFormat)
        else {
            throw CaptureError.converterUnavailable
        }

        // Fresh throttle per capture so every recording's meter starts live.
        levelLock.lock(); levelThrottle.reset(); levelLock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            // Runs on AVAudioEngine's render thread — keep it lean.
            self?.appendConverted(buffer, using: converter, outputFormat: outputFormat)
            self?.emitLevel(from: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }
        self.engine = engine
    }

    /// End capture and return the full 16 kHz mono Float32 buffer, refreshing
    /// `stats`. BOUNDED: never blocks longer than `stopTimeout` even if the
    /// engine teardown wedges — the utterance is returned in every case, with
    /// `stats.stopForced == true` when the engine had to be abandoned.
    ///
    /// Parity note: app/audio.py's Recorder.stop() RAISES on no active capture;
    /// here we return an empty buffer + zeroed stats and log, so the
    /// DictationController coordinator can never crash on a stray release.
    @discardableResult
    func stop() -> [Float] {
        lifecycleLock.lock()
        guard let engine = self.engine else {
            lifecycleLock.unlock()
            NSLog("OLIV AudioCapture: stop() with no active capture — returning empty buffer")
            let stats = CaptureStats()
            self.stats = stats
            return []
        }
        // Detach immediately so a wedged teardown can't block a fresh start().
        self.engine = nil
        let deviceSampleRate = self.deviceSampleRate
        lifecycleLock.unlock()

        let completed = AudioCapture.boundedTeardown(
            timeout: AudioCapture.stopTimeout, queue: AudioCapture.makeTeardownQueue()) {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let stopForced = !completed
        if stopForced {
            // Abandon the wedged engine (its teardown may finish later on the
            // utility queue). Port of audio.py "leak the wedged stream, salvage
            // the audio". `self.engine` is already nil → object is reusable.
            NSLog("OLIV AudioCapture: engine teardown did not return within "
                + "\(AudioCapture.stopTimeout)s — abandoning wedged engine, salvaging captured audio "
                + "(port of app/audio.py hardened stop)")
        }

        bufferLock.lock()
        let captured = samples
        let capped = capReported
        samples = []
        bufferLock.unlock()

        let stats = AudioCapture.computeStats(
            samples: captured,
            deviceSampleRate: deviceSampleRate,
            stopForced: stopForced,
            capped: capped
        )
        self.stats = stats
        return captured
    }

    // MARK: Internals

    private func appendConverted(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) {
        guard input.frameLength > 0 else { return }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 16
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { return }

        let frames = Int(output.frameLength)
        guard frames > 0, let channel = output.floatChannelData else { return }
        let pointer = channel[0]
        bufferLock.lock()
        let budget = AudioCapture.appendBudget(
            current: samples.count, incoming: frames, limit: AudioCapture.maxCaptureSamples)
        if budget > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: budget))
        }
        let reportCap = budget < frames && !capReported
        if reportCap { capReported = true }
        bufferLock.unlock()
        if reportCap {
            NSLog("OLIV AudioCapture: capture hit the \(Int(AudioCapture.maxCaptureSeconds))s "
                + "ceiling — dropping further audio for this capture (missed release / stuck hotkey?)")
        }
    }

    /// How many of `incoming` frames still fit under `limit` given `current`
    /// accumulated frames — never negative. Pure so the cap math unit-tests
    /// mic-free.
    static func appendBudget(current: Int, incoming: Int, limit: Int) -> Int {
        max(0, min(incoming, limit - current))
    }

    // MARK: File decode (W3-T3 e2e harness)

    /// Decode an audio file to the SAME 16 kHz mono Float32 array shape the live
    /// tap produces — the file twin of app/dictation.py's `_load_clip_array`,
    /// used by the `--e2e-file` latency harness (SidecarClient needs identical
    /// PCM whether it came from the mic or a benchmark clip). AVAudioFile reads
    /// the source at its native rate/layout; an AVAudioConverter downmixes +
    /// resamples to 16 kHz mono, chunked so any file length converts cleanly.
    static func decodeFile(at path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let inFormat = file.processingFormat
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            throw CaptureError.converterUnavailable
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount)
        else { return [] }
        try file.read(into: inBuffer)

        var samples: [Float] = []
        var fedInput = false
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16384)
            else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, inputStatus in
                if fedInput {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fedInput = true
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error {
                throw convError ?? CaptureError.converterUnavailable
            }
            let frames = Int(outBuffer.frameLength)
            if frames > 0, let channel = outBuffer.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
            }
            // .haveData means more output remains; anything else (endOfStream /
            // inputRanDry) is the natural end of a single-input conversion.
            if status != .haveData { break }
        }
        return samples
    }

    // MARK: Live level metering (W4-T2 HUD)

    /// Compute a throttled 0…1 level from the tap's RAW hardware buffer and hand
    /// it to `onLevel` on the main queue. Runs on the render thread — lean: the
    /// RMS is computed ONLY when the throttle says it's time, then one hop to main.
    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        levelLock.lock()
        guard _onLevel != nil else { levelLock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard levelThrottle.shouldEmit(at: now) else { levelLock.unlock(); return }
        let handler = _onLevel
        levelLock.unlock()

        let level = AudioCapture.normalizedLevel(rms: AudioCapture.bufferRMS(buffer))
        DispatchQueue.main.async { handler?(level) }
    }

    /// Rate-limits the level callbacks to a fixed cadence. A pure value type so
    /// the throttle logic unit-tests mic-free (feed monotonic timestamps, assert
    /// which ones emit) — the seam the W4-T2 DoD calls out.
    struct LevelThrottle {
        let minInterval: TimeInterval
        private var lastEmit: TimeInterval?
        init(minInterval: TimeInterval) { self.minInterval = minInterval }
        /// True (and arms the next window) iff at least `minInterval` has elapsed
        /// since the last emit; the very first call after init/reset always emits.
        mutating func shouldEmit(at now: TimeInterval) -> Bool {
            if let last = lastEmit, now - last < minInterval { return false }
            lastEmit = now
            return true
        }
        mutating func reset() { lastEmit = nil }
    }

    /// RMS of a buffer's first channel (0 for a non-float / empty buffer).
    /// Render-thread lean; the perceptual mapping lives in `normalizedLevel`.
    static func bufferRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        let samples = channels[0]
        var sumSquares: Float = 0
        for i in 0..<count { let s = samples[i]; sumSquares += s * s }
        return (sumSquares / Float(count)).squareRoot()
    }

    /// Map a linear RMS (0…1) to a perceptual 0…1 display level via dBFS over a
    /// speech-friendly window (-55…-10 dB). Pure + monotonic so the mapping
    /// unit-tests without a mic: silence → 0, full-scale → 1, louder ⇒ higher.
    static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10f(rms)                 // (0,1] → (-inf, 0]
        let floorDB: Float = -55, ceilDB: Float = -10
        let clamped = min(max(db, floorDB), ceilDB)
        return (clamped - floorDB) / (ceilDB - floorDB)
    }

    // MARK: Testable seams (mic-free)

    /// Run `teardown` on `queue`, waiting up to `timeout`. Returns true if it
    /// completed, false if it wedged (caller abandons the resource). Direct port
    /// of app/audio.py's `_bounded_call` — the primitive behind the hardened
    /// stop. Pure and mic-free: AudioCaptureTests drives it with a
    /// wedge-simulating closure, exactly like audio.py's _WedgedStream fake.
    static func boundedTeardown(
        timeout: TimeInterval,
        queue: DispatchQueue,
        _ teardown: @escaping () -> Void
    ) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            teardown()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Peak / RMS / duration for a captured buffer. Static + pure so tests can
    /// assert it without a mic.
    static func computeStats(
        samples: [Float],
        deviceSampleRate: Double,
        stopForced: Bool,
        capped: Bool = false
    ) -> CaptureStats {
        var stats = CaptureStats()
        stats.sampleCount = samples.count
        stats.sampleRate = targetSampleRate
        stats.deviceSampleRate = deviceSampleRate
        stats.stopForced = stopForced
        stats.capped = capped
        guard !samples.isEmpty else { return stats }

        var peak: Float = 0
        var sumSquares: Double = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += Double(sample) * Double(sample)
        }
        stats.peak = peak
        stats.rms = Float((sumSquares / Double(samples.count)).squareRoot())
        stats.durationSeconds = Double(samples.count) / targetSampleRate
        return stats
    }
}
