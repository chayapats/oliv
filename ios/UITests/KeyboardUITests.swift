import XCTest

/// Opt-in tests of the actual keyboard extension and App Group transport.
/// The host's recorder/server are explicitly synthetic; no real microphone or API token is used.
final class KeyboardUITests: XCTestCase {
    private let finishedText = "พรุ่งนี้ส่ง design ให้ทีม review ตอน 9 โมงนะครับ"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["OLIV_KEYBOARD_TESTS"] == "1" else {
            throw XCTSkip("Use OlivKeyboardValidation with OLIV already enabled and granted Full Access on an isolated test device.")
        }
    }

    @MainActor
    func testEnglishAndThaiKeysInsertThroughActualExtension() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        typeEnglish("hello", in: app)
        key("keyboard.space", in: app).tap()
        assertText("hello ", in: first)
        attachScreenshot(app, name: "OLIV-keyboard-English")

        let language = key("keyboard.language", in: app)
        XCTAssertEqual(language.label, "Switch to Thai")
        language.tap()
        for character in "ไทย" { tapCharacter(String(character), in: app) }
        assertText("hello ไทย", in: first)
        attachScreenshot(app, name: "OLIV-keyboard-Thai")

        // Restore English using OLIV's own language key, not an OS Settings change.
        key("keyboard.language", in: app).tap()
        XCTAssertEqual(app.staticTexts["keyboardFixturePhase"].label, "idle")
    }

    @MainActor
    func testSameFieldReceivesNewDictationExactlyOnce() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        typeEnglish("note", in: app)
        key("keyboard.space", in: app).tap()
        startCapture(in: app)
        finishCapture(in: app)
        let expected = "note " + finishedText
        assertText(expected, in: first)
        assertText("", in: app.textViews["keyboardHostSecond"])
        attachScreenshot(app, name: "OLIV-keyboard-dictation-inserted")

        // Finish while idle/result must not re-publish or re-consume the prior transcript.
        app.buttons["keyboardFixtureFinish"].tap()
        assertPhase("result", in: app)
        assertUnchanged(expected, in: first)
    }

    @MainActor
    func testSyntheticAutomaticFinishInsertsOnceWithoutFinishTap() {
        let app = launchHost(automaticFinish: true)
        let first = app.textViews["keyboardHostFirst"]
        typeEnglish("reply", in: app)
        key("keyboard.space", in: app).tap()

        // One explicit start is the only capture action. The Debug recorder
        // emits synthetic speech/non-speech windows; the actual extension and
        // App Group transport perform insertion into this focused text field.
        app.buttons["keyboardFixtureStart"].tap()
        assertPhase("result", in: app)
        let expected = "reply " + finishedText
        assertText(expected, in: first)
        assertText("", in: app.textViews["keyboardHostSecond"])
        assertUnchanged(expected, in: first)
        assertPhase("result", in: app)
        attachScreenshot(app, name: "OLIV-keyboard-synthetic-automatic-finish")
    }

    @MainActor
    func testChangingFieldDuringCaptureDoesNotInsertIntoEitherField() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        let second = app.textViews["keyboardHostSecond"]
        typeEnglish("first", in: app)
        startCapture(in: app)

        second.tap()
        requireOLIVKeyboard(in: app)
        typeEnglish("second", in: app)
        finishCapture(in: app)

        // The result completed normally, but neither the old nor replacement field receives it.
        assertText("first", in: first)
        assertUnchanged("second", in: second)
        assertText("first", in: first)
        attachScreenshot(app, name: "OLIV-keyboard-changed-field-rejected")
    }

    @MainActor
    func testSwitchingBetweenEmptyFieldsRejectsIdenticalContextDelivery() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        let second = app.textViews["keyboardHostSecond"]
        assertText("", in: first)
        assertText("", in: second)
        startCapture(in: app)

        // Both fields have identical empty context. Only document/focus identity
        // and lifecycle invalidation can reject this change of destination.
        second.tap()
        requireOLIVKeyboard(in: app)
        finishCapture(in: app)
        assertText("", in: first)
        assertText("", in: second)

        let unexpectedInsertions = [first, second].map { field in
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@ AND value != nil", ""), object: field)
            expectation.isInverted = true
            return expectation
        }
        XCTAssertEqual(XCTWaiter.wait(for: unexpectedInsertions, timeout: 1), .completed,
                       "A completed dictation must not insert into either empty field after focus changes")
        attachScreenshot(app, name: "OLIV-keyboard-empty-field-switch-rejected")
    }

    @MainActor
    func testTypingDuringCaptureInvalidatesOriginalContext() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        typeEnglish("before", in: app)
        startCapture(in: app)
        tapCharacter("x", in: app)
        assertText("beforex", in: first)
        finishCapture(in: app)
        assertUnchanged("beforex", in: first)
        assertText("", in: app.textViews["keyboardHostSecond"])
    }

    @MainActor
    func testCancelNeverInsertsAndFinishCannotResurrectCancelledCapture() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        typeEnglish("keep", in: app)
        startCapture(in: app)
        app.buttons["keyboardFixtureCancel"].tap()
        assertPhase("idle", in: app)
        app.buttons["keyboardFixtureFinish"].tap()
        assertPhase("idle", in: app)
        assertUnchanged("keep", in: first)
        assertText("", in: app.textViews["keyboardHostSecond"])
    }

    @MainActor
    private func launchHost(automaticFinish: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test-host"]
        if automaticFinish { app.launchArguments.append("--keyboard-auto-finish-fixture") }
        app.launch()
        let first = app.textViews["keyboardHostFirst"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "The Debug keyboard fixture host must be installed")
        first.tap()
        selectInstalledOLIVKeyboardIfNeeded(in: app)
        requireOLIVKeyboard(in: app)
        useEnglishLetters(in: app)
        assertText("", in: first)
        assertPhase("idle", in: app)
        return app
    }

    @MainActor
    private func selectInstalledOLIVKeyboardIfNeeded(in app: XCUIApplication) {
        // XCUITest can restore an Apple keyboard when it launches the host, even if
        // OLIV was selected manually. Choose the already enabled extension through
        // the same system globe menu a user uses; never change Settings or access.
        if key("keyboard.language", in: app).waitForExistence(timeout: 1) { return }

        let nextKeyboard = app.buttons["Next keyboard"]
        guard nextKeyboard.waitForExistence(timeout: 3) else {
            XCTFail("OLIV is not active and the system keyboard switcher is unavailable. Enable OLIV before running this opt-in suite.\n\(keyboardDiagnostics(app))")
            return
        }
        nextKeyboard.press(forDuration: 1)

        let label = NSPredicate(format: "label CONTAINS[c] %@", "OLIV")
        let installedOLIV = app.descendants(matching: .any)
            .matching(label).firstMatch
        if installedOLIV.waitForExistence(timeout: 3) {
            installedOLIV.tap()
            return
        }
        // The system may host its picker outside the application's accessibility tree.
        let systemOLIV = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any).matching(label).firstMatch
        if systemOLIV.waitForExistence(timeout: 1) {
            systemOLIV.tap()
            return
        }
        attachScreenshot(app, name: "OLIV-keyboard-picker-precondition")
        XCTFail("The system keyboard picker must already contain OLIV. These tests do not enable keyboards or grant Full Access.\n\(keyboardDiagnostics(app))")
    }

    @MainActor
    private func keyboardDiagnostics(_ app: XCUIApplication) -> String {
        "Host:\n\(app.debugDescription)\nSystem:\n\(XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)"
    }

    @MainActor
    private func requireOLIVKeyboard(in app: XCUIApplication) {
        let language = key("keyboard.language", in: app)
        XCTAssertTrue(language.waitForExistence(timeout: 5),
            "Precondition: the actual OLIV extension must be active, with Full Access already granted. These tests never change system keyboard/permission settings.\n\(app.debugDescription)")
    }

    @MainActor
    private func useEnglishLetters(in app: XCUIApplication) {
        let language = key("keyboard.language", in: app)
        if language.label == "Switch to English" { language.tap() }
        let letters = key("keyboard.letters", in: app)
        if letters.exists { letters.tap() }
        let shift = key("keyboard.shift", in: app)
        if let state = shift.value as? String, state == "On" || state == "Caps Lock" { shift.tap() }
        XCTAssertTrue(key(characterID("q"), in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    private func typeEnglish(_ text: String, in app: XCUIApplication) {
        useEnglishLetters(in: app)
        for character in text { tapCharacter(String(character), in: app) }
    }

    @MainActor
    private func tapCharacter(_ text: String, in app: XCUIApplication) {
        let button = key(characterID(text), in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 3), "Missing actual OLIV key: \(text)")
        button.tap()
    }

    private func characterID(_ text: String) -> String {
        "keyboard.key." + text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
    }

    @MainActor
    private func key(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        // .keyboardKey traits may appear as XCUIElementTypeKey rather than Button.
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func startCapture(in app: XCUIApplication) {
        app.buttons["keyboardFixtureStart"].tap()
        assertPhase("recording", in: app)
        requireOLIVKeyboard(in: app)
    }

    @MainActor
    private func finishCapture(in app: XCUIApplication) {
        app.buttons["keyboardFixtureFinish"].tap()
        assertPhase("result", in: app)
    }

    @MainActor
    private func assertPhase(_ expected: String, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let phase = app.staticTexts["keyboardFixturePhase"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected capture phase \(expected), got \(phase.label)", file: file, line: line)
    }

    @MainActor
    private func assertText(_ expected: String, in field: XCUIElement,
                            file: StaticString = #filePath, line: UInt = #line) {
        let predicate = expected.isEmpty
            ? NSPredicate(format: "value == %@ OR value == nil", expected)
            : NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Unexpected text in \(field.identifier): \(field.value ?? "nil")", file: file, line: line)
    }

    @MainActor
    private func assertUnchanged(_ expected: String, in field: XCUIElement,
                                 file: StaticString = #filePath, line: UInt = #line) {
        assertText(expected, in: field, file: file, line: line)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", expected), object: field)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1), .completed,
                       "Text changed after a rejected, canceled or repeated delivery", file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
