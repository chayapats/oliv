import Combine
import XCTest
@testable import OLIV

@MainActor
final class CaptureWorkerTests: XCTestCase {
    func testReleaseWhileOpeningDoesNotBlockUIOrTranscribeLater() async {
        let entered = expectation(description: "opening on capture worker")
        let closed = expectation(description: "cancelled open is closed")
        let idle = expectation(description: "release completes")
        let finishOpen = DispatchSemaphore(value: 0)
        let worker = CaptureWorker(start: { _, request in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            XCTAssertEqual(finishOpen.wait(timeout: .now() + 3), .success)
            guard request.isHeld else { throw AudioCapture.CaptureError.startCancelled }
            XCTFail("released microphone must not start")
        }, stop: {
            XCTFail("cancelled open must not use a previous recording")
            return CapturedAudio(samples: [1], stats: nil)
        }, close: { closed.fulfill() })
        let state = AppState()
        let controller = DictationController(appState: state, captureWorker: worker)
        controller.transcriber = { _ in XCTFail("cancelled open must not transcribe"); return nil }
        let observation = state.$status.dropFirst().sink { if $0 == .idle { idle.fulfill() } }

        controller.handlePress()
        XCTAssertEqual(state.status, .recording)
        await fulfillment(of: [entered], timeout: 2)
        // We are back on the main actor while the simulated system call is
        // still blocked. The release must be handled without waiting for it.
        controller.handleRelease()
        XCTAssertEqual(state.status, .idle)
        finishOpen.signal()
        await fulfillment(of: [closed, idle], timeout: 2)
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.activeEngineID)
        withExtendedLifetime(observation) {}
    }

    func testCaptureUsesThePressTimeSettingsWhenTheyChangeDuringOpen() async {
        let entered = expectation(description: "open receives frozen settings")
        let finished = expectation(description: "open completes")
        let finishOpen = DispatchSemaphore(value: 0)
        let worker = CaptureWorker(start: { options, _ in
            XCTAssertEqual(options.device, "first-mic")
            XCTAssertFalse(options.echoCancellation)
            XCTAssertFalse(options.duckOtherAudio)
            XCTAssertEqual(options.maxSeconds, OLIVAPIClient.maxCaptureSeconds)
            entered.fulfill()
            XCTAssertEqual(finishOpen.wait(timeout: .now() + 3), .success)
            XCTAssertEqual(options.device, "first-mic")
            finished.fulfill()
        }, stop: { CapturedAudio(samples: [], stats: nil) }, close: {},
           isDeviceLive: { true })
        let controller = DictationController(appState: AppState(), captureWorker: worker)
        controller.micDevice = "first-mic"
        controller.echoCancellation = false
        controller.duckOtherAudio = false
        controller.sttEngine = OLIVAPIClient.engineID
        controller.handlePress()
        await fulfillment(of: [entered], timeout: 2)
        controller.micDevice = "second-mic"
        controller.echoCancellation = true
        controller.duckOtherAudio = true
        finishOpen.signal()
        await fulfillment(of: [finished], timeout: 2)
        controller.stop()
    }

    func testStoppingControllerInvalidatesPendingOpenCompletion() async {
        let entered = expectation(description: "open entered")
        let closed = expectation(description: "shutdown serialized after open")
        let finishOpen = DispatchSemaphore(value: 0)
        let worker = CaptureWorker(start: { _, request in
            entered.fulfill()
            XCTAssertEqual(finishOpen.wait(timeout: .now() + 3), .success)
            XCTAssertFalse(request.isHeld)
            throw AudioCapture.CaptureError.startCancelled
        }, stop: { CapturedAudio(samples: [], stats: nil) }, close: { closed.fulfill() })
        let state = AppState()
        let controller = DictationController(appState: state, captureWorker: worker)
        controller.handlePress()
        await fulfillment(of: [entered], timeout: 2)
        controller.stop()
        XCTAssertEqual(state.status, .idle)
        finishOpen.signal()
        await fulfillment(of: [closed], timeout: 2)
        // Let the already-enqueued main-queue completion run as well.
        await Task.yield()
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.activeEngineID)
    }

    func testQueuedCancelledRequestNeverCallsHardware() async {
        let completion = expectation(description: "cancelled start completion")
        let worker = CaptureWorker(start: { _, _ in XCTFail("must not open") },
                                   stop: { CapturedAudio(samples: [1], stats: nil) }, close: {})
        let request = CaptureStartRequest()
        request.cancel()
        worker.start(options: CaptureOptions(), request: request) { result in
            guard case .failure(AudioCapture.CaptureError.startCancelled) = result else {
                return XCTFail("expected cancelled open")
            }
            completion.fulfill()
        }
        let captured = await worker.stop(request: request)
        await fulfillment(of: [completion], timeout: 2)
        XCTAssertTrue(captured.cancelledBeforeStart)
        XCTAssertTrue(captured.samples.isEmpty)
    }

    func testStartedRecordingIsStoppedOnTheSameWorkerAndRetainsAudio() async {
        let ready = expectation(description: "capture started")
        let worker = CaptureWorker(start: { _, _ in XCTAssertFalse(Thread.isMainThread) }, stop: {
            XCTAssertFalse(Thread.isMainThread)
            var stats = AudioCapture.CaptureStats()
            stats.deviceLive = true
            stats.startupSeconds = 0.083
            return CapturedAudio(samples: [0.25, -0.25], stats: stats)
        }, close: { XCTFail("started capture must take the stop path") })
        let request = CaptureStartRequest()
        worker.start(options: CaptureOptions(), request: request) { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        let captured = await worker.stop(request: request)
        XCTAssertEqual(captured.samples, [0.25, -0.25])
        XCTAssertEqual(captured.stats?.startupSeconds, 0.083)
        XCTAssertFalse(captured.cancelledBeforeStart)
    }

    func testRealOpenFailureIsNotReportedAsAnIntentionalQuickTap() async {
        let ready = expectation(description: "failed open")
        let worker = CaptureWorker(start: { _, _ in throw AudioCapture.CaptureError.noInputDevice },
                                   stop: { CapturedAudio(samples: [], stats: nil) }, close: {})
        let request = CaptureStartRequest()
        worker.start(options: CaptureOptions(), request: request) { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        let captured = await worker.stop(request: request)
        XCTAssertFalse(captured.cancelledBeforeStart)
    }

    func testQuitRestoresOutputEvenWhileHardwareOpenIsBlocked() async {
        let entered = expectation(description: "blocked open")
        let restored = expectation(description: "immediate output restore")
        let closed = expectation(description: "close after open")
        let finishOpen = DispatchSemaphore(value: 0)
        let worker = CaptureWorker(start: { _, request in
            entered.fulfill()
            XCTAssertEqual(finishOpen.wait(timeout: .now() + 3), .success)
            XCTAssertFalse(request.isHeld)
            throw AudioCapture.CaptureError.startCancelled
        }, stop: { CapturedAudio(samples: [], stats: nil) }, close: { closed.fulfill() },
           restoreOutput: { restored.fulfill() })
        let request = CaptureStartRequest()
        worker.start(options: CaptureOptions(), request: request) { _ in }
        await fulfillment(of: [entered], timeout: 2)
        worker.shutdown(request: request, immediate: true)
        await fulfillment(of: [restored], timeout: 1)
        finishOpen.signal()
        await fulfillment(of: [closed], timeout: 2)
    }

    func testOffAndOnBetweenRecordingsStillRequestsAECRetry() async {
        let entered = expectation(description: "retry flag")
        let worker = CaptureWorker(start: { options, _ in
            XCTAssertTrue(options.echoCancellation)
            XCTAssertTrue(options.retryVoiceProcessing)
            entered.fulfill()
        }, stop: { CapturedAudio(samples: [], stats: nil) }, close: {},
           isDeviceLive: { true })
        let controller = DictationController(appState: AppState(), captureWorker: worker)
        controller.echoCancellation = false
        controller.echoCancellation = true
        controller.handlePress()
        await fulfillment(of: [entered], timeout: 2)
        controller.stop()
    }

    func testDelayedStopFromAnOldRecordingCannotStopTheNextRecording() async {
        let firstReady = expectation(description: "first start")
        let secondReady = expectation(description: "second start")
        let worker = CaptureWorker(start: { _, _ in }, stop: {
            CapturedAudio(samples: [0.5], stats: nil)
        }, close: {})
        let first = CaptureStartRequest()
        worker.start(options: CaptureOptions(), request: first) { _ in firstReady.fulfill() }
        await fulfillment(of: [firstReady], timeout: 2)
        worker.shutdown(request: first, immediate: false)
        let second = CaptureStartRequest()
        worker.start(options: CaptureOptions(), request: second) { _ in secondReady.fulfill() }
        await fulfillment(of: [secondReady], timeout: 2)
        let stale = await worker.stop(request: first)
        XCTAssertTrue(stale.samples.isEmpty)
        let current = await worker.stop(request: second)
        XCTAssertEqual(current.samples, [0.5])
    }

    func testASecondPressCanQueueWhileTheCancelledFirstOpenFinishes() async {
        let firstEntered = expectation(description: "first open blocked")
        let secondEntered = expectation(description: "second open starts after cancellation")
        let finishFirst = DispatchSemaphore(value: 0)
        var opens = 0 // used only on the capture worker
        let worker = CaptureWorker(start: { _, request in
            opens += 1
            if opens == 1 {
                firstEntered.fulfill()
                XCTAssertEqual(finishFirst.wait(timeout: .now() + 3), .success)
                XCTAssertFalse(request.isHeld)
                throw AudioCapture.CaptureError.startCancelled
            }
            XCTAssertTrue(request.isHeld)
            secondEntered.fulfill()
        }, stop: { CapturedAudio(samples: [], stats: nil) }, close: {},
           isDeviceLive: { true })
        let state = AppState()
        let controller = DictationController(appState: state, captureWorker: worker)
        controller.handlePress()
        await fulfillment(of: [firstEntered], timeout: 2)
        controller.handleRelease()
        XCTAssertEqual(state.status, .idle)
        controller.handlePress()
        XCTAssertEqual(state.status, .recording)
        finishFirst.signal()
        await fulfillment(of: [secondEntered], timeout: 2)
        await Task.yield()
        XCTAssertEqual(state.status, .recording, "old completion must not reset the second press")
        controller.stop()
    }

    func testCancellationClosesAnOpenThatJustSucceeded() async {
        let ready = expectation(description: "hardware has started")
        let closed = expectation(description: "late cancellation closes hardware")
        let worker = CaptureWorker(start: { _, _ in },
                                   stop: { CapturedAudio(samples: [0.5], stats: nil) },
                                   close: { closed.fulfill() })
        let request = CaptureStartRequest()
        worker.start(options: CaptureOptions(), request: request) { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(request.didStart)
        worker.cancelOpening(request: request)
        await fulfillment(of: [closed], timeout: 2)
        let stale = await worker.stop(request: request)
        XCTAssertTrue(stale.samples.isEmpty)
    }
}
