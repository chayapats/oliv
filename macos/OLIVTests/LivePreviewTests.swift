import AppKit
import AVFoundation
import XCTest
@testable import OLIV

final class LivePreviewGovernorTests: XCTestCase {
    private func governor(_ change: (inout LivePreviewGovernor.Policy) -> Void = { _ in }) -> LivePreviewGovernor {
        var policy = LivePreviewGovernor.Policy()
        change(&policy)
        return LivePreviewGovernor(policy: policy)
    }

    func testOneInFlightAndEnoughNewAudioBeforeTheNextPreview() {
        let g = governor()
        XCTAssertEqual(g.decide(now: 10, lastStart: nil, inFlight: false, audioSeconds: 0.4, previewedAudioSeconds: 0), .wait)
        XCTAssertEqual(g.decide(now: 10, lastStart: nil, inFlight: false, audioSeconds: 0.6, previewedAudioSeconds: 0), .start)
        XCTAssertEqual(g.decide(now: 10, lastStart: nil, inFlight: true, audioSeconds: 5, previewedAudioSeconds: 0), .busy)
        // Too soon after the last start, then too little new audio.
        XCTAssertEqual(g.decide(now: 10.2, lastStart: 10, inFlight: false, audioSeconds: 5, previewedAudioSeconds: 2), .wait)
        XCTAssertEqual(g.decide(now: 10.5, lastStart: 10, inFlight: false, audioSeconds: 2.1, previewedAudioSeconds: 2), .wait)
        XCTAssertEqual(g.decide(now: 10.5, lastStart: 10, inFlight: false, audioSeconds: 2.3, previewedAudioSeconds: 2), .start)
    }

    func testIntervalBacksOffWithWhatEachPreviewCosts() {
        var g = governor()
        XCTAssertEqual(g.interval, 0.3)
        g.record(seconds: 0.6)          // keep busy ≤ 75% → 0.8 s apart
        XCTAssertEqual(g.interval, 0.8, accuracy: 1e-9)
        XCTAssertEqual(g.decide(now: 10.7, lastStart: 10, inFlight: false, audioSeconds: 9, previewedAudioSeconds: 2), .wait)
        XCTAssertEqual(g.decide(now: 10.85, lastStart: 10, inFlight: false, audioSeconds: 9, previewedAudioSeconds: 2), .start)
        g.record(seconds: 0.1)
        XCTAssertEqual(g.interval, 0.3, accuracy: 1e-9)
        XCTAssertFalse(g.isDisabled)
    }

    func testPreviewsThatCantKeepUpTurnOffForTheRun() {
        var g = governor()
        g.record(seconds: 2.0)            // warm-up: paces, never counts
        XCTAssertFalse(g.isDisabled)
        XCTAssertEqual(g.interval, 1.5)   // capped at the slowest cadence
        g.record(seconds: 2.0)            // slow 1
        g.record(seconds: 0.1)            // a fast one resets the streak
        g.record(seconds: 1.1)            // fits 75% of a 1.5 s cadence: not slow
        g.record(seconds: 1.2)            // slow: needs over 1.5 s between previews
        XCTAssertFalse(g.isDisabled)
        g.record(seconds: 1.15)           // slow 2 in a row
        XCTAssertTrue(g.isDisabled)
        XCTAssertEqual(g.decide(now: 100, lastStart: nil, inFlight: false, audioSeconds: 9, previewedAudioSeconds: 0), .off)
        g.record(seconds: 0.05)         // never back on within the run
        XCTAssertTrue(g.isDisabled)
    }

