import AppKit
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
        XCTAssertEqual(g.decide(now: 10, lastStart: nil, inFlight: false, audioSeconds: 0.5, previewedAudioSeconds: 0), .wait)
        XCTAssertEqual(g.decide(now: 10, lastStart: nil, inFlight: false, audioSeconds: 1.2, previewedAudioSeconds: 0), .start)
        XCTAssertEqual(g.decide(now: 10, lastStart: nil, inFlight: true, audioSeconds: 5, previewedAudioSeconds: 0), .busy)
        // Too soon after the last start, then too little new audio.
        XCTAssertEqual(g.decide(now: 10.5, lastStart: 10, inFlight: false, audioSeconds: 5, previewedAudioSeconds: 2), .wait)
        XCTAssertEqual(g.decide(now: 12, lastStart: 10, inFlight: false, audioSeconds: 2.2, previewedAudioSeconds: 2), .wait)
        XCTAssertEqual(g.decide(now: 12, lastStart: 10, inFlight: false, audioSeconds: 5, previewedAudioSeconds: 2), .start)
    }

    func testIntervalBacksOffWithWhatEachPreviewCosts() {
        var g = governor()
        XCTAssertEqual(g.interval, 1.0)
        g.record(seconds: 0.6)          // keep busy ≤ 30% → 2 s apart
        XCTAssertEqual(g.interval, 2.0, accuracy: 1e-9)
        XCTAssertEqual(g.decide(now: 11.5, lastStart: 10, inFlight: false, audioSeconds: 9, previewedAudioSeconds: 2), .wait)
        XCTAssertEqual(g.decide(now: 12.1, lastStart: 10, inFlight: false, audioSeconds: 9, previewedAudioSeconds: 2), .start)
        g.record(seconds: 0.1)
        XCTAssertEqual(g.interval, 1.0, accuracy: 1e-9)
        XCTAssertFalse(g.isDisabled)
    }

    func testPreviewsThatCantKeepUpTurnOffForTheRun() {
        var g = governor()
        g.record(seconds: 2.0)            // warm-up: paces, never counts
        XCTAssertFalse(g.isDisabled)
        XCTAssertEqual(g.interval, 3.0)   // capped at the slowest cadence
        g.record(seconds: 2.0)            // slow 1
        g.record(seconds: 0.1)            // a fast one resets the streak
        g.record(seconds: 0.85)           // fits 30% of a 3 s cadence: not slow
        g.record(seconds: 1.0)            // slow: needs over 3 s between previews
        XCTAssertFalse(g.isDisabled)
        g.record(seconds: 0.95)           // slow 2 in a row
        XCTAssertTrue(g.isDisabled)
        XCTAssertEqual(g.decide(now: 100, lastStart: nil, inFlight: false, audioSeconds: 9, previewedAudioSeconds: 0), .off)
        g.record(seconds: 0.05)         // never back on within the run
        XCTAssertTrue(g.isDisabled)
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

    func log(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return events }

    func hooks(shown: @escaping (String) -> Void = { _ in }) -> LivePreviewSession.Hooks {
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
            return LivePreviewResult(text: text, skipped: nil)
        }, cancel: { [self] seq in
            log("cancel \(seq)")
            release.signal()
        }, show: { _, text in shown(text) })
    }
}

final class LivePreviewSessionTests: XCTestCase {
    private func pacer() -> LivePreviewPacer {
        var policy = LivePreviewGovernor.Policy()
        policy.minInterval = 0
        policy.minAudio = 0
        policy.minNewAudio = 0
        return LivePreviewPacer(policy: policy)
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
        let session = LivePreviewSession(pacer: pacer(), hooks: fake.hooks { _ in shown.fulfill() },
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
        let session = LivePreviewSession(pacer: pacer(), hooks: fake.hooks { text in
            XCTAssertEqual(text, "preview words")
            shown.fulfill()
        }, tick: 0.01, windowSamples: 16_000)
        session.start()
        wait(for: [shown], timeout: 5)
        session.stop()
        XCTAssertGreaterThan(session.currentStats.shown, 0)
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
