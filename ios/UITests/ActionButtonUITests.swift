import XCTest

/// Opt-in hardware test for the real Action button. It needs a physical iPhone
/// whose Action button runs a shortcut containing Toggle OLIV. Results are read
/// from the app's local diagnostics afterwards; the test only drives the button.
final class ActionButtonUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["OLIV_ACTION_BUTTON_TESTS"] == "1" else {
            throw XCTSkip("Use OlivActionButtonValidation on a configured physical iPhone.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("The Action button does not exist in Simulator.")
        #endif
    }

    /// Each press is the same running install: without the process release in
    /// AppModel every press after the first fails. Waits outlast the no-speech
    /// cancel, so a quiet room sends nothing to the server.
    @MainActor
    func testRepeatedStartsFromAnotherApp() throws {
        #if !targetEnvironment(simulator)
        activateHost()
        for gap in [0.0, 0, 0, 0, 0, 5, 5, 5, 5, 5, 30, 30] {
            XCUIDevice.shared.press(.action)
            Thread.sleep(forTimeInterval: 8 + gap)
        }
        #endif
    }

    /// Every press launches a new process.
    @MainActor
    func testStartsAfterTermination() throws {
        #if !targetEnvironment(simulator)
        let oliv = XCUIApplication(bundleIdentifier: "com.chayapat.oliv.ios")
        activateHost()
        for _ in 0..<8 {
            oliv.terminate()
            Thread.sleep(forTimeInterval: 2)
            XCUIDevice.shared.press(.action)
            Thread.sleep(forTimeInterval: 8)
        }
        #endif
    }

    @MainActor
    private func activateHost() {
        if ProcessInfo.processInfo.environment["OLIV_ACTION_FOREGROUND_FIRST"] == "1" {
            let oliv = XCUIApplication(bundleIdentifier: "com.chayapat.oliv.ios")
            oliv.activate()
            XCTAssertTrue(oliv.wait(for: .runningForeground, timeout: 10))
            Thread.sleep(forTimeInterval: 2)
        }
        let host = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        host.activate()
        XCTAssertTrue(host.wait(for: .runningForeground, timeout: 10))
    }
}
