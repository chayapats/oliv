import XCTest
@testable import OLIV

final class VoiceProcessingFailuresTests: XCTestCase {
    func testFailedRouteSurvivesRelaunchButDeviceAndOSChangesRetry() {
        let suite = "oliv-test-voice-failures-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = VoiceProcessingFailures.route(inputUID: "mic", outputUID: "speaker", system: "27.2")
        VoiceProcessingFailures(defaults: defaults).remember(route)
        let relaunched = VoiceProcessingFailures(defaults: defaults)
        XCTAssertTrue(relaunched.contains(route))
        for newRoute in [
            VoiceProcessingFailures.route(inputUID: "other-mic", outputUID: "speaker", system: "27.2"),
            VoiceProcessingFailures.route(inputUID: "mic", outputUID: "headphones", system: "27.2"),
            VoiceProcessingFailures.route(inputUID: "mic", outputUID: "speaker", system: "27.3")
        ] { XCTAssertFalse(relaunched.contains(newRoute)) }
        relaunched.reset()
        XCTAssertFalse(VoiceProcessingFailures(defaults: defaults).contains(route))
    }

    func testCancelledAndTransientOpensDoNotDisableAEC() {
        for error in [AudioCapture.CaptureError.startCancelled, .routeChangedWhileOpening] {
            XCTAssertFalse(AudioCapture.shouldDistrustAfterFailedOpen(backend: .voiceProcessing, error: error))
        }
    }

    func testExplicitRetryClearsBothPersistentAndInMemoryFailures() {
        let failures = VoiceProcessingFailures()
        failures.remember("failed-route")
        let audio = AudioCapture(voiceFailures: failures)
        audio.voiceProcessingDistrusted = true
        audio.retryVoiceProcessing()
        XCTAssertFalse(audio.voiceProcessingDistrusted)
        XCTAssertFalse(failures.contains("failed-route"))
    }

    func testCancelledStartDoesNotAccessMicrophoneOrArmCapture() {
        let audio = AudioCapture()
        XCTAssertThrowsError(try audio.start(shouldContinue: { false })) { error in
            guard case AudioCapture.CaptureError.startCancelled = error else {
                return XCTFail("expected cancellation")
            }
        }
        XCTAssertFalse(audio.isRunning)
    }
}
