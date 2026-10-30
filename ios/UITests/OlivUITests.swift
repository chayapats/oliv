import XCTest

final class OlivUITests: XCTestCase {
    private let finishedText = "พรุ่งนี้ส่ง design ให้ทีม review ตอน 9 โมงนะครับ"
    private let originalText = "เอ่อ พรุ่งนี้ส่ง design ให้ทีม review ตอนเก้าโมงนะครับ"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        return app
    }

    @MainActor
    func testCaptureAndResult() {
        let app = launch()
        attachScreenshot(app, named: "OLIV-capture")
        finishRecording(in: app)
        XCTAssertTrue(app.buttons["copyResultButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["cleanedTranscript"].label, finishedText)

        let versions = app.segmentedControls["transcriptVersionPicker"]
        versions.buttons["Original"].tap()
        XCTAssertEqual(app.staticTexts["rawTranscript"].label, originalText)
        versions.buttons["Finished"].tap()
        tap(app.buttons["copyResultButton"], in: app)
        XCTAssertTrue(app.staticTexts["Copied"].exists)
        attachScreenshot(app, named: "OLIV-result")
    }

    @MainActor
    func testCancelDoesNotCreateResult() {
        let app = launch()
        tap(app.buttons["recordButton"], in: app)
        let cancel = app.buttons["cancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        tap(cancel, in: app)
        XCTAssertTrue(app.buttons["recordButton"].exists)
        XCTAssertFalse(app.buttons["copyResultButton"].exists)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["A fresh page."].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSettingsAndHistoryAreReachable() {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.textFields["serverURLField"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["tokenField"].exists)
        tap(app.buttons["saveSettingsButton"], in: app)
        // Partial visibility can report hittable beneath the persistent Save bar.
        // Use a short drag so revealing this action doesn't overshoot the navigation bar.
        let connection = app.buttons["testConnectionButton"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<4 where connection.frame.maxY >= app.buttons["saveSettingsButton"].frame.minY {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertGreaterThan(connection.frame.minY, app.navigationBars["Settings"].frame.maxY)
        XCTAssertLessThan(connection.frame.maxY, app.buttons["saveSettingsButton"].frame.minY)
        tap(connection, in: app)
        let connected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "API reachable", "not verified")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 5))
        attachScreenshot(app, named: "OLIV-settings")
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["A fresh page."].waitForExistence(timeout: 3))
    }

    @MainActor
    func testNoSpeechDoesNotOfferCopy() {
        let app = launch(["--no-speech"])
        finishRecording(in: app)
        XCTAssertTrue(app.staticTexts["No speech detected."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["copyResultButton"].exists)
        XCTAssertFalse(app.buttons["shareResultButton"].exists)
        XCTAssertTrue(app.buttons["recordButton"].isEnabled)
        attachScreenshot(app, named: "OLIV-no-speech")
    }

    @MainActor
    func testFailedUploadCanRetrySavedRecording() {
        let app = launch(["--fail-once"])
        finishRecording(in: app)
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "retryRecordingButton_")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["copyResultButton"].exists)
        let dismissMessage = app.buttons["dismissMessageButton"]
        if dismissMessage.exists { dismissMessage.tap() }
        tap(retry, in: app)
        XCTAssertTrue(app.buttons["copyResultButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["cleanedTranscript"].label, finishedText)
        XCTAssertFalse(retry.exists)
    }

    @MainActor
    func testExistingTextCanBeCleaned() {
        let app = launch()
        tap(app.buttons["cleanTextButton"], in: app)
        let editor = app.textViews["cleanupTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["submitCleanupButton"].isEnabled)
        editor.tap()
        editor.typeText("  A clear thought from Oliv.  ")
        let keyboardDone = app.buttons["cleanupKeyboardDoneButton"]
        if keyboardDone.waitForExistence(timeout: 2) { keyboardDone.tap() }
        tap(app.buttons["submitCleanupButton"], in: app)
        XCTAssertTrue(app.staticTexts["cleanedTranscript"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["cleanedTranscript"].label, "A clear thought from Oliv.")
        XCTAssertTrue(app.buttons["copyResultButton"].exists)
    }

    @MainActor
    func testHistorySearchAndDelete() {
        let app = launch()
        finishRecording(in: app)
        XCTAssertTrue(app.buttons["copyResultButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyEntry_")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        let query = "nothing-matches-this-query"
        search.typeText(query)
        XCTAssertTrue(app.staticTexts["No matching words."].waitForExistence(timeout: 3))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
        let searchKey = app.keyboards.buttons["Search"]
        if searchKey.exists { searchKey.tap() }
        tap(row, in: app)
        tap(app.buttons["deleteTranscriptButton"], in: app)
        // SwiftUI exposes the action sheet's outer and inner button with the same identifier.
        tap(app.buttons.matching(identifier: "confirmDeleteTranscriptButton").firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["A fresh page."].waitForExistence(timeout: 3))
        XCTAssertFalse(row.exists)
    }

    @MainActor
    func testLargestDynamicTypeKeepsMainActionsReachable() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        attachScreenshot(app, named: "OLIV-accessibility-capture")
        tap(app.buttons["recordButton"], in: app)
        let cancel = app.buttons["cancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        reveal(cancel, in: app)
        XCTAssertTrue(cancel.isHittable)
        tap(app.buttons["recordButton"], in: app)
        XCTAssertTrue(app.buttons["copyResultButton"].waitForExistence(timeout: 5))
        tap(app.buttons["copyResultButton"], in: app)
        reveal(app.buttons["shareResultButton"], in: app)
        XCTAssertTrue(app.buttons["shareResultButton"].isHittable)
        attachScreenshot(app, named: "OLIV-accessibility-result")
        app.tabBars.buttons["Settings"].tap()
        reveal(app.textFields["serverURLField"], in: app)
        XCTAssertTrue(app.textFields["serverURLField"].isHittable)
        XCTAssertTrue(app.buttons["saveSettingsButton"].isHittable)
        attachScreenshot(app, named: "OLIV-accessibility-settings")
        app.tabBars.buttons["History"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyEntry_")).firstMatch
        reveal(row, in: app)
        XCTAssertTrue(row.isHittable)
    }

    @MainActor
    private func finishRecording(in app: XCUIApplication) {
        tap(app.buttons["recordButton"], in: app)
        XCTAssertTrue(app.buttons["cancelButton"].waitForExistence(timeout: 3))
        tap(app.buttons["recordButton"], in: app)
    }

    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        reveal(element, in: app, file: file, line: line)
        if !element.isEnabled {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                           "Action did not become enabled: \(element.identifier)", file: file, line: line)
        }
        XCTAssertTrue(element.isEnabled, "Expected an enabled action: \(element.identifier)", file: file, line: line)
        element.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing element: \(element.identifier)", file: file, line: line)
        for _ in 0..<12 where !element.isHittable {
            if element.frame.maxY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, "Element is not reachable by scrolling: \(element.identifier)", file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
