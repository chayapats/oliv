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

    // MARK: The generation gate (what makes abandoning a wedged unit safe)

    // shutdown() ABANDONS a wedged audio unit without stopping it — so its IOProc
    // keeps running and keeps calling back. The ONLY thing standing between that
    // zombie and the next utterance is this check. If it ever returns true for a
    // stale session, the abandoned unit's frames get spliced into whatever the user
    // says next, and two threads race on the sample buffer.
    func testFramesFromTheLiveSessionAreAccepted() {
        XCTAssertTrue(AudioCapture.acceptsFrames(sessionGeneration: 7, currentGeneration: 7))
    }

    func testFramesFromAnAbandonedSessionAreRejected() {
        // The wedged unit was opened for capture 7; the user has since started 8.
        XCTAssertFalse(
            AudioCapture.acceptsFrames(sessionGeneration: 7, currentGeneration: 8),
            "an abandoned unit's IOProc must not append into a later capture")
        // And it must stay rejected no matter how many captures go by.
        XCTAssertFalse(
            AudioCapture.acceptsFrames(sessionGeneration: 7, currentGeneration: 99))
    }

    // MARK: Conversion buffer sizing (pre-allocated, so it must be right up front)

    // The render thread must not allocate, so the 16 kHz buffer is sized ONCE at
    // open. Under-allocate and every slice is silently truncated.
    func testConvertCapacityForA48kDeviceDownsamples() {
        // 48 kHz -> 16 kHz is a third of the frames; the buffer only needs headroom.
        let capacity = AudioCapture.convertCapacity(maxFrames: 4096, deviceRate: 48000)
        XCTAssertGreaterThanOrEqual(capacity, 4096 / 3)
        XCTAssertLessThan(capacity, 4096, "a downsampled slice should not need the full input size")
    }

    // The case a naive `capacity = maxFrames` gets WRONG: a device slower than the
    // 16 kHz target produces MORE frames than it consumed.
    func testConvertCapacityForASubTargetDeviceUpsamples() {
        let capacity = AudioCapture.convertCapacity(maxFrames: 4096, deviceRate: 8000)
        XCTAssertGreaterThanOrEqual(
            capacity, 8192, "an 8 kHz device doubles the frame count on the way to 16 kHz")
    }

    // AirPods in their HFP call profile — the device that started this whole bug.
    func testConvertCapacityForAirPodsHFP() {
        let capacity = AudioCapture.convertCapacity(maxFrames: 4096, deviceRate: 24000)
        XCTAssertGreaterThanOrEqual(capacity, 2731)   // 4096 * 16/24, rounded up
    }

    // A device that reports a nonsense rate must not produce a zero-sized buffer.
    func testConvertCapacityWithAnUnreadableRateStillAllocates() {
        XCTAssertGreaterThan(AudioCapture.convertCapacity(maxFrames: 4096, deviceRate: 0), 4096)
    }

    // MARK: Slice sizing (the silent-total-loss bug)

    // 4096 is a FLOOR, not a ceiling: kAudioUnitProperty_MaximumFramesPerSlice does
    // not constrain what the HAL hands you, so a device with a larger IO buffer used
    // to overflow the render buffer — and the callback answered by dropping every
    // frame, forever, while reporting "the mic wasn't ready".
    func testMinFramesPerSliceIsAFloorNotACeiling() {
        XCTAssertEqual(max(AudioCapture.deviceBufferFrameSize(0), AudioCapture.minFramesPerSlice),
                       AudioCapture.minFramesPerSlice,
                       "an unreadable device falls back to the floor")
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

    // MARK: Echo-cancellation policy (0.1.10 speaker bleed)

    // Speakers are where the bleed is, so that is where the canceller goes.
    func testVoiceProcessingUsedForASpeakerLoop() {
        XCTAssertTrue(AudioCapture.shouldUseVoiceProcessing(
            enabled: true, isSystemDefaultInput: true,
            inputIsBluetooth: false, outputIsBluetooth: false))
    }

    // The toggle is absolute: off means the pre-0.1.10 HAL path, whatever the
    // devices are. It exists precisely so a user whose mic the voice unit
    // degrades can get the old capture back.
    func testDisabledMeansNoVoiceProcessing() {
        XCTAssertFalse(AudioCapture.shouldUseVoiceProcessing(
            enabled: false, isSystemDefaultInput: true,
            inputIsBluetooth: false, outputIsBluetooth: false))
    }

    // THE constraint that shapes this whole path: the voice unit cannot be bound
    // to a chosen microphone (measured: -10875 in every bound configuration), so
    // it records the system default input. When the picked mic ISN'T that device,
    // using it would record a different microphone than the picker names — the
    // exact class of silent lie the mic picker exists to end. HAL instead.
    func testNonDefaultInputSkipsVoiceProcessing() {
        XCTAssertFalse(AudioCapture.shouldUseVoiceProcessing(
            enabled: true, isSystemDefaultInput: false,
            inputIsBluetooth: false, outputIsBluetooth: false),
            "never record a different mic than the one the user picked")
    }

    // Neither end of a Bluetooth loop gets the voice unit: it is duplex, so
    // handing it a Bluetooth endpoint risks the A2DP → HFP flip that drops the
    // user's music to call quality (the regression AudioDevices exists to
    // prevent), and headphones don't leak into the mic, so there is nothing to
    // cancel in exchange.
    func testBluetoothEitherEndSkipsVoiceProcessing() {
        XCTAssertFalse(AudioCapture.shouldUseVoiceProcessing(
            enabled: true, isSystemDefaultInput: true,
            inputIsBluetooth: true, outputIsBluetooth: false),
            "a Bluetooth mic must not be handed to the voice unit")
        XCTAssertFalse(AudioCapture.shouldUseVoiceProcessing(
            enabled: true, isSystemDefaultInput: true,
            inputIsBluetooth: false, outputIsBluetooth: true),
            "Bluetooth playback must keep its A2DP profile while dictating")
    }

    // The backend a capture ran on is REPORTED, not inferred: a silent fallback
    // to the plain HAL would otherwise look exactly like a working canceller.
    func testStatsDefaultToTheHALBackend() {
        let capture = AudioCapture()
        _ = capture.stop()
        XCTAssertEqual(capture.stats?.backend, .hal)
    }

    // The pre-open device checks are time-of-check/time-of-use: macOS promotes a
    // headset to default input AND output the moment it connects, and the unbound
    // voice unit follows the default. So the route is checked AGAIN once the unit
    // is running, and a change retires that attempt in favour of the bound HAL
    // unit.
    func testRouteRecheckAcceptsAnUnchangedRoute() {
        XCTAssertTrue(AudioCapture.routeStillSuitable(
            deviceID: 80, systemDefaultInputID: 80, outputIsBluetooth: false))
    }

    func testRouteRecheckRejectsADefaultInputThatMovedUnderUs() {
        XCTAssertFalse(AudioCapture.routeStillSuitable(
            deviceID: 80, systemDefaultInputID: 99, outputIsBluetooth: false),
            "the voice unit would now be recording a different mic than the picker names")
    }

    func testRouteRecheckRejectsABluetoothOutputThatJustConnected() {
        XCTAssertFalse(AudioCapture.routeStillSuitable(
            deviceID: 80, systemDefaultInputID: 80, outputIsBluetooth: true),
            "a headset that connected mid-open must keep its A2DP profile")
    }

    // The failure the open-time fallback CANNOT see: the voice unit starts fine
    // and then delivers nothing. One such capture demotes the rest of the run to
    // the plain HAL path.
    func testVoiceProcessingThatDeliveredNothingIsDistrusted() {
        XCTAssertTrue(AudioCapture.shouldDistrustVoiceProcessing(
            backend: .voiceProcessing, deviceLive: false, sampleCount: 0))
    }

    // A HAL capture that comes back empty is the user holding the key without
    // speaking — it must demote nothing.
    func testAnEmptyHALCaptureDemotesNothing() {
        XCTAssertFalse(AudioCapture.shouldDistrustVoiceProcessing(
            backend: .hal, deviceLive: false, sampleCount: 0))
    }

    // Toggling echo cancellation is the user's explicit "try again": it must
    // clear a demotion an earlier failure left behind, or Settings would show the
    // feature ON while every capture quietly ran without it.
    func testTogglingEchoCancellationClearsTheDemotion() {
        let capture = AudioCapture()
        capture.voiceProcessingDistrusted = true          // as a failed capture leaves it
        capture.echoCancellation = false
        capture.echoCancellation = true                   // the user's "try again"
        XCTAssertFalse(capture.voiceProcessingDistrusted,
                       "toggling the setting must actually clear the demotion, not just look like it")
        XCTAssertTrue(capture.echoCancellation)
    }

    // …and a write that does NOT change the value is not a reset gesture: assigning
    // the same value must leave a demotion in place, or a settings pane that
    // re-applies its state on every appearance would silently undo the fallback.
    func testReassigningTheSameEchoCancellationValueKeepsTheDemotion() {
        let capture = AudioCapture()
        capture.echoCancellation = true
        capture.voiceProcessingDistrusted = true
        capture.echoCancellation = true
        XCTAssertTrue(capture.voiceProcessingDistrusted)
    }

    // Neither does a voice capture that actually worked.
    func testAWorkingVoiceCaptureIsNotDistrusted() {
        XCTAssertFalse(AudioCapture.shouldDistrustVoiceProcessing(
            backend: .voiceProcessing, deviceLive: true, sampleCount: 16000))
        XCTAssertFalse(AudioCapture.shouldDistrustVoiceProcessing(
            backend: .voiceProcessing, deviceLive: true, sampleCount: 0))
    }

    // A voice unit that will not OPEN is broken on this machine, and it will be
    // broken on the next press too. Trying it again every time makes the user pay
    // the fallback — up to a quarter-second before the HAL unit is listening — at
    // the start of every single utterance, when the whole point of the fallback
    // is that it is paid once. (It was: the open-failure path was the one demotion
    // route that never set the flag.)
    func testAVoiceUnitThatWillNotOpenIsDistrustedForTheRun() {
        XCTAssertTrue(AudioCapture.shouldDistrustAfterFailedOpen(
            backend: .voiceProcessing,
            error: AudioCapture.CaptureError.unitStartFailed(-10875)))
        XCTAssertTrue(AudioCapture.shouldDistrustAfterFailedOpen(
            backend: .voiceProcessing, error: AudioCapture.CaptureError.unitUnavailable(-10875)))
    }

    // …with one exception. A route change is a property of the MOMENT, not of the
    // machine: the headset that just connected made THIS press take the HAL path,
    // and turning that into a demotion would cost the user echo cancellation for
    // the rest of the run because they plugged something in once.
    func testARouteChangeDuringOpenDoesNotDemoteTheRun() {
        XCTAssertFalse(AudioCapture.shouldDistrustAfterFailedOpen(
            backend: .voiceProcessing, error: AudioCapture.CaptureError.routeChangedWhileOpening))
    }

    // A HAL failure has nothing to demote to, and must never set the flag: the
    // next press would then skip the voice unit for no reason at all.
    func testAFailedHALOpenDemotesNothing() {
        XCTAssertFalse(AudioCapture.shouldDistrustAfterFailedOpen(
            backend: .hal, error: AudioCapture.CaptureError.unitStartFailed(-1)))
    }
}