    /// A Mac about 3.5× slower than the M4 Pro the policy was measured on (a
    /// base M1's GPU): previews space out instead of crowding the GPU, and
    /// turn off once a long hold makes them take over 1.125 s each.
    func testASlowerMacSpacesPreviewsOutThenTurnsThemOff() {
        var g = governor()
        let m4Pro = [0.18, 0.2, 0.22, 0.25, 0.3]        // a few seconds of speech (#46)
        for seconds in m4Pro { g.record(seconds: seconds) }
        XCTAssertEqual(g.interval, 0.4, accuracy: 1e-9)  // 0.3 s / 0.75
        var m1 = governor()
        for seconds in m4Pro.map({ $0 * 3.5 }) {
            m1.record(seconds: seconds)
            XCTAssertFalse(m1.isDisabled)
        }
        XCTAssertEqual(m1.interval, 1.4, accuracy: 1e-9) // 1.05 s / 0.75: spaced out
        // A 10 s window costs about 0.6 s on the M4 Pro, 2.1 s on the M1.
        m1.record(seconds: 0.6 * 3.5)
        m1.record(seconds: 0.6 * 3.5)
        XCTAssertEqual(m1.disabledReason, "previews can't keep up on this Mac")
        g.record(seconds: 0.6)
        g.record(seconds: 0.6)
        XCTAssertFalse(g.isDisabled)
    }

    func testReleasesHeldUpByACancelledPreviewTurnPreviewsOff() {
        var g = governor()
        g.recordRelease(waited: 0.4)
        g.recordRelease(waited: 0.02)                     // resets
        g.recordRelease(waited: 0.4)
        XCTAssertFalse(g.isDisabled)
        g.recordRelease(waited: 0.3)
        XCTAssertTrue(g.isDisabled)
        XCTAssertEqual(g.disabledReason, "a cancelled preview delayed the final text")
    }

    func testRepeatedFailuresTurnPreviewsOff() {
        var g = governor()
        g.recordFailure()
        g.record(seconds: 0.1)           // a success resets
        g.recordFailure()
        XCTAssertFalse(g.isDisabled)
        g.recordFailure()
        XCTAssertTrue(g.isDisabled)
    }

    func testAFailedDecodePacesAndCountsTowardBothGuards() {
        var g = governor()
        g.record(seconds: 0.1)                 // warm-up
        g.recordFailure(seconds: 0.6)          // the model ran: its cost paces the next one
        XCTAssertEqual(g.interval, 0.8, accuracy: 1e-9)
        XCTAssertFalse(g.isDisabled)
        g.recordFailure(seconds: 0.1)          // a second failure in a row
        XCTAssertEqual(g.disabledReason, "previews failed")

        var slow = governor()
        slow.record(seconds: 0.1)              // warm-up
        slow.record(seconds: 1.2)              // slow 1
        slow.recordFailure(seconds: 1.2)       // slow 2, though it failed
        XCTAssertEqual(slow.disabledReason, "previews can't keep up on this Mac")

        var errored = governor()
        errored.record(seconds: 0.6)
        errored.recordFailure()                // the sidecar errored: no decode to pace by
        XCTAssertEqual(errored.interval, 0.8, accuracy: 1e-9)
    }

    func testSequenceNumbersOnlyGrowAcrossHolds() {
        let pacer = LivePreviewPacer()
        let first = pacer.nextSeq(), second = pacer.nextSeq()
        XCTAssertLessThan(first, second)
        XCTAssertGreaterThan(first, 0)
    }
}

final class LivePreviewEligibilityTests: XCTestCase {
    func testNoSnapshotWithoutARecording() {
        var buffer = [Float](repeating: 7, count: 4)
        let result = AudioCapture().copyLatestSamples(into: &buffer)
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(buffer, [7, 7, 7, 7])
    }

    func testOnlyOnDeviceEnginesPreview() {
        for engine in OLIVSettings.Engine.local {
            XCTAssertTrue(LivePreview.isEligible(engine: engine.id), engine.id)
        }
        for engine in [SidecarClient.cloudEngine, OLIVAPIClient.engineID, "oliv-trial", "", "future-cloud"] {
            XCTAssertFalse(LivePreview.isEligible(engine: engine), engine)
        }
    }
}

final class LivePreviewTailTests: XCTestCase {
    func testTheBenchGateComparesBytes() {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift calls them equal")
        XCTAssertFalse(LivePreviewBench.sameBytes(composed, decomposed), "the gate doesn't")
        XCTAssertTrue(LivePreviewBench.sameBytes("ส่งไฟล์ deck", "ส่งไฟล์ deck"))
    }

