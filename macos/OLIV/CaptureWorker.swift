import Foundation

struct CaptureOptions {
    var device = MicSelection.builtIn
    var echoCancellation = true
    var duckOtherAudio = true
    var retryVoiceProcessing = false
    var maxSeconds = AudioCapture.maxCaptureSeconds
}

/// A release can arrive while Core Audio is still configuring the device.
/// Its cancellation is visible to that work without waiting for the main actor.
final class CaptureStartRequest: @unchecked Sendable {
    let pressedAt = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var held = true
    private var started = false
    private var startFailed = false

    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    var didStart: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var failedToStart: Bool { lock.lock(); defer { lock.unlock() }; return startFailed }
    func cancel() { lock.lock(); held = false; lock.unlock() }
    func markStarted() { lock.lock(); started = true; lock.unlock() }
    func markFailed() { lock.lock(); startFailed = true; lock.unlock() }
}

struct CapturedAudio {
    let samples: [Float]
    let stats: AudioCapture.CaptureStats?
    var cancelledBeforeStart = false
}

/// All capture configuration and lifecycle calls share one worker. In
/// particular, stop cannot race an unfinished open, and changing Settings
/// during an open cannot change that recording's device or AEC configuration.
// Mutable capture state is confined to queue; the two read-only observations
// and immediate output restore use AudioCapture's own locks.
final class CaptureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.oliv.capture", qos: .userInitiated)
    private let startCapture: (CaptureOptions, CaptureStartRequest) throws -> Void
    private let stopCapture: () -> CapturedAudio
    private let closeCapture: () -> Void
    private let restoreOutput: () -> Void
    private let liveDevice: () -> Bool
    private let startupTime: () -> TimeInterval?
    private var activeRequest: CaptureStartRequest?  // confined to queue
    var isDeviceLive: Bool { liveDevice() }
    var startupSeconds: TimeInterval? { startupTime() }

    convenience init(audio: AudioCapture) {
        self.init(start: { options, request in
            if options.retryVoiceProcessing { audio.retryVoiceProcessing() }
            audio.deviceSelection = options.device
            audio.echoCancellation = options.echoCancellation
            audio.duckOtherAudio = options.duckOtherAudio
            try audio.start(maxSeconds: options.maxSeconds, pressedAt: request.pressedAt,
                            shouldContinue: { request.isHeld })
        }, stop: {
            let samples = audio.stop()
            return CapturedAudio(samples: samples, stats: audio.stats)
        }, close: {
            // shutdown alone tears down the unit without disarming the capture
            // buffer. A release racing the successful open must also stop that
            // buffer, or the next press would fail with alreadyRunning.
            if audio.isRunning { _ = audio.stop() } else { audio.shutdown() }
        }, restoreOutput: { audio.restoreOutputImmediately() },
                  isDeviceLive: { audio.isDeviceLive }, startupSeconds: { audio.startupSeconds })
    }

    /// Hardware-free seam for exercising delayed opens and rapid releases.
    init(start: @escaping (CaptureOptions, CaptureStartRequest) throws -> Void,
         stop: @escaping () -> CapturedAudio, close: @escaping () -> Void,
         restoreOutput: @escaping () -> Void = {},
         isDeviceLive: @escaping () -> Bool = { false },
         startupSeconds: @escaping () -> TimeInterval? = { nil }) {
        startCapture = start
        stopCapture = stop
        closeCapture = close
        self.restoreOutput = restoreOutput
        liveDevice = isDeviceLive
        startupTime = startupSeconds
    }

    func start(options: CaptureOptions, request: CaptureStartRequest,
               completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            activeRequest = request
            let result = Result<Void, Error> {
                guard request.isHeld else { throw AudioCapture.CaptureError.startCancelled }
                try startCapture(options, request)
                request.markStarted()
            }
            if case let .failure(error) = result {
                if case AudioCapture.CaptureError.startCancelled = error {} else { request.markFailed() }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stop(request: CaptureStartRequest) async -> CapturedAudio {
        request.cancel()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                // A cancelled processing task can enqueue its stop after a new
                // press. It must never stop that newer recording.
                guard activeRequest === request else {
                    continuation.resume(returning: CapturedAudio(
                        samples: [], stats: nil, cancelledBeforeStart: true))
                    return
                }
                activeRequest = nil
                guard request.didStart else {
                    closeCapture()
                    continuation.resume(returning: CapturedAudio(
                        samples: [], stats: nil, cancelledBeforeStart: !request.failedToStart))
                    return
                }
                continuation.resume(returning: stopCapture())
            }
        }
    }

    func cancelOpening(request: CaptureStartRequest) {
        request.cancel()
        queue.async { [self] in
            guard activeRequest === request else { return }
            activeRequest = nil
            closeCapture()
        }
    }

    func shutdown(request: CaptureStartRequest?, immediate: Bool) {
        request?.cancel()
        // A fade queued behind an unfinished open will not survive app exit.
        // OutputDucker owns its lock, so restoring it does not wait on Core Audio.
        if immediate { restoreOutput() }
        queue.async { [self] in
            activeRequest = nil
            closeCapture()
        }
    }
}
