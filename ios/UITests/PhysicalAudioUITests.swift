import XCTest

/// Explicitly opt-in hardware diagnostic. No API calls, transcripts or user stores.
/// This tests foreground-started audio across Home, not an ActionButton intent.
final class PhysicalAudioUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["OLIV_PHYSICAL_AUDIO_TESTS"] == "1" else {
            throw XCTSkip("Use OlivPhysicalAudioValidation on a microphone-authorized physical iPhone.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("This opt-in test diagnoses hardware background audio. Use a physical iPhone.")
        #endif
    }

    @MainActor
    func testRealCaptureAndClassificationSurviveHomeThenStopWithoutUpload() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test-host", "--real-audio-background-test"]
        app.launch()
        defer {
            app.activate()
            if app.buttons["audioProbeStop"].exists { app.buttons["audioProbeStop"].tap() }
            app.terminate()
        }
        let permission = app.staticTexts["audioProbePermission"]
        XCTAssertTrue(permission.waitForExistence(timeout: 5))
        guard permission.label == "granted" else {
            throw XCTSkip("OLIV must already have microphone permission; this test does not change permissions.")
        }
        app.buttons["audioProbeStart"].tap()
        let phase = app.staticTexts["audioProbePhase"]
        XCTAssertTrue(wait(for: phase, matching: "label == 'recording'", seconds: 2))
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .milliseconds(2_200))
        app.activate()

        let beforeStop = XCTAttachment(screenshot: app.screenshot())
        beforeStop.name = "Physical audio diagnostic after background"
        beforeStop.lifetime = .keepAlways
        add(beforeStop)
        // The independent safety cap may finish while XCTest reactivates the app.
        // That is acceptable if real PCM and classifier work survived background.
        app.buttons["audioProbeStop"].tap()
        XCTAssertTrue(wait(for: phase, matching: "label == 'stopped' OR label == 'failed'", seconds: 2))
        XCTAssertEqual(app.staticTexts["audioProbeFailure"].label, "none")
        XCTAssertEqual(phase.label, "stopped")
        XCTAssertEqual(app.staticTexts["audioProbeBackgroundSeen"].label, "yes")
        XCTAssertGreaterThanOrEqual(number("audioProbeBackgroundWall", in: app), 2)
        XCTAssertGreaterThan(number("audioProbeBackgroundAudio", in: app), 1)
        XCTAssertGreaterThan(number("audioProbeObservations", in: app), 0)
        XCTAssertGreaterThan(number("audioProbeBackgroundObservations", in: app), 0)
        XCTAssertEqual(app.staticTexts["audioProbeResidual"].label, "none")
        let afterStop = XCTAttachment(screenshot: app.screenshot())
        afterStop.name = "Physical audio diagnostic stopped and discarded"
        afterStop.lifetime = .keepAlways
        add(afterStop)
    }

    @MainActor
    private func number(_ identifier: String, in app: XCUIApplication) -> Double {
        Double(app.staticTexts[identifier].label) ?? -1
    }

    @MainActor
    private func wait(for element: XCUIElement, matching format: String, seconds: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)],
                      timeout: seconds) == .completed
    }
}