    func testShortTextIsShownWhole() {
        XCTAssertEqual(LivePreview.tail("  สวัสดีครับ deploy  "), "สวัสดีครับ deploy")
        XCTAssertEqual(LivePreview.tail("one\ntwo"), "one two")
    }

    func testLongTextKeepsTheNewestWords() {
        let text = (1...40).map { "word\($0)" }.joined(separator: " ")
        let tail = LivePreview.tail(text, limit: 30)
        XCTAssertTrue(tail.hasPrefix("…"), tail)
        XCTAssertTrue(tail.hasSuffix("word39 word40"), tail)
        XCTAssertLessThanOrEqual(tail.count, 30)
        // Starts on a word, not mid-word.
        XCTAssertTrue(text.contains(" " + tail.dropFirst()), tail)
    }

    func testThaiMarksNeverLoseTheirConsonant() {
        // Every cluster carries marks above and below the line.
        let thai = String(repeating: "กี่ญั้ฤๅปุ่ ", count: 30) + "ล่าสุด"
        for limit in 5...40 {
            let tail = LivePreview.tail(thai, limit: limit)
            XCTAssertTrue(tail.hasSuffix("ล่าสุด"), tail)
            XCTAssertLessThanOrEqual(tail.count, limit)
            let first = tail.dropFirst().unicodeScalars.first!
            // A combining mark (Mn) at the cut would render detached.
            XCTAssertNotEqual(first.properties.generalCategory, .nonspacingMark, "limit \(limit): \(tail)")
            XCTAssertTrue(thai.unicodeScalars.map(String.init).joined().hasSuffix(
                tail.dropFirst().unicodeScalars.map(String.init).joined()))
        }
    }

    @MainActor
    func testPillGrowsOnlyForRecordingWithText() {
        let model = HUDModel()
        model.phase = .recording
        XCTAssertFalse(model.showsPreview)
        model.previewText = "…words"
        XCTAssertTrue(model.showsPreview)
        model.phase = .processing
        XCTAssertFalse(model.showsPreview)
    }
}

/// Hooks for one session, all observable from the test.
private final class FakePreview: @unchecked Sendable {
    let lock = NSLock()
    var events: [String] = []
    var blockUntilCancelled = false
    let release = DispatchSemaphore(value: 0)
    var text = "preview words"
    /// When set, previews return these texts in turn (then `text`).
    var texts: [String] = []
    /// When set, every preview comes back without text for this reason…
    var skipped: String?
    /// …after this long "decoding".
    var delay: TimeInterval = 0

    func log(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return events }

