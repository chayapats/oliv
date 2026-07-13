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
// stop() is BOUNDED: it lifts the samples out FIRST, then the blocking
// engine-stop / tap-removal runs on a utility queue and we wait only a bounded
// interval (boundedTeardown, the Swift port of audio.py's _bounded_call). On
// timeout we ABANDON the wedged engine instance, log loudly, report it via
// `stats.stopForced`, still return every sample captured so far, and leave this
// object reusable (start() builds a fresh engine next time). boundedTeardown is a
// pure, mic-free seam so the timeout logic unit-tests with a wedge-simulating
// closure, exactly like audio.py's _WedgedStream fake — see AudioCaptureTests.
//
// The LIVENESS GATE (the Bluetooth lesson):
// A Bluetooth (HFP) mic delivers 0.5–3 s of EXACT digital zeros after the engine
// opens, while its link comes up — measured on AirPods Pro, where a whole 3 s
// push-to-talk utterance landed inside the hole and the capture came back as
// 2.901 s of zeros. Those frames are not quiet audio, they are the absence of a
// working device, so they are DROPPED rather than written into the utterance, and
// `CaptureStats.deviceLive` records whether the mic ever woke at all. The
// coordinator uses that to show "getting the mic ready" instead of a recording
// pill, and to say "the mic wasn't ready" instead of failing silently — which is
// what this bug did for months. bufferHasSignal is the pure seam (a real mic
// always carries a noise floor; only a dead device reads exactly 0.0).
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
import CoreAudio
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
        /// The input device delivered at least one real (non-zero) frame during
        /// this capture. False = the mic never woke up (a Bluetooth link that
        /// never came up, or an all-zero virtual device), which is the difference
        /// between "the user held the key without speaking" and "the user spoke
        /// into a dead mic" — the release worker must not report those the same
        /// way, because reporting them the same way is what made this bug
        /// invisible for so long.
        var deviceLive: Bool = false
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

    // THE BLUETOOTH DEAD LEAD-IN (what this class's liveness gate exists for).
    //
    // Measured on AirPods Pro: an AVAudioEngine opened at press time gives a
    // Bluetooth HFP mic 0.5–3 s of DIGITAL ZEROS before its input link is up —
    // sometimes no tap buffers at all. A 3 s push-to-talk utterance landed
    // ENTIRELY inside that hole (dead lead-in 2.901 s of a 2.90 s clip, whole-clip
    // RMS 0.00000). The sidecar's _is_silent() gate then classified the clip as
    // no-speech and OLIV typed nothing, silently. Same probe on the built-in mic:
    // 0.000 s dead lead-in, speech RMS 0.028–0.040 — the capture path was fine,
    // only the Bluetooth device lifecycle was not.
    //
    // We do NOT paper over this by holding the mic open between dictations: that
    // would light the macOS mic indicator whenever OLIV is merely *available*, and
    // an always-lit indicator is not a trade a dictation app gets to make on the
    // user's behalf. The mic opens on press and closes on release, full stop.
    //
    // What we DO is refuse to lie about the zeros. They are dropped rather than
    // written into the utterance, `deviceLive` reports whether the mic ever woke,
    // and the HUD says "getting the mic ready" until it does — so the user waits
    // for the device instead of talking into a hole.

    /// A warming device emits EXACTLY 0.0; we drop those frames rather than pad
    /// the utterance with silence. Backstop: if nothing ever proves liveness
    /// within this window (a virtual all-zero input device), accept frames anyway
    /// so a weird device degrades to "records silence" instead of "records
    /// nothing, forever".
    static let liveWaitTimeout: TimeInterval = 5.0

    private let lifecycleLock = NSLock()
    private var engine: AVAudioEngine?
    private var deviceSampleRate: Double = AudioCapture.targetSampleRate

    private let bufferLock = NSLock()
    private var samples: [Float] = []
    private var capReported = false   // guarded by bufferLock; reset per start()
    /// The hotkey is down and frames are landing in the utterance. Guarded by
    /// bufferLock.
    private var isCapturing = false
    /// The device has produced at least one non-zero sample since the engine was
    /// opened (or the liveWaitTimeout backstop fired). Guarded by bufferLock.
    private var deviceLive = false
    private var openedAt: TimeInterval = 0   // systemUptime; guarded by bufferLock

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

    /// The hotkey is down and frames are landing in the utterance.
    var isRunning: Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return isCapturing
    }

    /// The bound device has actually delivered audio. False during a Bluetooth
    /// link warm-up — the HUD shows "getting the mic ready" rather than a
    /// recording pill that is quietly capturing zeros.
    var isDeviceLive: Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return deviceLive
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

    /// Build + start the engine and its tap. Requires `lifecycleLock`.
    ///
    /// A FRESH engine per press. That costs a Bluetooth mic its 0.5–3 s link-up
    /// (see the dead-lead-in note above) but it is also what keeps the mic
    /// indicator honest — the mic is open only while the hotkey is held — and it
    /// means every capture rebinds whatever the system default input is NOW, with
    /// no device-change bookkeeping to get wrong.
    private func openEngineLocked() throws {
        if engine != nil { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // We deliberately do NOT choose the input device here — we take whatever
        // Core Audio calls the default input.
        //
        // Not for lack of trying: AVAudioEngine backs inputNode and outputNode with
        // the SAME AUHAL (verified: `engine.outputNode.audioUnit == engine.inputNode
        // .audioUnit`), so pointing it at an input-ONLY device via
        // kAudioOutputUnitProperty_CurrentDevice leaves a graph the engine cannot
        // start (-10868 from AUGraphParser::InitializeActiveNodesInInputChain) or,
        // worse, one that starts and then delivers ZERO buffers forever. Selecting a
        // device properly needs a different capture backend (a raw AUHAL with the
        // output element disabled, or AVCaptureSession) — not a property poke on
        // this one. Until then, the mic is chosen in System Settings ▸ Sound ▸ Input.
        let deviceID = AudioCapture.defaultInputDeviceID()

        let hardwareFormat = input.inputFormat(forBus: 0)
        deviceSampleRate = hardwareFormat.sampleRate

        // Always convert from the ACTUAL hardware format — do not assume 16k.
        // A device that is mid-switch can report 0 Hz / 0 ch; AVAudioFormat would
        // happily build a nonsense format from it, so reject it explicitly.
        guard
            hardwareFormat.sampleRate > 0,
            hardwareFormat.channelCount > 0,
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

        bufferLock.lock()
        deviceLive = false
        openedAt = ProcessInfo.processInfo.systemUptime
        bufferLock.unlock()

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
        NSLog("OLIV AudioCapture: capturing from \"\(AudioCapture.deviceName(deviceID))\" "
            + "(\(Int(hardwareFormat.sampleRate)) Hz, \(hardwareFormat.channelCount) ch) "
            + "— resampling to \(Int(AudioCapture.targetSampleRate)) Hz mono")
    }

    /// Human-readable name of a Core Audio device. Logged on every capture: the
    /// mic comes from the system default, so when dictation returns nothing there
    /// is otherwise no way — for the user or for us — to tell whether OLIV
    /// listened to the headset or to the laptop.
    static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let value = name?.takeRetainedValue() else {
            return "unknown device (id \(deviceID))"
        }
        return value as String
    }

    /// The system's current default input device, or 0 if Core Audio won't say.
    static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    /// Open the mic and begin accumulating 16 kHz mono Float32 samples.
    /// Non-blocking. Throws on misuse (already recording) or if the mic/engine
    /// can't be opened.
    ///
    /// Frames arriving before the device is LIVE (a Bluetooth link still coming
    /// up emits exact zeros) are dropped, not recorded — see appendConverted.
    /// `isDeviceLive` tells the caller when it is honest to say "recording".
    func start() throws {
        bufferLock.lock()
        if isCapturing {
            bufferLock.unlock()
            throw CaptureError.alreadyRunning
        }
        // ARM BEFORE THE TAP CAN FIRE. openEngineLocked() starts the engine, and
        // from that instant the render thread may call appendConverted — which
        // drops frames when `isCapturing` is false. Arming afterwards would leave
        // a window where the mic is live but the capture is not, and the opening
        // frames of the utterance would be discarded. In an audio path whose whole
        // purpose is "stop losing the start of what people say", that window has
        // no business existing, so it doesn't: the state is armed first and unwound
        // if the engine fails to open.
        capReported = false
        samples = []
        isCapturing = true
        bufferLock.unlock()

        // Fresh throttle per capture so every recording's meter starts live.
        levelLock.lock(); levelThrottle.reset(); levelLock.unlock()

        lifecycleLock.lock()
        do {
            try openEngineLocked()
        } catch {
            lifecycleLock.unlock()
            bufferLock.lock()
            isCapturing = false      // unwind: no engine ⇒ no capture in flight
            samples = []
            bufferLock.unlock()
            throw error
        }
        lifecycleLock.unlock()
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
        bufferLock.lock()
        guard isCapturing else {
            bufferLock.unlock()
            NSLog("OLIV AudioCapture: stop() with no active capture — returning empty buffer")
            let stats = CaptureStats()
            self.stats = stats
            return []
        }
        isCapturing = false
        let captured = samples
        let capped = capReported
        let wasLive = deviceLive
        samples = []
        bufferLock.unlock()

        lifecycleLock.lock()
        let deviceSampleRate = self.deviceSampleRate
        lifecycleLock.unlock()

        // Close the mic the moment the key comes up: the indicator must mean
        // "OLIV is listening right now", never "OLIV might listen later".
        //
        // The samples are already safely in hand ABOVE this line, so a wedged
        // Core Audio teardown (which this machine has produced for real — see the
        // hardened-stop note in the header) can no longer cost the user their
        // utterance. It can still cost them up to `stopTimeout`, and `stopForced`
        // is how they get told that.
        let completed = shutdown()

        var stats = AudioCapture.computeStats(
            samples: captured,
            deviceSampleRate: deviceSampleRate,
            stopForced: !completed,
            capped: capped
        )
        stats.deviceLive = wasLive
        self.stats = stats
        return captured
    }

    /// Close the mic (bounded, abandons a wedged engine). Idempotent; safe to call
    /// with no engine open. stop() calls it on every release, and DictationController
    /// calls it defensively when the hotkey is torn down.
    ///
    /// Returns true if the teardown completed, false if it wedged and the engine
    /// was abandoned — `stop()` carries that into `stats.stopForced` so a wedge is
    /// reported, not just logged. No engine open is a completed teardown (true).
    @discardableResult
    func shutdown() -> Bool {
        lifecycleLock.lock()
        guard let engine = self.engine else {
            lifecycleLock.unlock()
            return true
        }
        // Detach immediately so a wedged teardown can't block the next start().
        self.engine = nil
        lifecycleLock.unlock()

        bufferLock.lock()
        deviceLive = false
        bufferLock.unlock()

        let completed = AudioCapture.boundedTeardown(
            timeout: AudioCapture.stopTimeout, queue: AudioCapture.makeTeardownQueue()) {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if !completed {
            // Abandon the wedged engine (its teardown may finish later on the
            // utility queue). Port of audio.py "leak the wedged stream, salvage
            // the audio". `self.engine` is already nil → object is reusable.
            NSLog("OLIV AudioCapture: engine teardown did not return within "
                + "\(AudioCapture.stopTimeout)s — abandoning wedged engine "
                + "(port of app/audio.py hardened stop)")
        }
        return completed
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
        let incoming = UnsafeBufferPointer(start: pointer, count: frames)

        bufferLock.lock()

        // LIVENESS GATE. A Bluetooth mic whose link is still coming up emits
        // EXACTLY 0.0 — never a noise floor. Those frames are not audio, they are
        // the absence of a working device, so they must not be written into the
        // utterance: padding the clip with them is what dragged the whole-clip RMS
        // under the sidecar's silence threshold and made dictation a no-op.
        var wentLive = false
        var forcedLive = false
        if !deviceLive {
            if AudioCapture.bufferHasSignal(incoming) {
                deviceLive = true
                wentLive = true
            } else if ProcessInfo.processInfo.systemUptime - openedAt > AudioCapture.liveWaitTimeout {
                // Backstop: an input that is genuinely all-zeros (a virtual/loopback
                // device) must degrade to "records silence", never to "records
                // nothing, forever".
                deviceLive = true
                forcedLive = true
            } else {
                bufferLock.unlock()
                return   // still warming — drop the zeros
            }
        }

        var reportCap = false
        if isCapturing {
            let budget = AudioCapture.appendBudget(
                current: samples.count, incoming: frames, limit: AudioCapture.maxCaptureSamples)
            if budget > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: budget))
            }
            reportCap = budget < frames && !capReported
            if reportCap { capReported = true }
        }
        bufferLock.unlock()

        if wentLive {
            NSLog("OLIV AudioCapture: input device is live (first non-zero frame)")
        }
        if forcedLive {
            NSLog("OLIV AudioCapture: input device produced only digital silence for "
                + "\(AudioCapture.liveWaitTimeout)s — capturing anyway; is the right mic selected?")
        }
        if reportCap {
            NSLog("OLIV AudioCapture: capture hit the \(Int(AudioCapture.maxCaptureSeconds))s "
                + "ceiling — dropping further audio for this capture (missed release / stuck hotkey?)")
        }
    }

    /// True iff any sample is non-zero. The liveness discriminator: a warming
    /// Bluetooth link delivers EXACTLY 0.0, while a real mic in a silent room
    /// still carries a noise floor (~0.002 measured on the built-in mic).
    static func bufferHasSignal(_ samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { bufferHasSignal($0) }
    }

    static func bufferHasSignal(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        for value in samples where value != 0 { return true }
        return false
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
        // Nothing to meter until the device is awake: while a Bluetooth link comes
        // up the buffers are exact zeros, the HUD is showing "getting the mic
        // ready", and `update(level:)` drops anything that isn't the recording
        // phase anyway. Bail before the RMS and the hop to main.
        bufferLock.lock()
        let live = isCapturing && deviceLive
        bufferLock.unlock()
        guard live else { return }

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
