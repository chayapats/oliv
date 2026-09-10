// Push-to-talk audio capture — a Swift port of app/audio.py (W1-T3).
//
// Turns a press/record/release into a 16 kHz MONO Float32 sample buffer (the
// STT stage's array contract). start() opens the CHOSEN input device and
// accumulates converted samples; stop() ends capture and returns the buffer.
//
// The backend is a raw output audio unit (output element DISABLED) — a
// VoiceProcessingIO one when echo cancellation applies, else a plain AUHAL — and
// NOT AVAudioEngine; see openUnitLocked for why. Short version:
// AVAudioEngine gives inputNode and outputNode the same audio unit, so it cannot
// be pointed at an input-only device, which is every laptop mic. Letting the user
// pick their mic is not optional (macOS silently promotes a paired Bluetooth
// headset to default input, and dictating through one costs the first second of
// every sentence AND drops the headset's playback to call quality), so the
// backend had to go.
//
// Samplerate: we NEVER assume the mic is natively 16 kHz (built-in reads 48 kHz,
// AirPods 24 kHz in their call profile). We read the hardware input format and run
// every buffer through an AVAudioConverter down to 16 kHz mono Float32 — the
// AVFoundation analogue of app/audio.py's resample-on-stop path, done streaming.
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
// SPEAKER BLEED (0.1.10 — the "music gets transcribed" pass):
// A laptop mic records the laptop's own speakers. With music playing out loud
// the utterance carries the song under the speech, and that costs twice: STT
// INVENTS text from the music (confident sentences nobody said) and the real
// speech is transcribed against a wall of noise. Two defences, both toggleable:
//
//   A. ECHO CANCELLATION — the capture unit becomes Apple's VoiceProcessingIO
//      (AEC + noise suppression), which subtracts what the machine is PLAYING
//      from what the mic HEARS. It is used only when neither the input nor the
//      output device is Bluetooth (see shouldUseVoiceProcessing) and it falls
//      back to the plain AUHAL if it won't open, so the worst case is exactly
//      the pre-0.1.10 capture path.
//   B. DUCKING — OutputDucker fades the system output down while the mic is
//      open and back up on release, so the part AEC cannot model gets quieter
//      too. Owned here, not by the coordinator, because the mic's open/close is
//      the only event that reliably brackets EVERY capture, including the
//      wedged-teardown path.
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
//
// WHAT THE RENDER THREAD ACTUALLY DOES (an earlier revision of this file claimed
// "it allocates nothing" while allocating a PCM buffer on every callback — so this
// section states the truth, and the code is written to keep it true):
//
//   * NO allocation per callback. Both the hardware buffer AND the 16 kHz
//     conversion buffer are pre-allocated in CaptureSession at open, and `samples`
//     reserves its whole 10-minute ceiling in start(), so append() never reallocs.
//   * NO logging, no I/O. The gate/cap events set a flag under bufferLock and the
//     NSLog is dispatched to main — at most three hops per capture.
//   * TWO short, uncontended locks (bufferLock around the sample append,
//     levelLock around the meter sink) plus a ≤24 Hz hop to main. Not textbook
//     lock-free, but bounded and off the allocation path. If this ever needs to be
//     truly RT-clean, the exit is an SPSC ring buffer — or AVCaptureSession, which
//     delivers on a dispatch queue instead of the IOProc thread.
//   * It does NOT touch `lifecycleLock`, and it does NOT read `self.unit`. See
//     CaptureSession for why that matters.