    func hooks(shownLine: @escaping (LivePreviewLine) -> Void = { _ in }) -> LivePreviewSession.Hooks {
        .init(latestSamples: { buffer in
            let total = 48_000   // 3 s so far
            let count = min(buffer.count, total)
            for i in 0..<count { buffer[i] = 0.1 }
            return (count, total)
        }, transcribe: { [self] _, seq in
            log("transcribe \(seq)")
            if blockUntilCancelled {
                _ = release.wait(timeout: .now() + 10)
                log("returned \(seq)")
                return LivePreviewResult(text: "", skipped: "cancelled")
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lock.lock()
            let next = texts.isEmpty ? text : texts.removeFirst()
            lock.unlock()
            return LivePreviewResult(text: skipped == nil ? next : "", skipped: skipped)
        }, cancel: { [self] seq in
            log("cancel \(seq)")
            release.signal()
        }, show: { _, line in shownLine(line) })
    }

    func hooks(shown: @escaping (String) -> Void) -> LivePreviewSession.Hooks {
        hooks(shownLine: { shown($0.text) })
    }
}

final class LivePreviewSessionTests: XCTestCase {
    private func pacer(_ change: (inout LivePreviewGovernor.Policy) -> Void = { _ in }) -> LivePreviewPacer {
        var policy = LivePreviewGovernor.Policy()
        policy.minInterval = 0
        policy.minAudio = 0
        policy.minNewAudio = 0
        change(&policy)
        return LivePreviewPacer(policy: policy)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testDecodesWithoutTextStillPaceAndCanTurnPreviewsOff() {
        // A decode whose text was a known hallucination cost the GPU as much
        // as one with text.
        let fake = FakePreview()
        fake.skipped = "noSpeech"
        fake.delay = 0.06
        let pacer = pacer { $0.maxInterval = 0.1; $0.maxBusyFraction = 0.3 }   // slow: over 0.03 s
        let session = LivePreviewSession(pacer: pacer, hooks: fake.hooks(), tick: 0.01, windowSamples: 16_000)
        session.start()
        waitUntil { !pacer.isEnabled }
        session.stop()
        XCTAssertFalse(pacer.isEnabled, "decodes without text never paced previews: \(fake.log.count) ran")
        XCTAssertEqual(pacer.interval, 0.1, accuracy: 1e-9)
        // The warm-up, then two slow in a row.
        XCTAssertEqual(fake.log.filter { $0.hasPrefix("transcribe") }.count, 3, "\(fake.log.suffix(5))")
        let stats = session.currentStats
        XCTAssertEqual(stats.skipped, ["noSpeech": 3])
        XCTAssertEqual(stats.previewSeconds.count, 3)
        XCTAssertEqual(stats.shown, 0)
    }

    func testFailedDecodesTurnPreviewsOff() {
        let fake = FakePreview()
        fake.skipped = "failed"
        let pacer = pacer()
        let session = LivePreviewSession(pacer: pacer, hooks: fake.hooks(), tick: 0.01, windowSamples: 16_000)
        session.start()
        waitUntil { !pacer.isEnabled }
        session.stop()
        XCTAssertFalse(pacer.isEnabled, "failed decodes never counted as failures: \(fake.log.count) ran")
        XCTAssertEqual(fake.log.filter { $0.hasPrefix("transcribe") }.count, 2, "\(fake.log.suffix(5))")
        XCTAssertEqual(session.currentStats.skipped, ["failed": 2])
    }

    func testPreviewsSkippedBeforeDecodingLeaveThePacingAlone() {
        for reason in ["silent", "notLoaded", "cancelled"] {
            let fake = FakePreview()
            fake.skipped = reason
            let pacer = pacer()
            pacer.record(seconds: 0.6)      // backed off to 0.8 s apart
            pacer.recordFailure()           // one failure so far
            let session = LivePreviewSession(pacer: pacer, hooks: fake.hooks(), tick: 0.01, windowSamples: 16_000)
            session.start()
            waitUntil { session.currentStats.skipped[reason] == 1 }
            session.stop()
            XCTAssertEqual(session.currentStats.skipped, [reason: 1])
            XCTAssertEqual(session.currentStats.previewSeconds, [], reason)
            XCTAssertEqual(pacer.interval, 0.8, accuracy: 1e-9, reason)
            // Nor did it reset the failure streak.
            pacer.recordFailure()
            XCTAssertFalse(pacer.isEnabled, reason)
        }
    }

    func testOnlyOnePreviewRunsAndTicksMeanwhileAreSkipped() {
        let fake = FakePreview()
        fake.blockUntilCancelled = true
        let session = LivePreviewSession(pacer: pacer(), hooks: fake.hooks(), tick: 0.01, windowSamples: 16_000)
        session.start()
        Thread.sleep(forTimeInterval: 0.3)
        let stats = session.currentStats
        XCTAssertEqual(stats.started, 1)
        XCTAssertGreaterThan(stats.skippedBusy, 3)
        XCTAssertEqual(fake.log.filter { $0.hasPrefix("transcribe") }.count, 1)
        session.stop()
    }

    func testReleaseCancelsThePreviewInFlightWithoutWaitingAndShowsNothingAfter() {
        let fake = FakePreview()
        fake.blockUntilCancelled = true
        let shown = expectation(description: "nothing shown after release")
        shown.isInverted = true
        let session = LivePreviewSession(pacer: pacer(), hooks: fake.hooks(shown: { _ in shown.fulfill() }),
                                         tick: 0.01, windowSamples: 16_000)
        session.start()
        let deadline = Date().addingTimeInterval(5)
        while !fake.log.contains(where: { $0.hasPrefix("transcribe") }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let seq = Int(fake.log.first!.split(separator: " ")[1])!
        let start = Date()
        session.stop()
        // stop() never waits for the model; the cancel is already out.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(fake.log.contains("cancel \(seq)"), "\(fake.log)")
        wait(for: [shown], timeout: 0.5)
        let finished = Date().addingTimeInterval(5)
        while session.currentStats.releaseWait == nil && Date() < finished { Thread.sleep(forTimeInterval: 0.01) }
        let stats = session.currentStats
        XCTAssertTrue(stats.inFlightAtStop)
        XCTAssertNotNil(stats.releaseWait)
        XCTAssertEqual(stats.shown, 0)
    }

    func testTextIsShownWhileHeld() {
        let fake = FakePreview()
        let shown = expectation(description: "preview shown")
        shown.assertForOverFulfill = false
        let session = LivePreviewSession(pacer: pacer(), hooks: fake.hooks(shown: { text in
            XCTAssertEqual(text, "preview words")
            shown.fulfill()
        }), tick: 0.01, windowSamples: 16_000)
        session.start()
        wait(for: [shown], timeout: 5)
        session.stop()
        XCTAssertGreaterThan(session.currentStats.shown, 0)
    }

    func testTheWordsTwoPreviewsAgreeOnAreShownSettled() {
        let fake = FakePreview()
        fake.texts = ["ช่วย deploy", "ช่วย deploy เวอร์ชันใหม่"]
        fake.text = "ช่วย deploy เวอร์ชันใหม่"
        let lines = Recorder<LivePreviewLine>()
        let session = LivePreviewSession(pacer: pacer(), hooks: fake.hooks(shownLine: { lines.append($0) }),
                                         tick: 0.01, windowSamples: 16_000)
        session.start()
        waitUntil { lines.all.count >= 3 }
        session.stop()
        let shown = lines.all
        XCTAssertEqual(shown[0], LivePreviewLine(settled: "", tentative: "ช่วย deploy"), "nothing to agree with yet")
        XCTAssertEqual(shown[1], LivePreviewLine(settled: "ช่วย deploy", tentative: " เวอร์ชันใหม่"))
        XCTAssertEqual(shown[2], LivePreviewLine(settled: "ช่วย deploy เวอร์ชันใหม่", tentative: ""))
        XCTAssertEqual(session.currentStats.shownAt.count, session.currentStats.shown)
        XCTAssertEqual(session.currentStats.shownAt, session.currentStats.shownAt.sorted())
    }

    func testAnOffPacerNeverStartsAPreview() {
        let fake = FakePreview()
        let pacer = pacer()
        pacer.recordFailure(); pacer.recordFailure()
        XCTAssertFalse(pacer.isEnabled)
        let session = LivePreviewSession(pacer: pacer, hooks: fake.hooks(), tick: 0.01, windowSamples: 16_000)
        session.start()
        Thread.sleep(forTimeInterval: 0.2)
        session.stop()
        XCTAssertEqual(fake.log, [])
    }
}

/// Thread-safe list for events recorded from the controller's worker threads.
private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

@MainActor
final class LivePreviewControllerTests: XCTestCase {
    private func makeController(engine: String = SidecarClient.defaultEngine,
                                pasted: @escaping (String?) -> Void) -> (DictationController, AppState, NSPasteboard) {
        let worker = CaptureWorker(start: { _, _ in }, stop: {
            CapturedAudio(samples: [Float](repeating: 0.1, count: 32_000), stats: nil)
        }, close: {}, isDeviceLive: { true }, latestSamples: { buffer in
            let total = 32_000
            let count = min(buffer.count, total)
            for i in 0..<count { buffer[i] = 0.1 }
            return (count, total)
        })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.oliv.test.\(UUID().uuidString)"))
        let injector = TextInjector(pasteboard: pasteboard)
        injector.postAccessCheck = { true }
        injector.secureInputCheck = { false }
        injector.cmdVPoster = { pasted(pasteboard.string(forType: .string)); return true }
        let state = AppState()
        let controller = DictationController(appState: state, injector: injector, captureWorker: worker)
        controller.sttEngine = engine
        controller.livePreview = true
        controller.showHUD = true
        return (controller, state, pasteboard)
    }

    func testPreviewIsShownButOnlyTheFinalPassIsPasted() async {
        let pastes = Recorder<String?>()
        let (controller, state, pasteboard) = makeController { pastes.append($0) }
        defer { pasteboard.releaseGlobally() }
        let shown = expectation(description: "preview reached the HUD")
        shown.assertForOverFulfill = false
        controller.previewTranscriber = { _, _, _ in LivePreviewResult(text: "PREVIEW ONLY", skipped: nil) }
        controller.previewCanceller = { _ in }
        controller.previewObserver = { text in
            XCTAssertEqual(text, "PREVIEW ONLY")
            shown.fulfill()
        }
        controller.transcriber = { _ in "final words" }
        let idle = expectation(description: "release finished")
        let observation = state.$status.dropFirst().sink { if $0 == .idle { idle.fulfill() } }

        controller.handlePress()
        await fulfillment(of: [shown], timeout: 5)
        controller.handleRelease()
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(pastes.all, ["final words"])
        XCTAssertEqual(state.transcripts.entries.map(\.text), ["final words"])
        withExtendedLifetime(observation) {}
    }

    func testReleaseCancelsThePreviewBeforeTheFinalPassRuns() async {
        let events = Recorder<String>()
        let log = events.append
        let (controller, state, pasteboard) = makeController { _ in }
        defer { pasteboard.releaseGlobally() }
        let inFlight = expectation(description: "a preview is decoding")
        let release = DispatchSemaphore(value: 0)
        controller.previewTranscriber = { _, _, seq in
            log("preview \(seq)")
            inFlight.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return LivePreviewResult(text: "", skipped: "cancelled")
        }
        controller.previewCanceller = { seq in log("cancel \(seq)"); release.signal() }
        controller.transcriber = { _ in log("final"); return "final words" }
        let idle = expectation(description: "release finished")
        let observation = state.$status.dropFirst().sink { if $0 == .idle { idle.fulfill() } }

        controller.handlePress()
        await fulfillment(of: [inFlight], timeout: 5)
        controller.handleRelease()
        await fulfillment(of: [idle], timeout: 5)
        let seen = events.all
        XCTAssertEqual(seen.count, 3, "\(seen)")
        XCTAssertEqual(seen.first, "preview 1")
        XCTAssertEqual(Array(seen.dropFirst()), ["cancel 1", "final"])
        withExtendedLifetime(observation) {}
    }

    func testCloudEnginesAndTheOffSwitchNeverPreview() async {
        for (engine, enabled, hud) in [(OLIVAPIClient.engineID, true, true), (SidecarClient.cloudEngine, true, true),
                                       ("oliv-trial", true, true), (SidecarClient.defaultEngine, false, true),
                                       (SidecarClient.defaultEngine, true, false)] {
            let (controller, _, pasteboard) = makeController(engine: engine) { _ in }
            controller.livePreview = enabled
            controller.showHUD = hud
            controller.previewTranscriber = { _, _, _ in
                XCTFail("\(engine) previewed (setting \(enabled), HUD \(hud))")
                return LivePreviewResult(text: "", skipped: nil)
            }
            controller.handlePress()
            try? await Task.sleep(nanoseconds: 700_000_000)   // past the first-preview point
            controller.stop()
            pasteboard.releaseGlobally()
        }
    }
}

/// The real sidecar, with a stand-in model helper that "decodes" a preview
/// until it is cancelled: release must not wait for that decode.
final class LivePreviewSidecarTests: XCTestCase {
    private static let slowHelper = #"""
    #!/bin/bash
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      case "$line" in
        *'"cmd":"cancel_preview"'*) ;;
        *'"preview_seq"'*)
          : > "$(dirname "$0")/decoding"
          if IFS= read -r -t 20 next && [[ "$next" == *cancel_preview* ]]; then
            printf '{"id":%s,"ok":true,"text":"","skipped":"cancelled"}\n' "$id"
          else
            printf '{"id":%s,"ok":true,"text":"finished anyway"}\n' "$id"
          fi ;;
        *'"cmd":"stt"'*) printf '{"id":%s,"ok":true,"text":"final words","avg_logprob":-0.1}\n' "$id" ;;
        *) printf '{"id":%s,"ok":false}\n' "$id" ;;
      esac
    done
    """#

    func testCancelReachesTheSidecarWhileAPreviewHoldsTheRequestQueue() throws {
        let sidecar = try NativeTestSupport.sidecar()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oliv-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("helper.sh")
        try Self.slowHelper.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let client = SidecarClient(command: [sidecar], environment: ["OLIV_INFERENCE_EXECUTABLE": helper.path])
        defer { client.close() }
        let speech = (0..<16_000).map { $0 % 2 == 0 ? Float(0.1) : -0.1 }

        let previewed = expectation(description: "preview returned")
        var preview: LivePreviewResult?
        DispatchQueue.global().async {
            preview = try? client.preview(samples: speech, engine: SidecarClient.defaultEngine, seq: 41)
            previewed.fulfill()
        }
        let marker = dir.appendingPathComponent("decoding")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the helper never started the preview")

        let released = Date()
        client.cancelPreviews(through: 41)
        let final = try client.dictate(samples: speech, cleanup: false)
        XCTAssertLessThan(Date().timeIntervalSince(released), 5)
        XCTAssertEqual(final.final, "final words")
        wait(for: [previewed], timeout: 5)
        XCTAssertEqual(preview, LivePreviewResult(text: "", skipped: "cancelled"))
    }

    func testCloudEnginesAreRefusedBySidecar() throws {
        let client = SidecarClient(command: [try NativeTestSupport.sidecar()],
                                   environment: ["OLIV_INFERENCE_EXECUTABLE": "/nonexistent"])
        defer { client.close() }
        // Refused by policy before any model (or upload) is involved.
        XCTAssertThrowsError(try client.preview(samples: [Float](repeating: 0.1, count: 16_000),
                                                engine: SidecarClient.cloudEngine, seq: 1))
        XCTAssertTrue(client._isAliveForTests, "a refused preview must not cost the sidecar")
    }
}

/// `OLIV --live-preview-bench` end to end: the real sidecar, with a stand-in
/// model helper whose preview "decodes" until it is cancelled and that logs
/// which previews reached it.
final class LivePreviewBenchTests: XCTestCase {
    private static let helper = #"""
    #!/bin/bash
    dir=$(dirname "$0")
    mode=$(cat "$dir/mode")
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      case "$line" in
        *'"cmd":"cancel_preview"'*)
          printf 'cancel %s\n' "$(printf '%s' "$line" | sed -n 's/.*"through":\([0-9]*\).*/\1/p')" >> "$dir/events" ;;
        *'"preview_seq"'*)
          printf 'preview %s\n' "$(printf '%s' "$line" | sed -n 's/.*"preview_seq":\([0-9]*\).*/\1/p')" >> "$dir/events"
          if IFS= read -r -t 20 next && [[ "$next" == *cancel_preview* ]]; then
            printf 'cancel %s\n' "$(printf '%s' "$next" | sed -n 's/.*"through":\([0-9]*\).*/\1/p')" >> "$dir/events"
            printf '{"id":%s,"ok":true,"text":"","skipped":"cancelled"}\n' "$id"
          else
            printf '{"id":%s,"ok":true,"text":"finished anyway"}\n' "$id"
          fi ;;
        *'"cmd":"stt"'*)
          n=$(( $(cat "$dir/finals" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$dir/finals"
          case "$mode" in
            fail) printf '{"id":%s,"ok":false}\n' "$id" ;;
            differ) printf '{"id":%s,"ok":true,"text":"final words %s","avg_logprob":-0.1}\n' "$id" "$n" ;;
            *) printf '{"id":%s,"ok":true,"text":"final words","avg_logprob":-0.1}\n' "$id" ;;
          esac ;;
        *'"cmd":"generate"'*) printf '{"id":%s,"ok":false}\n' "$id" ;;
        *) printf '{"id":%s,"ok":true}\n' "$id" ;;
      esac
    done
    """#

    /// One clip of `seconds`, and a helper in `mode`: "ok" (the same final
    /// every time), "differ" (a new final every time) or "fail" (no final).
    private struct Fixture {
        let dir: URL
        let launch: SidecarClient.Launch
        var args: [String] {
            ["--live-preview-bench", "--manifest", dir.appendingPathComponent("manifest.jsonl").path,
             "--audio-root", dir.path, "--gap", "0", "--out", dir.appendingPathComponent("out.json").path]
        }

        init(mode: String, seconds: Double) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("oliv-bench-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let helper = dir.appendingPathComponent("helper.sh")
            try LivePreviewBenchTests.helper.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            try mode.write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            try #"{"id":"clip","path":"clip.wav"}"#.write(to: dir.appendingPathComponent("manifest.jsonl"),
                                                          atomically: true, encoding: .utf8)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LivePreview.sampleRate,
                                       channels: 1, interleaved: false)!
            let count = Int(seconds * LivePreview.sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = i % 2 == 0 ? 0.1 : -0.1 }
            let file = try AVAudioFile(forWriting: dir.appendingPathComponent("clip.wav"), settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            launch = SidecarClient.Launch(command: [try NativeTestSupport.sidecar()],
                                          environment: ["OLIV_INFERENCE_EXECUTABLE": helper.path],
                                          root: dir.path, bundled: false)
        }

        func summary() throws -> [String: Any] {
            let data = try Data(contentsOf: dir.appendingPathComponent("out.json"))
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return report?["summary"] as? [String: Any] ?? [:]
        }

        var events: [String] {
            let text = (try? String(contentsOf: dir.appendingPathComponent("events"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
    }

    func testWarmUpAndMeasuredPacersNumberPreviewsInOneSequence() {
        let (warmUp, measured) = LivePreviewBench.pacers(policy: .init())
        let warm = (0..<3).map { _ in warmUp.nextSeq() }
        XCTAssertGreaterThan(measured.nextSeq(), warm.max()!)
        // Separate governors: the warm-up never paces what is measured.
        warmUp.recordFailure(); warmUp.recordFailure()
        XCTAssertFalse(warmUp.isEnabled)
        XCTAssertTrue(measured.isEnabled)
    }

    func testMeasuredPreviewsStillRunAfterTheWarmUpReleaseCancelledOne() throws {
        // 2 s: each hold starts one preview after 1 s of audio, and the
        // helper holds it until the release cancels it.
        let bench = try Fixture(mode: "ok", seconds: 2)
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        XCTAssertEqual(LivePreviewBench.run(args: bench.args, launch: bench.launch), 0)
        // The warm-up's preview 1 was cancelled at its release; the measured
        // hold's preview must reach the model rather than be skipped as
        // already cancelled.
        XCTAssertEqual(bench.events, ["preview 1", "cancel 1", "preview 2", "cancel 2"])
        let summary = try bench.summary()
        XCTAssertNil((summary["skipped"] as? [String: Int])?["cancelled"], "\(summary)")
        XCTAssertEqual(summary["previews_started"] as? Int, 1)
        XCTAssertEqual(summary["in_flight_at_release"] as? Int, 1)
        XCTAssertEqual(summary["identical_finals"] as? Int, 1)
    }

    func testFailedClipsAndDifferingFinalsFailTheRun() throws {
        for mode in ["fail", "differ"] {
            let bench = try Fixture(mode: mode, seconds: 0.5)
            defer { try? FileManager.default.removeItem(at: bench.dir) }
            XCTAssertEqual(LivePreviewBench.run(args: bench.args, launch: bench.launch), 1, mode)
            let summary = try bench.summary()
            XCTAssertEqual(summary["failed_clips"] as? Int, mode == "fail" ? 1 : 0, mode)
            XCTAssertEqual(summary["differing_finals"] as? Int, mode == "differ" ? 1 : 0, mode)
        }
    }
}
