// AudioCapture tests — the mic-free parts. The full capture path needs a real
// microphone (and mic permission), so we don't test it in the unit suite; the
// live probe is app/__main__.py's --audio-test. What IS testable without a mic
// is the bounded-stop timeout logic — the whole point of the hardened stop —
// isolated behind AudioCapture.boundedTeardown, exercised here with a
// wedge-simulating closure exactly like app/__main__.py's --audio-unittest [4]
// fakes a wedged stream (_WedgedStream).

import XCTest
@testable import OLIV

final class AudioCaptureTests: XCTestCase {
    // --audio-unittest [4] core: a teardown that returns promptly completes.
    func testBoundedTeardownCompletesWhenFast() {
        let queue = DispatchQueue(label: "com.oliv.test.audio.fast")
        let completed = AudioCapture.boundedTeardown(timeout: 1.0, queue: queue) {
            // returns immediately
        }
        XCTAssertTrue(completed)
    }

    // --audio-unittest [4]: a WEDGED teardown (blocks forever, like Pa_StopStream
    // wedging >8min live in Wave 1) must be BOUNDED — boundedTeardown returns
    // false well within the timeout so stop() can abandon the engine and salvage
    // the audio rather than hang.
    func testBoundedTeardownReportsWedge() {
        let queue = DispatchQueue(label: "com.oliv.test.audio.wedge")
        let start = Date()
        let completed = AudioCapture.boundedTeardown(timeout: 0.3, queue: queue) {
            // Block forever — the leaked worker mimics a wedged Core Audio stop.
            DispatchSemaphore(value: 0).wait()
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(completed, "wedged teardown must report not-completed")
        XCTAssertLessThan(elapsed, 2.0, "bounded: must not block for the full wedge")
        XCTAssertGreaterThanOrEqual(elapsed, 0.3, "waited at least the timeout before abandoning")
    }

    // The salvage math: stats over a known buffer (peak / rms / duration) so the
    // returned utterance is always described, even on a forced stop.
    func testComputeStatsOverKnownBuffer() {
        let samples: [Float] = [0.5, -0.5, 0.25, -0.25]
        let stats = AudioCapture.computeStats(samples: samples, deviceSampleRate: 48000, stopForced: true)
        XCTAssertEqual(stats.sampleCount, 4)
        XCTAssertEqual(stats.sampleRate, AudioCapture.targetSampleRate)
        XCTAssertEqual(stats.deviceSampleRate, 48000)
        XCTAssertTrue(stats.stopForced)
        XCTAssertEqual(stats.peak, 0.5, accuracy: 1e-6)
        // rms = sqrt(mean(x^2)) = sqrt((0.25+0.25+0.0625+0.0625)/4) = sqrt(0.15625)
        XCTAssertEqual(stats.rms, Float(0.15625.squareRoot()), accuracy: 1e-6)
        XCTAssertEqual(stats.durationSeconds, 4.0 / AudioCapture.targetSampleRate, accuracy: 1e-9)
    }

    func testComputeStatsEmptyBuffer() {
        let stats = AudioCapture.computeStats(samples: [], deviceSampleRate: 16000, stopForced: false)
        XCTAssertEqual(stats.sampleCount, 0)
        XCTAssertEqual(stats.peak, 0)
        XCTAssertEqual(stats.rms, 0)
        XCTAssertEqual(stats.durationSeconds, 0)
    }

    // Permission preflight must not crash regardless of the machine's TCC state.
    func testAuthorizationStatusDoesNotCrash() {
        let capture = AudioCapture()
        _ = capture.authorizationStatus()
    }

    // stop() with no active capture is graceful (empty buffer + zeroed stats),
    // not a crash — the coordinator-friendly deviation from Recorder.stop().
    func testStopWithoutStartIsGraceful() {
        let capture = AudioCapture()
        let samples = capture.stop()
        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(capture.stats?.sampleCount, 0)
        XCTAssertFalse(capture.isRunning)
    }

    // MARK: Teardown-queue independence (post-release hardening)

    // Regression guard for the serial-queue cascade: teardown queues must be
    // INDEPENDENT, so one permanently wedged teardown can never make every
    // later stop() time out behind it on a shared serial queue. stop() builds a
    // FRESH queue per teardown via makeTeardownQueue(); if that ever regresses
    // to a shared serial queue, the second teardown here queues behind the
    // wedge and reports false.
    func testWedgedTeardownDoesNotBlockLaterTeardown() {
        let wedge = DispatchSemaphore(value: 0)
        defer { wedge.signal() }   // free the leaked worker once we've asserted
        let first = AudioCapture.boundedTeardown(
            timeout: 0.1, queue: AudioCapture.makeTeardownQueue()
        ) {
            wedge.wait()           // wedged "forever", like a stuck Core Audio stop
        }
        XCTAssertFalse(first, "the wedged teardown itself must report not-completed")
        let second = AudioCapture.boundedTeardown(
            timeout: 1.0, queue: AudioCapture.makeTeardownQueue()
        ) {
            // returns immediately
        }
        XCTAssertTrue(second, "a wedged earlier teardown must not cascade into later stops")
    }

    // MARK: Capture cap (post-release hardening)

    // The cap math: how many incoming frames still fit under the ceiling. Under
    // the cap takes all; crossing it truncates; at/over it drops everything —
    // never negative.
    func testAppendBudgetUnderCapTakesAll() {
        XCTAssertEqual(AudioCapture.appendBudget(current: 0, incoming: 4096, limit: 10_000), 4096)
    }

    func testAppendBudgetCrossingCapTruncates() {
        XCTAssertEqual(AudioCapture.appendBudget(current: 9_000, incoming: 4096, limit: 10_000), 1_000)
    }

    func testAppendBudgetAtOrOverCapDropsAll() {
        XCTAssertEqual(AudioCapture.appendBudget(current: 10_000, incoming: 4096, limit: 10_000), 0)
        XCTAssertEqual(AudioCapture.appendBudget(current: 12_000, incoming: 1, limit: 10_000), 0)
    }

    // The shipped ceiling: 10 minutes at the 16 kHz target rate — far beyond any
    // real push-to-talk utterance, small enough that a stuck hotkey can't grow
    // the buffer (and its Data/base64/JSON copies downstream) without bound.
    func testMaxCaptureSamplesIsTenMinutesAt16k() {
        XCTAssertEqual(AudioCapture.maxCaptureSamples,
                       Int(600 * AudioCapture.targetSampleRate))
    }

    // Hitting the cap must be REPORTED, not silent: stop() carries the flag
    // through CaptureStats so the release worker can tell the user the tail
    // was cut (same describe-the-salvage stance as stopForced).
    func testComputeStatsCarriesCappedFlag() {
        let capped = AudioCapture.computeStats(
            samples: [0.1], deviceSampleRate: 48000, stopForced: false, capped: true)
        XCTAssertTrue(capped.capped)
        let normal = AudioCapture.computeStats(
            samples: [0.1], deviceSampleRate: 48000, stopForced: false, capped: false)
        XCTAssertFalse(normal.capped)
    }

    // MARK: W4-T2 live-level metering seams (pure, mic-free)

    // The throttle gates callbacks to the cadence: the first emits, ones inside
    // the window are dropped, and one at/after the window emits again.
    func testLevelThrottleEmitsAtCadence() {
        var throttle = AudioCapture.LevelThrottle(minInterval: 0.04)   // ~24 Hz
        XCTAssertTrue(throttle.shouldEmit(at: 0.00))    // first always emits
        XCTAssertFalse(throttle.shouldEmit(at: 0.02))   // too soon
        XCTAssertFalse(throttle.shouldEmit(at: 0.039))  // still inside the window
        XCTAssertTrue(throttle.shouldEmit(at: 0.05))    // window elapsed → emit
        XCTAssertFalse(throttle.shouldEmit(at: 0.06))   // window re-armed at 0.05
        XCTAssertTrue(throttle.shouldEmit(at: 0.11))
    }

    // reset() re-arms so the next call emits immediately (each recording starts
    // its meter live — start() resets the throttle).
    func testLevelThrottleResetReArms() {
        var throttle = AudioCapture.LevelThrottle(minInterval: 1.0)
        XCTAssertTrue(throttle.shouldEmit(at: 100))
        XCTAssertFalse(throttle.shouldEmit(at: 100.5))
        throttle.reset()
        XCTAssertTrue(throttle.shouldEmit(at: 100.6))
    }

    // The dBFS mapping: silence → 0, louder ⇒ higher, full-scale clamps to 1,
    // and the output stays in 0…1.
    func testNormalizedLevelMapping() {
        XCTAssertEqual(AudioCapture.normalizedLevel(rms: 0), 0, accuracy: 1e-6)
        let quiet = AudioCapture.normalizedLevel(rms: 0.001)
        let loud = AudioCapture.normalizedLevel(rms: 0.3)
        XCTAssertGreaterThan(loud, quiet, "louder must map higher")
        XCTAssertGreaterThanOrEqual(quiet, 0.0)
        XCTAssertLessThanOrEqual(loud, 1.0)
        XCTAssertEqual(AudioCapture.normalizedLevel(rms: 1.0), 1.0, accuracy: 1e-6)
    }

    // MARK: Warm-mic seams (Bluetooth dead-lead-in fix)
    //
    // Measured root cause: a cold AVAudioEngine per press gives a Bluetooth (HFP)
    // mic 0.5–3 s of DIGITAL ZEROS before its input link is up — a whole 3 s
    // push-to-talk utterance landed entirely inside that hole (dead lead-in
    // 2.901 s of a 2.90 s clip; whole-clip RMS 0.00000), so the sidecar's
    // _is_silent() gate (_SILENCE_RMS = 0.005) dropped it and OLIV typed nothing.
    // The same probe on the built-in mic: 0.000 s dead lead-in, RMS 0.028–0.040.
    // Fix = keep the engine warm across presses. These are its pure seams.

    // Liveness: a device that is still warming up emits EXACTLY 0.0 samples; a
    // real mic always carries a noise floor. That's the discriminator we use to
    // decide "the device is awake, start accumulating".
    func testBufferHasSignalDetectsDigitalSilence() {
        XCTAssertFalse(AudioCapture.bufferHasSignal([0, 0, 0, 0]),
                       "all-zero (digital silence) = device not live yet")
        XCTAssertFalse(AudioCapture.bufferHasSignal([]),
                       "no samples = nothing to prove liveness")
    }

    func testBufferHasSignalDetectsRealMicNoiseFloor() {
        // A quiet room on the built-in mic still reads ~0.002 — that IS liveness.
        XCTAssertTrue(AudioCapture.bufferHasSignal([0, 0, 0.0019, 0]))
        XCTAssertTrue(AudioCapture.bufferHasSignal([-0.0005]),
                      "sign must not matter — magnitude does")
    }

    // deviceLive rides in CaptureStats so the release worker can tell "held the
    // key without speaking" from "spoke into a mic that never woke up". Reporting
    // those two the same way — a silent no-op — is what hid the Bluetooth bug.
    func testComputeStatsDefaultsDeviceLiveToFalse() {
        let stats = AudioCapture.computeStats(
            samples: [0.1], deviceSampleRate: 48000, stopForced: false)
        XCTAssertFalse(stats.deviceLive,
                       "absent proof of a live mic, assume it never woke")
    }

    // A wedged teardown must still be REPORTED. stop() lifts the samples out
    // first, then tears down; shutdown() returns whether that completed and stop()
    // carries it into stats.stopForced. Regression guard for the refactor that
    // moved teardown out of stop(): it briefly hard-coded stopForced to false,
    // silently killing the signal the hardened-stop header promises.
    func testShutdownWithNoEngineReportsCompleted() {
        let capture = AudioCapture()
        XCTAssertTrue(capture.shutdown(),
                      "nothing to tear down is a COMPLETED teardown, not a wedge")
    }

    // A stray release must not fabricate a wedge either.
    func testStopWithoutStartDoesNotReportStopForced() {
        let capture = AudioCapture()
        _ = capture.stop()
        XCTAssertEqual(capture.stats?.stopForced, false)
        XCTAssertEqual(capture.stats?.deviceLive, false)
    }
}