import AVFoundation
import AudioToolbox
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
        /// Which capture backend this utterance ran through — `.voiceProcessing`
        /// when echo cancellation was actually in force, `.hal` when it was off,
        /// skipped, or fell back. Carried so "was the AEC on for THAT clip?" is a
        /// fact in the log rather than an inference.
        var backend: Backend = .hal
    }

    /// Which output audio unit backs the capture.
    ///
    /// `.voiceProcessing` is the echo-cancelling one (kAudioUnitSubType_VoiceProcessingIO):
    /// it models what the machine is playing and subtracts it from the mic, which
    /// is the only thing that removes speaker bleed from an utterance the user is
    /// speaking INTO. `.hal` is the plain AUHAL — the pre-0.1.10 path, and still
    /// the fallback whenever the voice unit can't or shouldn't open.
    enum Backend: String, Equatable {
        case voiceProcessing
        case hal

        var subType: OSType {
            switch self {
            case .voiceProcessing: return kAudioUnitSubType_VoiceProcessingIO
            case .hal: return kAudioUnitSubType_HALOutput
            }
        }

        var label: String {
            switch self {
            case .voiceProcessing: return "voice-processing (echo cancelling)"
            case .hal: return "HAL"
            }
        }
    }

    enum CaptureError: Error, CustomStringConvertible {
        case alreadyRunning
        case converterUnavailable
        case noInputDevice
        case unitUnavailable(OSStatus)
        case deviceBindFailed(AudioDeviceID, OSStatus)
        case unitStartFailed(OSStatus)
        case routeChangedWhileOpening

        /// The one open failure that is NOT evidence the voice unit is broken on
        /// this machine. The route changed under it mid-open — a headset
        /// connecting is exactly that — so the next press may well be fine, and
        /// distrusting the unit here would cost the user echo cancellation for
        /// the rest of the run because they plugged something in once.
        var isTransientRouteChange: Bool {
            if case .routeChangedWhileOpening = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .alreadyRunning:
                return "AudioCapture already started — call stop() before starting again"
            case .converterUnavailable:
                return "could not build the 16 kHz mono AVAudioConverter from the hardware format"
            case .noInputDevice:
                return "no input device is available"
            case let .unitUnavailable(status):
                return "could not configure the HAL input unit (OSStatus \(status))"
            case let .deviceBindFailed(device, status):
                return "could not bind input device \(AudioDevices.deviceName(device)) "
                    + "(OSStatus \(status))"
            case let .unitStartFailed(status):
                return "the HAL input unit failed to start (OSStatus \(status))"
            case .routeChangedWhileOpening:
                return "the audio route changed while the unit was opening"
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

    /// How long the OPEN waits for the voice unit to prove it delivers audio
    /// before demoting to the HAL unit (see waitForFirstFrame). Generous against
    /// the 60–76 ms first frame measured on a healthy open, short enough that a
    /// dud costs a barely perceptible pause rather than an utterance. A Bluetooth
    /// mic's 0.5–3 s warm-up never lands here: the voice unit is not used on
    /// Bluetooth at all.
    static let voiceLivenessTimeout: TimeInterval = 0.25

    /// AUHAL element numbering: the input bus is element 1, the (disabled) output
    /// bus is element 0. Naming them beats a bare `1` three property calls deep.
    static let inputElement: AudioUnitElement = 1
    static let outputElement: AudioUnitElement = 0

    /// FLOOR on frames per render callback, not a ceiling. The real slice size is
    /// the DEVICE's `kAudioDevicePropertyBufferFrameSize`, read per open — setting
    /// kAudioUnitProperty_MaximumFramesPerSlice does NOT constrain what the HAL
    /// hands you. A device configured with a bigger IO buffer (Audio MIDI Setup, an
    /// aggregate device) used to overflow the fixed 4096-frame buffer, and the
    /// callback answered by returning noErr WITHOUT rendering — dropping every
    /// frame of every capture, forever, and reporting it as "the mic wasn't ready".
    /// A silent total loss, in the one file whose entire purpose is to never lose
    /// audio silently. We now size the buffer from the device and keep this only as
    /// headroom.
    static let minFramesPerSlice: UInt32 = 4096

    /// Which mic to record from: a `MicSelection` sentinel or a device UID (see
    /// AudioDevices). Read at each start(); DictationController keeps it in sync
    /// with Settings. Defaults to the built-in mic — never a Bluetooth headset by
    /// accident, because macOS promotes a paired headset to default input and that
    /// silently costs the user their first second of speech and their music.
    var deviceSelection: String = MicSelection.builtIn

    /// "Cancel speaker echo" (Settings › General, default ON). Read at each
    /// start(); a capture that has already begun keeps the backend it opened
    /// with. Turning it off pins the capture to the plain AUHAL — the exact
    /// pre-0.1.10 path — which is the escape hatch if the voice unit ever
    /// degrades a particular mic.
    var echoCancellation: Bool = true {
        // Toggling it is the user's explicit "try again" gesture — it must clear
        // a demotion an earlier failure left behind, or the setting would sit
        // there ON while every capture quietly ran without it.
        didSet { if echoCancellation != oldValue { voiceProcessingDistrusted = false } }
    }

    /// "Lower other audio while dictating" (Settings › General, default ON).
    /// Read at open/close; see OutputDucker.
    var duckOtherAudio: Bool = true

    /// The backend the CURRENT/last capture actually used — `.hal` when the
    /// voice unit was skipped (Bluetooth) or failed to open. Surfaced in
    /// CaptureStats so a fallback is reportable, not just loggable.
    private(set) var activeBackend: Backend = .hal

    /// The voice unit OPENED and then delivered nothing — a failure the open-time
    /// fallback cannot see, because by then it has already succeeded. One such
    /// capture is a lost utterance; a second would be a pattern, so the next
    /// press goes straight to the HAL unit and stays there for this run. Reset
    /// only by relaunching (or by the user toggling echo cancellation off and on,
    /// which is the explicit "try again" gesture).
    ///
    /// Not `private`, so the reset is actually TESTABLE: a test that can only see
    /// the public toggle cannot tell a working reset from a deleted one, and it
    /// passed for exactly that reason before this was widened.
    var voiceProcessingDistrusted = false

    private let ducker: OutputDucker
    /// True while `ducker` holds the output down for THIS capture, so the
    /// restore is exactly as symmetric as the duck (a toggle flipped
    /// mid-utterance must not strand the volume). Guarded by its OWN lock: the
    /// duck is set under `lifecycleLock` during the open and cleared by
    /// shutdown() BEFORE it takes that lock (the volume must come back even when
    /// the teardown wedges), so the two must not share one.
    private let duckLock = NSLock()
    private var didDuck = false

    private let lifecycleLock = NSLock()
    /// The live capture, +1-retained because its pointer is the render callback's
    /// refCon. nil = nothing open. Guarded by lifecycleLock; the RENDER THREAD
    /// NEVER READS IT — it reaches its own session through refCon instead.
    private var sessionRef: Unmanaged<CaptureSession>?
    private var deviceSampleRate: Double = AudioCapture.targetSampleRate

    private let bufferLock = NSLock()
    private var samples: [Float] = []
    private var capReported = false   // guarded by bufferLock; reset per start()
    private var overflowReported = false   // guarded by bufferLock; reset per start()
    /// The hotkey is down and frames are landing in the utterance. Guarded by
    /// bufferLock.
    private var isCapturing = false
    /// The device has produced at least one non-zero sample since the engine was
    /// opened (or the liveWaitTimeout backstop fired). Guarded by bufferLock.
    private var deviceLive = false
    private var openedAt: TimeInterval = 0   // systemUptime; guarded by bufferLock
    /// Bumped once per start(). A CaptureSession is stamped with the generation it
    /// was opened for, and frames from any OTHER generation are discarded — this is
    /// what makes an abandoned (wedged) unit's still-running IOProc harmless. See
    /// CaptureSession. Guarded by bufferLock.
    private var generation: UInt64 = 0

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

    /// `ducker` is injected so the output-volume side is substitutable in tests
    /// and in the headless probe; the app builds the real one.
    init(ducker: OutputDucker = OutputDucker()) {
        self.ducker = ducker
    }

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

    // MARK: The capture session (one per open — the refCon the callback gets)

    /// Everything ONE opened unit needs, owned by that unit and reachable ONLY
    /// through the render callback's refCon.
    ///
    /// WHY THIS TYPE EXISTS — the bug it makes impossible. The callback used to get
    /// `self` as its refCon and render into whatever `self.unit` happened to be at
    /// the time. That is safe right up until `shutdown()` ABANDONS a wedged unit —
    /// which it does deliberately (see the hardened-stop note in the header; this
    /// machine has produced an 8-minute Core Audio wedge for real). An abandoned
    /// unit is never stopped, so its IOProc KEEPS RUNNING. It was harmless only
    /// while `self.unit` was nil; the moment the user pressed the hotkey again and
    /// a new unit was published, the zombie IOProc would call AudioUnitRender on
    /// the NEW unit — from the OLD unit's thread, with the OLD unit's timestamp and
    /// frame count — and both threads would then race on the one shared render
    /// buffer and append into the same `samples`. Corrupted audio at best.
    ///
    /// Now every unit carries its own buffers and its own converter, so a zombie
    /// renders harmlessly into memory nobody else can see, and the `generation`
    /// stamp gets its frames dropped at the door (see appendConverted). On the
    /// wedge path we simply never release this object: it leaks WITH the unit it
    /// belongs to, which is exactly the trade the hardened stop already makes —
    /// a few hundred KB beats a callback firing into freed memory.
    fileprivate final class CaptureSession {
        let unit: AudioUnit
        /// The capture this session was opened for. Frames from a stale generation
        /// are dropped rather than mixed into someone else's utterance.
        let generation: UInt64
        /// Pre-allocated at open, sized from the DEVICE's buffer frame size. The
        /// render thread must not allocate, so both of these are reused every
        /// callback and never grown.
        let renderBuffer: AVAudioPCMBuffer
        let convertBuffer: AVAudioPCMBuffer
        let converter: AVAudioConverter
        /// Strong on purpose: the callback must stay valid for as long as the unit
        /// can fire, INCLUDING after this session has been abandoned. The cycle
        /// (AudioCapture → sessionRef → owner) is broken by release() on the clean
        /// teardown path and leaked on the wedge path, by design.
        let owner: AudioCapture

        init(unit: AudioUnit, generation: UInt64, renderBuffer: AVAudioPCMBuffer,
             convertBuffer: AVAudioPCMBuffer, converter: AVAudioConverter,
             owner: AudioCapture) {
            self.unit = unit
            self.generation = generation
            self.renderBuffer = renderBuffer
            self.convertBuffer = convertBuffer
            self.converter = converter
            self.owner = owner
        }

        /// The realtime input callback. Renders into ITS OWN unit and ITS OWN
        /// buffer — never into whatever the object currently has open.
        func render(
            flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            timestamp: UnsafePointer<AudioTimeStamp>,
            bus: UInt32,
            frames: UInt32
        ) -> OSStatus {
            guard frames > 0 else { return noErr }
            guard frames <= renderBuffer.frameCapacity else {
                // Should now be unreachable (the buffer is sized from the device),
                // but if the HAL ever hands us more than it promised, SAY SO rather
                // than drop the whole capture in silence.
                owner.noteRenderOverflow(frames: frames, capacity: renderBuffer.frameCapacity)
                return noErr
            }

            renderBuffer.frameLength = frames
            let status = AudioUnitRender(unit, flags, timestamp, bus, frames,
                                         renderBuffer.mutableAudioBufferList)
            guard status == noErr else { return status }

            owner.appendConverted(from: self)
            owner.emitLevel(from: self)
            return noErr
        }
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

    /// Open the CHOSEN mic and start its render callback. Requires `lifecycleLock`.
    ///
    /// A raw AUHAL, not AVAudioEngine — and that choice IS the mic picker.
    /// AVAudioEngine backs `inputNode` and `outputNode` with the SAME audio unit
    /// (verified: `engine.outputNode.audioUnit == engine.inputNode.audioUnit`), so
    /// pointing it at an input-ONLY device — which every laptop mic is, having zero
    /// output channels — leaves a graph it cannot start (-10868 out of
    /// AUGraphParser::InitializeActiveNodesInInputChain) or, worse, one that starts
    /// and then delivers zero buffers forever. Both were measured. The second one
    /// shipped for an afternoon.
    ///
    /// A HALOutput unit with the OUTPUT element DISABLED has no such coupling: it
    /// binds any input device, leaves the system output device alone (headphone
    /// playback keeps its A2DP profile — no more music dropping to call quality
    /// mid-dictation), and delivered its first sample 60–76 ms after open.
    ///
    /// A FRESH unit per press: the mic is open only while the hotkey is held, so
    /// the macOS mic indicator never claims more than the truth, and every capture
    /// re-resolves the device selection with no stale-binding bookkeeping.
    ///
    /// Returns the line to log — the caller logs it AFTER dropping lifecycleLock.
    /// Logging while holding it would stall the render thread on its very first
    /// callbacks (NSLog takes locks and does I/O), and dropped opening frames are
    /// the exact bug this branch exists to end.
    private func openUnitLocked(generation: UInt64) throws -> String {
        if sessionRef != nil { return "" }

        // 1. Which mic? Re-resolved per press, so unplugging or switching a device
        //    between dictations just works.
        let devices = AudioDevices.inputDevices()
        guard let deviceID = AudioDevices.resolve(
            selection: deviceSelection,
            devices: devices,
            systemDefaultID: AudioDevices.systemDefaultInputID())
        else {
            throw CaptureError.noInputDevice
        }

        // 2. Echo cancellation first, plain HAL as the fallback. The voice unit
        //    can fail to initialise for reasons we cannot enumerate from here (a
        //    device it won't drive, a HAL in a bad mood), and "no dictation at
        //    all" is a far worse outcome than "dictation without AEC" — so a
        //    failure DEMOTES the capture instead of failing it.
        let wantsVoiceProcessing = AudioCapture.shouldUseVoiceProcessing(
            enabled: echoCancellation,
            isSystemDefaultInput: deviceID == AudioDevices.systemDefaultInputID(),
            inputIsBluetooth: AudioDevices.isBluetooth(deviceID),
            outputIsBluetooth: AudioDevices.isBluetooth(AudioDevices.systemDefaultOutputID()))
        var attempts: [Backend] = wantsVoiceProcessing && !voiceProcessingDistrusted
            ? [.voiceProcessing, .hal]
            : [.hal]
        var notes: [String] = []
        var target = deviceID
        while true {
            let backend = attempts.removeFirst()
            do {
                // Re-read the generation per attempt: `retire` bumps it when it
                // abandons a wedged unit, and the next backend must be stamped
                // with the NEW one or the zombie's frames would pass the gate.
                bufferLock.lock()
                let generation = self.generation
                bufferLock.unlock()
                let opened = try openUnitLocked(
                    generation: generation, deviceID: target, backend: backend)
                return (notes + [opened]).joined(separator: "\n")
            } catch {
                guard !attempts.isEmpty else { throw error }
                // A voice unit that will not OPEN is broken on THIS machine, not
                // unlucky: the -10875 a configuration it dislikes returns will
                // return again on the next press, and on every press after that.
                // So the open failure earns the same distrust the two DELIVERY
                // failures already earn — otherwise the fallback is paid again
                // every time the user speaks, which is the cost trade 3 prices at
                // exactly once.
                if AudioCapture.shouldDistrustAfterFailedOpen(backend: backend, error: error) {
                    voiceProcessingDistrusted = true
                }
                // RE-RESOLVE THE MIC FOR THE FALLBACK, against the machine as it
                // is NOW. The commonest reason to be here is the route check
                // finding that the default input MOVED while the voice unit was
                // opening — and the entire point of rejecting the voice unit then
                // is that it would record the wrong microphone. Binding the
                // fallback to the ID resolved BEFORE that move records exactly the
                // same wrong microphone one unit later, while the picker still
                // says "System Default". Resolution is by SELECTION, not by ID, so
                // a mic the user named by UID still resolves to that mic; what
                // changes is only what "the default" and "the picked device is
                // gone" mean, which is what moved.
                target = AudioDevices.resolve(
                    selection: deviceSelection,
                    devices: AudioDevices.inputDevices(),
                    systemDefaultID: AudioDevices.systemDefaultInputID()) ?? target
                notes.append("OLIV AudioCapture: \(backend.label) unit would not open "
                    + "(\(error)) — falling back to \(attempts[0].label)")
            }
        }
    }

    /// Should this capture use the echo-cancelling unit?
    ///
    /// Three conditions, each of which was measured rather than assumed:
    ///
    ///  * `isSystemDefaultInput` — THE hard constraint. The voice unit will not
    ///    initialise when its device is bound to an input-only device: every
    ///    configuration that pointed it at "MacBook Pro Microphone" failed with
    ///    OSStatus -10875, and the ONLY one that initialised leaves the device
    ///    unbound, which means it records the SYSTEM DEFAULT input. So OLIV uses
    ///    it exactly when the mic the user picked IS the default input, and takes
    ///    the plain HAL otherwise. Recording a different microphone than the one
    ///    the picker names is not a trade-off, it is a lie — and the picker
    ///    exists because that lie already cost this app a release.
    ///  * not Bluetooth on EITHER end. The voice unit is duplex: it opens the
    ///    output side too, which risks exactly the A2DP → HFP flip AudioDevices
    ///    spends its header warning about (music drops to call quality
    ///    mid-sentence). The trade is easy, because headphones do not leak into
    ///    the mic — AEC there would buy nothing and cost a real regression.
    ///    Speakers are where the bleed is, and speakers are where the AEC goes.
    ///  * `enabled` — the user's switch, absolute in both directions.
    ///
    /// Pure so the policy unit-tests without a device.
    static func shouldUseVoiceProcessing(
        enabled: Bool,
        isSystemDefaultInput: Bool,
        inputIsBluetooth: Bool,
        outputIsBluetooth: Bool
    ) -> Bool {
        enabled && isSystemDefaultInput && !inputIsBluetooth && !outputIsBluetooth
    }

    /// Do the two conditions the unbound voice unit rests on STILL hold, now
    /// that it is running? Checked again after start because the pre-open check
    /// is a time-of-check/time-of-use window: a headset that connects in it gets
    /// promoted to default input AND output by macOS, and either promotion turns
    /// the running voice unit into a different microphone or a Bluetooth route.
    /// Pure so the recheck unit-tests without a device.
    static func routeStillSuitable(
        deviceID: AudioDeviceID, systemDefaultInputID: AudioDeviceID, outputIsBluetooth: Bool
    ) -> Bool {
        deviceID == systemDefaultInputID && !outputIsBluetooth
    }

    /// Open ONE backend. Throws on any failure — the caller decides whether that
    /// means "try the next backend" or "this capture is lost".
    private func openUnitLocked(
        generation: UInt64, deviceID: AudioDeviceID, backend: Backend
    ) throws -> String {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: backend.subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.unitUnavailable(-1)
        }
        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &newUnit)
        guard status == noErr, let unit = newUnit else {
            throw CaptureError.unitUnavailable(status)
        }
        // Nothing past this point may leak the unit.
        // BOUNDED, like every other teardown here. These paths run BEFORE the
        // unit is started, but they still talk to a Core Audio that has just
        // refused to do something — the state this machine has produced 8-minute
        // wedges from. A straight dispose that wedges would hang the press and,
        // worse, hang it on the way to the fallback backend that was about to
        // rescue it. On a wedge the instance is abandoned (leaked) exactly as the
        // hardened stop abandons one: it was never started, so nothing of ours is
        // still running inside it.
        func fail(_ error: CaptureError) -> CaptureError {
            let completed = AudioCapture.boundedTeardown(
                timeout: AudioCapture.stopTimeout, queue: AudioCapture.makeTeardownQueue()) {
                AudioComponentInstanceDispose(unit)
            }
            if !completed {
                NSLog("OLIV AudioCapture: disposing an unstarted \(backend.label) unit did not "
                    + "return within \(AudioCapture.stopTimeout)s — abandoning it")
            }
            return error
        }

        var enable: UInt32 = 1
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
            AudioCapture.inputElement, &enable, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw fail(.unitUnavailable(status)) }

        // The output element: OFF for the HAL unit (the line that makes an
        // input-only device legal here, and what keeps headphone playback on its
        // A2DP profile), ON for the voice unit — which is duplex and simply will
        // not initialise without it, because its output side IS the reference
        // signal the canceller subtracts from the mic. Measured: every
        // output-disabled voice configuration failed with -10875.
        var outputIO: UInt32 = backend == .voiceProcessing ? 1 : 0
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
            AudioCapture.outputElement, &outputIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw fail(.unitUnavailable(status)) }

        // 3. Bind the device — must happen before AudioUnitInitialize.
        //
        // ONLY on the HAL path. Binding the voice unit to a microphone is what
        // makes it refuse to initialise (see shouldUseVoiceProcessing): it wants
        // a duplex device, and a laptop mic has no output side. Left unbound it
        // runs on the system default input + output — which is why the voice unit
        // is used only when the picked mic IS the default input, so "unbound"
        // and "the device the user chose" are the same device.
        if backend == .hal {
            var device = deviceID
            status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw fail(.deviceBindFailed(deviceID, status)) }
        }

        // 4. What the hardware gives, and what we want it as. Never assume 16 kHz:
        //    the built-in mic reports 48 kHz, AirPods 24 kHz in the HFP call profile.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
            AudioCapture.inputElement, &hardware, &size)
        guard status == noErr, hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0
        else { throw fail(.converterUnavailable) }

        // The voice unit's input bus advertises the mic array RAW — this MacBook
        // reports NINE channels there, a layout AVAudioFormat refuses to build at
        // all (measured: AVAudioFormat(streamDescription:) returns nil, which
        // would have thrown .converterUnavailable on every press). It happily
        // converts to mono when asked, and mono is what the 16 kHz contract wants
        // anyway, so the voice path asks for one channel and the HAL path keeps
        // taking the hardware's own count (unchanged behaviour).
        let clientChannels: UInt32 = backend == .voiceProcessing ? 1 : hardware.mChannelsPerFrame
        var client = AudioStreamBasicDescription(
            mSampleRate: hardware.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: clientChannels,
            mBitsPerChannel: 32,
            mReserved: 0)
        status = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
            AudioCapture.inputElement, &client,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw fail(.converterUnavailable) }

        // The voice unit needs BOTH of its buses described, including the output
        // one we never feed. Skipping this is the difference between initialising
        // and -10875 (measured: the identical configuration passes with it and
        // fails without). We render nothing to that bus — no output callback is
        // installed, so it plays silence and exists only to give the canceller
        // its reference.
        if backend == .voiceProcessing {
            status = AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                AudioCapture.outputElement, &client,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            guard status == noErr else { throw fail(.converterUnavailable) }
        }

        guard
            let inputFormat = AVAudioFormat(streamDescription: &client),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioCapture.targetSampleRate,
                channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw fail(.converterUnavailable) }

        // 5. Size the slice from the DEVICE, not from a hopeful constant, and
        //    pre-allocate BOTH buffers the callback needs. MaximumFramesPerSlice is
        //    what WE promise to handle; it does not cap what the HAL delivers, so
        //    the device's own buffer frame size is the number that matters. Getting
        //    this wrong used to drop every frame of every capture in silence — see
        //    minFramesPerSlice.
        let deviceFrames = AudioCapture.deviceBufferFrameSize(deviceID)
        var maxFrames = max(deviceFrames, AudioCapture.minFramesPerSlice)
        status = AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw fail(.unitUnavailable(status)) }

        // The conversion buffer must hold a whole slice AFTER resampling. Ratio > 1
        // when the device runs BELOW 16 kHz, so this cannot just be maxFrames.
        let convertCapacity = AudioCapture.convertCapacity(
            maxFrames: maxFrames, deviceRate: hardware.mSampleRate)
        guard
            let render = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxFrames),
            let convert = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                           frameCapacity: convertCapacity)
        else { throw fail(.converterUnavailable) }

        deviceSampleRate = hardware.mSampleRate

        bufferLock.lock()
        deviceLive = false
        openedAt = ProcessInfo.processInfo.systemUptime
        bufferLock.unlock()

        // 6. The input callback. Its refCon is the SESSION, not `self` — so the
        //    callback can only ever touch the unit and buffers it was born with.
        //    passRetained: a wedged, abandoned unit's IOProc keeps firing, and it
        //    must find live memory when it does. shutdown() releases this on the
        //    clean path and deliberately leaks it on the wedge path.
        let session = CaptureSession(
            unit: unit, generation: generation, renderBuffer: render,
            convertBuffer: convert, converter: converter, owner: self)
        let ref = Unmanaged.passRetained(session)

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timestamp, bus, frames, _ in
                let session = Unmanaged<CaptureSession>.fromOpaque(refCon).takeUnretainedValue()
                return session.render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
            },
            inputProcRefCon: ref.toOpaque())
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            ref.release()
            throw fail(.unitUnavailable(status))
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            ref.release()
            throw fail(.unitStartFailed(status))
        }

        if backend == .voiceProcessing {
            AudioCapture.configureVoiceProcessing(unit, duckOthers: duckOtherAudio)
        }

        // Lower the speakers for the length of the hold — the half of the
        // speaker-bleed problem the canceller can't model (see the header).
        //
        // ONLY on the HAL path, and this split was forced by measurement. The
        // voice unit ducks other audio ITSELF, through the system mixer, and the
        // two mechanisms actively fight:
        //   * The user's volume got STRANDED. Whatever the voice unit's ducking
        //     touches is not ours, so our ownership check (correctly) surrendered
        //     mid-fade and walked away — leaving the machine at 22% when the user
        //     had it at 50%. That is the exact failure this class exists to make
        //     impossible, arrived at from the other direction.
        //   * Cancellation got WORSE, not better. The canceller models the echo
        //     PATH; moving the volume scalar underneath it forces a re-converge
        //     mid-utterance, measured here as residual bleed rms 0.0004 → 0.0036
        //     — enough to put hallucinated text back into the transcript.
        // Apple's ducking has neither problem: it is inside the mixer the
        // canceller already knows about, and it never touches a device property
        // that can be left behind. So the voice path asks the unit to duck (see
        // configureVoiceProcessing) and the HAL path — which has no canceller and
        // therefore needs this most — fades the scalar.
        //
        // BEFORE START on purpose (same echo-path reasoning), so every throw path
        // below has to unduck: an open that ends in a throw must never leave the
        // user's volume down.
        if duckOtherAudio && backend == .hal {
            duckLock.lock()
            didDuck = true
            duckLock.unlock()
            ducker.duck()
        }

        // PUBLISH BEFORE START. Once AudioOutputUnitStart returns the IOProc may
        // already be running; it finds everything it needs through refCon, so there
        // is no window in which a frame arrives with nowhere to go.
        self.sessionRef = ref
        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            // Volume FIRST: the teardown below is bounded but can still take up
            // to three seconds, and the mic never opened — there is nothing to
            // keep the user's music quiet for.
            unduck()
            retire(ref, unit: unit, reason: "it would not start (OSStatus \(status))",
                   started: false)
            throw CaptureError.unitStartFailed(status)
        }

        // RE-CHECK THE ROUTE, now that the unit is actually running. The voice
        // unit's two guards (it records the default INPUT, and it opens the
        // default OUTPUT) were evaluated before the unit existed, and a device
        // can change in between — macOS promotes a headset the moment it
        // connects, which is precisely the event this app cannot afford to lose
        // a race with. Both outcomes of that race are unacceptable on their own
        // terms: recording a different mic than the picker names, or flipping a
        // just-connected headset out of A2DP. So we look again with the unit
        // live, and a changed route retires this attempt — the caller's fallback
        // opens the plain HAL unit, which is BOUND to the chosen device and
        // therefore immune to both.
        if backend == .voiceProcessing, !AudioCapture.routeStillSuitable(
            deviceID: deviceID,
            systemDefaultInputID: AudioDevices.systemDefaultInputID(),
            outputIsBluetooth: AudioDevices.isBluetooth(AudioDevices.systemDefaultOutputID()))
        {
            retire(ref, unit: unit, reason: "the audio route changed while it was opening")
            // A DISTINCT error, not a bind failure: this is the one open failure
            // the caller must NOT read as "the voice unit is broken here" — see
            // shouldDistrustAfterFailedOpen.
            throw CaptureError.routeChangedWhileOpening
        }

        // DOES IT ACTUALLY DELIVER? The voice unit can start cleanly and then
        // hand over nothing at all, and the open-time fallback cannot see that —
        // by then it has already succeeded. Waiting here for the first real frame
        // turns that into an ordinary failed open, so the HAL fallback happens
        // inside THIS press instead of costing the user a whole utterance and
        // only demoting the next one.
        //
        // The wait costs nothing when the unit is healthy: the first frame lands
        // 60–76 ms after open (measured), and frames are already accumulating
        // while we wait, so nothing spoken in that window is lost. Only the HUD
        // learns about it late, and only in the failure case.
        if backend == .voiceProcessing, !waitForFirstFrame(timeout: AudioCapture.voiceLivenessTimeout) {
            retire(ref, unit: unit, reason: "it started but delivered no audio")
            voiceProcessingDistrusted = true
            throw CaptureError.unitStartFailed(kAudioUnitErr_FailedInitialization)
        }

        activeBackend = backend
        let name: String = AudioDevices.deviceName(deviceID)
        let rate: Int = Int(hardware.mSampleRate)
        let channels: UInt32 = hardware.mChannelsPerFrame
        let target: Int = Int(AudioCapture.targetSampleRate)
        return "OLIV AudioCapture: capturing from \"\(name)\" "
            + "(\(rate) Hz, \(channels) ch, \(maxFrames)-frame slices, \(backend.label)) "
            + "— resampling to \(target) Hz mono"
    }

    /// Abandon a unit that has already been STARTED, for a reason that is not the
    /// user's problem, and leave this object ready to open the next backend.
    ///
    /// Through `boundedTeardown`, like every other close in this file: stopping a
    /// Core Audio unit can wedge (this machine has produced an 8-minute one), and
    /// a straight-line stop/uninitialize/dispose here would hang the PRESS —
    /// turning "fall back to the HAL unit" into "the hotkey does nothing". On a
    /// wedge the unit and its session are abandoned exactly as the hardened stop
    /// abandons them, and the generation gate makes the zombie's frames harmless.
    private func retire(
        _ ref: Unmanaged<CaptureSession>, unit: AudioUnit, reason: String, started: Bool = true
    ) {
        self.sessionRef = nil
        let completed = AudioCapture.boundedTeardown(
            timeout: AudioCapture.stopTimeout, queue: AudioCapture.makeTeardownQueue()) {
            if started { AudioOutputUnitStop(unit) }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        if completed { ref.release() }
        unduck()   // this attempt is abandoned; so is its duck

        // Frames from this unit may already sit in the utterance. They came from
        // a device we have just decided not to trust — possibly the wrong mic
        // entirely — so they must not be mixed into what the next backend
        // captures.
        //
        // And BUMP THE GENERATION. On a wedged teardown this unit's IOProc is
        // still running, and it was stamped with the generation the fallback
        // backend is about to reuse — so the gate that makes a zombie harmless
        // would have waved its frames straight through into the HAL utterance,
        // refilling the buffer this very method just cleared. The next attempt
        // re-reads the generation (see the attempt loop) and the zombie is
        // orphaned in the past where it belongs.
        bufferLock.lock()
        samples.removeAll(keepingCapacity: true)
        deviceLive = false
        openedAt = ProcessInfo.processInfo.systemUptime
        generation &+= 1
        bufferLock.unlock()

        NSLog("OLIV AudioCapture: retired the voice-processing unit — \(reason)"
            + (completed ? "" : " (its teardown wedged and was abandoned)"))
    }

    /// Block until the capture proves it is alive, up to `timeout`. Polls the
    /// same `deviceLive` flag the HUD's warming state uses, so "live" means
    /// exactly what it means everywhere else in this file: a real, non-zero frame
    /// arrived.
    private func waitForFirstFrame(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if isDeviceLive { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return isDeviceLive
    }

    /// Did a voice-processing capture fail in the one way the open-time fallback
    /// cannot see — started, then produced no live device and no samples? Pure so
    /// the demotion rule unit-tests without a mic. A HAL capture that comes back
    /// empty means the user held the key without speaking (or a dead device), and
    /// must NOT demote anything.
    static func shouldDistrustVoiceProcessing(
        backend: Backend, deviceLive: Bool, sampleCount: Int
    ) -> Bool {
        backend == .voiceProcessing && !deviceLive && sampleCount == 0
    }

    /// Does a failed OPEN mean "don't try the voice unit again this run"?
    ///
    /// Yes for everything that says the unit cannot be brought up HERE: those
    /// failures are a property of the machine, they repeat on every press, and
    /// re-paying the fallback each time costs the first quarter-second of every
    /// utterance for nothing. No for a route change, which is a property of the
    /// MOMENT — the headset that just connected is a reason to take the HAL path
    /// this once, not to abandon echo cancellation until the app restarts.
    ///
    /// Pure, so the rule is unit-tested without a mic (the fallback itself needs
    /// real hardware to fail — see the tests' note on that seam).
    static func shouldDistrustAfterFailedOpen(backend: Backend, error: Error) -> Bool {
        guard backend == .voiceProcessing else { return false }
        return (error as? CaptureError)?.isTransientRouteChange != true
    }

    /// Turn the voice unit into the thing we actually want: echo cancellation ON,
    /// automatic gain control OFF.
    ///
    /// AGC is off ON PURPOSE. It would ride the level of every utterance, and the
    /// downstream sidecar makes decisions on absolute level (the `_is_silent()`
    /// gate that the Bluetooth bug used to trip); an AGC that lifts a silent
    /// room's noise floor toward speech level is a new way to feed the STT audio
    /// it should have ignored. The canceller is the part we came for.
    ///
    /// `duckOthers` turns on the unit's OWN ducking of other audio — Apple's
    /// mechanism, inside the mixer the canceller already models, which is why the
    /// voice path uses it instead of OutputDucker's volume scalar (see the call
    /// site for the two measured failures that split them).
    ///
    /// Best-effort by design: none of these is worth losing a capture over, so a
    /// failure is logged and the unit runs with its defaults.
    private static func configureVoiceProcessing(_ unit: AudioUnit, duckOthers: Bool) {
        var bypass: UInt32 = 0
        let bypassStatus = AudioUnitSetProperty(
            unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0,
            &bypass, UInt32(MemoryLayout<UInt32>.size))
        var agc: UInt32 = 0
        let agcStatus = AudioUnitSetProperty(
            unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0,
            &agc, UInt32(MemoryLayout<UInt32>.size))
        // Advanced ducking follows the user's speech instead of holding a fixed
        // dip. Measured against a fixed .max dip on a hold with NO speaking, the
        // two are indistinguishable (residual bleed rms 0.0015–0.0031 either way,
        // n=3 each) — so the tie is broken on the case that actually matters: a
        // real dictation, where the user IS speaking and playback should dip with
        // their voice rather than stay flattened for the whole hold.
        //
        // OFF asks for `.min`, not `.default`: the voice unit ducks other audio
        // whether we ask it to or not, and `.default` is a real dip — wiring the
        // "off" position to it would leave the user's music dipping after they
        // turned the control off. `.min` is the quietest ducking the API offers.
        // The honest limit, stated in Settings: on the echo-cancelling path some
        // ducking is the OS's to do, and off means "as little as macOS allows".
        var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: DarwinBoolean(duckOthers),
            mDuckingLevel: duckOthers ? .max : .min)
        let duckStatus = AudioUnitSetProperty(
            unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
            &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        guard bypassStatus != noErr || agcStatus != noErr || duckStatus != noErr else { return }
        NSLog("OLIV AudioCapture: voice-processing unit kept some defaults "
            + "(bypass \(bypassStatus), AGC \(agcStatus), ducking \(duckStatus))")
    }

    /// Hand the output volume back if THIS object ducked it. Idempotent, and the
    /// only place `didDuck` is cleared — every close path funnels through here.
    private func unduck(immediate: Bool = false) {
        duckLock.lock()
        let ducked = didDuck
        didDuck = false
        duckLock.unlock()
        // On the QUIT path, ask the ducker rather than this flag. `didDuck` is
        // cleared the moment a release starts the fade, so a release followed
        // quickly by ⌘Q would skip the synchronous restore and exit while the
        // fade was still in flight — the exact case restoreNow exists for. The
        // ducker knows whether it still owns a level; nothing owned makes this a
        // cheap no-op.
        if immediate {
            if !ducker.restoreNow(), !ducker.restoreNow() {
                NSLog("OLIV AudioCapture: could not verify the output-volume restore while "
                    + "quitting — the next launch will put it back")
            }
            return
        }
        guard ducked else { return }
        ducker.restore()
    }

    /// The device's IO buffer frame size — how many frames the HAL will actually
    /// hand each callback. 0 when unreadable (the caller falls back to the floor).
    static func deviceBufferFrameSize(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
        return status == noErr ? frames : 0
    }

    /// The HAL handed us a slice bigger than the buffer we sized from its own
    /// reported frame count. Should be unreachable; if it ever happens, the capture
    /// is being lost and the user must not be told "the mic wasn't ready".
    fileprivate func noteRenderOverflow(frames: UInt32, capacity: AVAudioFrameCount) {
        bufferLock.lock()
        let report = !overflowReported
        if report { overflowReported = true }
        bufferLock.unlock()
        guard report else { return }
        DispatchQueue.main.async {
            NSLog("OLIV AudioCapture: the input device delivered \(frames) frames but the "
                + "buffer holds \(capacity) — DROPPING AUDIO. This capture is lost.")
        }
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
        // if the unit fails to open.
        capReported = false
        overflowReported = false
        samples = []
        // Reserve the whole 10-minute ceiling ONCE, here, off the render thread.
        // 38 MB of address space (pages materialise only as you actually speak) buys
        // a hard guarantee that samples.append() in the callback never reallocates —
        // which is the difference between "the render thread does not allocate" being
        // a comment and being true.
        samples.reserveCapacity(AudioCapture.maxCaptureSamples)
        isCapturing = true
        // Stale-generation frames (an abandoned wedged unit's IOProc, still running)
        // are dropped from here on — see CaptureSession.
        generation &+= 1
        let generation = self.generation
        bufferLock.unlock()

        // Fresh throttle per capture so every recording's meter starts live.
        levelLock.lock(); levelThrottle.reset(); levelLock.unlock()

        lifecycleLock.lock()
        let opened: String
        do {
            opened = try openUnitLocked(generation: generation)
        } catch {
            lifecycleLock.unlock()
            bufferLock.lock()
            isCapturing = false      // unwind: no unit ⇒ no capture in flight
            samples = []
            bufferLock.unlock()
            throw error
        }
        lifecycleLock.unlock()

        // Outside the lock ON PURPOSE: the render thread is already delivering.
        if !opened.isEmpty { NSLog("%@", opened) }
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
        stats.backend = activeBackend
        self.stats = stats

        // A voice-processing capture that came back with NOTHING — no live
        // device, no samples — is the one failure the open-time fallback cannot
        // catch: the unit started fine and then never delivered. Distrust it for
        // the rest of this run so the next press opens the plain HAL unit, which
        // is bound to the chosen device. Losing one utterance to this is bad;
        // losing every one of them silently is the bug class this file exists to
        // end.
        if AudioCapture.shouldDistrustVoiceProcessing(
            backend: activeBackend, deviceLive: wasLive, sampleCount: captured.count)
        {
            voiceProcessingDistrusted = true
            NSLog("OLIV AudioCapture: the voice-processing unit started but delivered no audio "
                + "— falling back to the plain HAL capture for the rest of this run")
        }
        return captured
    }

    /// Close the mic (bounded, abandons a wedged unit). Idempotent; safe to call
    /// with nothing open. stop() calls it on every release, and DictationController
    /// calls it defensively when the hotkey is torn down.
    ///
    /// Returns true if the teardown completed, false if it wedged and the unit was
    /// abandoned — `stop()` carries that into `stats.stopForced` so a wedge is
    /// reported, not just logged. Nothing open is a completed teardown (true).
    @discardableResult
    func shutdown(immediate: Bool = false) -> Bool {
        // FIRST, and outside every lock: the user's music comes back the moment
        // the key is up, not after a teardown that may wedge for three seconds.
        // Idempotent, so the defensive shutdown() calls cost nothing.
        //
        // `immediate` is the QUIT path. The normal restore is a 120 ms fade on a
        // private queue, and a fade loses its race with process exit — the app
        // would exit with the volume still down and only put it back at the NEXT
        // launch. On termination we write the levels synchronously instead.
        unduck(immediate: immediate)

        lifecycleLock.lock()
        guard let ref = self.sessionRef else {
            lifecycleLock.unlock()
            return true
        }
        // Detach FIRST: a wedged teardown must never block the next start(). The
        // render thread does not read this — it holds its own session through
        // refCon — so detaching does not stop an in-flight callback. It doesn't
        // need to: that callback renders into ITS OWN unit and buffers, and its
        // frames are dropped on the generation check.
        self.sessionRef = nil
        lifecycleLock.unlock()

        bufferLock.lock()
        deviceLive = false
        bufferLock.unlock()

        let unit = ref.takeUnretainedValue().unit
        let completed = AudioCapture.boundedTeardown(
            timeout: AudioCapture.stopTimeout, queue: AudioCapture.makeTeardownQueue()) {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        if completed {
            // AudioOutputUnitStop has returned, so no callback is in flight and none
            // can start: the session (and its buffers) is now provably unreachable.
            ref.release()
        } else {
            // Abandon the wedged unit — and, with it, its session. We do NOT release
            // the +1: the unit was never stopped, so its IOProc may still fire, and
            // it must find live memory when it does. It renders into its own buffers
            // and its frames are discarded by the generation check, so it cannot
            // corrupt the next capture. Port of app/audio.py "leak the wedged stream,
            // salvage the audio" — a few hundred KB beats a callback firing into
            // freed memory. `sessionRef` is already nil, so this object is reusable.
            NSLog("OLIV AudioCapture: input unit teardown did not return within "
                + "\(AudioCapture.stopTimeout)s — abandoning wedged unit and its session "
                + "(port of app/audio.py hardened stop)")
        }
        return completed
    }

    // MARK: Internals

    /// Convert one rendered slice to 16 kHz mono and append it. Runs on the render
    /// thread: it allocates nothing (both buffers come from the session, `samples`
    /// reserved its ceiling in start()) and it logs nothing inline — the three
    /// one-shot events hop to main at the end.
    fileprivate func appendConverted(from session: CaptureSession) {
        let input = session.renderBuffer
        let output = session.convertBuffer
        guard input.frameLength > 0 else { return }

        var consumed = false
        var convError: NSError?
        let status = session.converter.convert(to: output, error: &convError) { _, inputStatus in
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

        // THE GENERATION GATE. This is what makes abandoning a wedged unit safe: its
        // IOProc is still running and still calling us, but it belongs to a capture
        // that is over. Its frames are not this utterance's frames.
        guard AudioCapture.acceptsFrames(
            sessionGeneration: session.generation, currentGeneration: generation)
        else {
            bufferLock.unlock()
            return
        }

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

        // OFF THE RENDER THREAD. NSLog takes locks and does I/O; calling it inline
        // here — which an earlier revision did — put a filesystem write in the audio
        // callback at the exact instant speech starts. Each of these fires at most
        // once per capture, so the hop to main is cheap and, unlike NSLog, bounded.
        guard wentLive || forcedLive || reportCap else { return }
        DispatchQueue.main.async {
            if wentLive {
                NSLog("OLIV AudioCapture: input device is live (first non-zero frame)")
            }
            if forcedLive {
                NSLog("OLIV AudioCapture: input device produced only digital silence for "
                    + "\(AudioCapture.liveWaitTimeout)s — capturing anyway; "
                    + "is the right mic selected?")
            }
            if reportCap {
                NSLog("OLIV AudioCapture: capture hit the "
                    + "\(Int(AudioCapture.maxCaptureSeconds))s ceiling — dropping further "
                    + "audio for this capture (missed release / stuck hotkey?)")
            }
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

    /// Do frames from a session opened at `sessionGeneration` belong in the capture
    /// currently running at `currentGeneration`?
    ///
    /// The whole safety argument for abandoning a wedged unit rests on this
    /// returning false for the zombie. Pure so it unit-tests without a mic — the
    /// live path (appendConverted, emitLevel) calls exactly this function.
    static func acceptsFrames(sessionGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        sessionGeneration == currentGeneration
    }

    /// Frames the 16 kHz conversion buffer must hold for one `maxFrames` slice off a
    /// device running at `deviceRate`.
    ///
    /// The ratio EXCEEDS 1 when the device runs below 16 kHz, so this is not just
    /// `maxFrames` — an 8 kHz device needs twice the room. Pure so the sizing math
    /// unit-tests mic-free; under-allocating here silently truncates every buffer.
    static func convertCapacity(maxFrames: UInt32, deviceRate: Double) -> AVAudioFrameCount {
        guard deviceRate > 0 else { return AVAudioFrameCount(maxFrames) + 64 }
        let ratio = targetSampleRate / deviceRate
        return AVAudioFrameCount((Double(maxFrames) * ratio).rounded(.up)) + 64
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
    fileprivate func emitLevel(from session: CaptureSession) {
        // Nothing to meter until the device is awake: while a Bluetooth link comes
        // up the buffers are exact zeros, the HUD is showing "getting the mic
        // ready", and `update(level:)` drops anything that isn't the recording
        // phase anyway. Bail before the RMS and the hop to main.
        //
        // The generation check comes along for the ride: an abandoned unit's zombie
        // IOProc must not drive the meter of a capture it has nothing to do with.
        bufferLock.lock()
        let live = isCapturing && deviceLive && AudioCapture.acceptsFrames(
            sessionGeneration: session.generation, currentGeneration: generation)
        bufferLock.unlock()
        guard live else { return }
        let buffer = session.renderBuffer

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
