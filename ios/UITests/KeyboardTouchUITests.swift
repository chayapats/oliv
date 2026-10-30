import XCTest

/// Real UIKit touch delivery through the installed extension. The host uses
/// synthetic audio/server fixtures, and these tests never start capture.
final class KeyboardTouchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["OLIV_KEYBOARD_TESTS"] == "1" else {
            throw XCTSkip("Opt in on an isolated device with OLIV already enabled: OLIV_KEYBOARD_TESTS=1.")
        }
    }

    @MainActor
    func testTapsInVisibleKeyGapInsertNearestCharacterExactlyOnce() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        let q = key("keyboard.key.71", in: app)
        let w = key("keyboard.key.77", in: app)
        let gap = w.frame.minX - q.frame.maxX
        XCTAssertGreaterThan(gap, 0, "This must exercise empty space between the visible keycaps")
        let y = q.frame.midY

        coordinate(CGPoint(x: q.frame.maxX + gap * 0.25, y: y), in: app).tap()
        assertText("q", in: first, diagnostics: app)
        coordinate(CGPoint(x: q.frame.maxX + gap * 0.75, y: y), in: app).tap()
        assertText("qw", in: first, diagnostics: app)
        assertHostStayedIdle(app)
    }

    @MainActor
    func testSlidingToNeighborCommitsOnlyReleaseTarget() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        let q = key("keyboard.key.71", in: app)
        let w = key("keyboard.key.77", in: app)

        // q/w have no alternative-character menu. The gesture represents one
        // uninterrupted finger, with the initial control receiving the release.
        q.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        assertText("w", in: first)
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: q.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        assertText("wq", in: first)
        assertHostStayedIdle(app)
    }

    @MainActor
    func testSlidingAboveKeyboardCancelsAndNextTapStillWorks() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        let q = key("keyboard.key.71", in: app)
        // Leave both the key rows and the preview/header region. No new touch
        // begins in the host, so this must cancel the original key rather than
        // transfer focus to a text field or activate a host control.
        let outside = CGPoint(x: q.frame.midX, y: q.frame.minY - 100)
        XCTAssertGreaterThan(outside.y, app.frame.minY)
        q.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: coordinate(outside, in: app))
        assertText("", in: first)

        key("keyboard.key.77", in: app).tap()
        assertText("w", in: first)
        assertHostStayedIdle(app)
    }

    @MainActor
    func testBothInteriorEdgesOfWideSpaceInsertSpaceWithoutNeighborActions() {
        let app = launchHost()
        let first = app.textViews["keyboardHostFirst"]
        key("keyboard.key.71", in: app).tap()
        let space = key("keyboard.space", in: app)
        XCTAssertGreaterThan(space.frame.width, 80, "Exercise the actual wide Space key")

        // These points are inside visible Space artwork, far from its center.
        // Choosing by center distance incorrectly redirects them to language
        // or Return. Interleave letters so the double-space shortcut is irrelevant.
        coordinate(CGPoint(x: space.frame.minX + 4, y: space.frame.midY), in: app).tap()
        assertText("q ", in: first)
        XCTAssertEqual(key("keyboard.language", in: app).label, "Switch to Thai")
        key("keyboard.key.77", in: app).tap()
        coordinate(CGPoint(x: space.frame.maxX - 4, y: space.frame.midY), in: app).tap()
        assertText("q w ", in: first)
        key("keyboard.key.71", in: app).tap()
        assertText("q w q", in: first)
        XCTAssertEqual(key("keyboard.language", in: app).label, "Switch to Thai")
        assertHostStayedIdle(app)
    }

    @MainActor
    func testSpaceTrackpadMovesUpAndDownWithoutInsertingSpace() {
        let app = launchCursorHost(seed: "cursor-lines")
        let field = app.textViews["keyboardReferenceField"]
        let seed = "qqqqqq\nqqqqqq\nqqqqqq"
        assertText(seed, in: field)
        dragSpace(vertical: -17, in: app)
        key("keyboard.key.71", in: app).tap()
        assertText("qqqqqq\nqqqqqqq\nqqqqqq", in: field)
        dragSpace(vertical: 17, in: app)
        key("keyboard.key.77", in: app).tap()
        assertText("qqqqqq\nqqqqqqq\nqqqqqqw", in: field)
    }

    @MainActor
    func testShortVerticalTrackpadIgnoresMinorSidewaysDrift() {
        let app = launchCursorHost(seed: "cursor-lines")
        let field = app.textViews["keyboardReferenceField"]
        dragSpace(vertical: -17, horizontal: 8, in: app)
        key("keyboard.key.77", in: app).tap()
        assertText("qqqqqq\nqqqqqqw\nqqqqqq", in: field)
        dragSpace(vertical: 17, horizontal: -8, in: app)
        key("keyboard.key.71", in: app).tap()
        assertText("qqqqqq\nqqqqqqw\nqqqqqqq", in: field)
    }

    @MainActor
    func testVerticalTrackpadKeepsEmojiAndThaiGraphemesIntact() {
        let app = launchCursorHost(seed: "cursor-unicode")
        let field = app.textViews["keyboardReferenceField"]
        let seed = "ab👩🏽‍💻กิcd\n123456\nxyzzzz"
        assertText(seed, in: field)
        dragSpace(vertical: -17, in: app)
        dragSpace(vertical: -17, in: app)
        key("keyboard.key.71", in: app).tap()
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.contains("👩🏽‍💻"))
        XCTAssertTrue(value.contains("กิ"))
        XCTAssertEqual(value.replacingOccurrences(of: "q", with: ""), seed)
        XCTAssertTrue(value.components(separatedBy: "\n")[0].contains("q"),
                      "Two upward moves must reach the first line through the real proxy")
    }

    @MainActor
    func testSpaceTrackpadCrossesBlankParagraphWithoutLosingColumn() {
        let app = launchCursorHost(seed: "cursor-blank")
        let field = app.textViews["keyboardReferenceField"]
        dragSpace(vertical: -34, in: app)
        key("keyboard.key.77", in: app).tap()
        assertText("qqqqqqw\n\nqqqqqq", in: field)
        dragSpace(vertical: 34, in: app)
        key("keyboard.key.71", in: app).tap()
        assertText("qqqqqqw\n\nqqqqqqq", in: field)
    }

    @MainActor
    func testSpaceTrackpadStopsAtDocumentEdges() {
        let app = launchCursorHost(seed: "cursor-lines")
        let field = app.textViews["keyboardReferenceField"]
        dragSpace(vertical: -34, in: app)
        dragSpace(vertical: -17, in: app)
        key("keyboard.key.77", in: app).tap()
        assertText("qqqqqqw\nqqqqqq\nqqqqqq", in: field)
        dragSpace(vertical: 34, in: app)
        dragSpace(vertical: 17, in: app)
        key("keyboard.key.71", in: app).tap()
        assertText("qqqqqqw\nqqqqqq\nqqqqqqq", in: field)
    }

    @MainActor
    func testSpaceTrackpadMovesWithinWrappedParagraph() {
        let app = launchCursorHost(seed: "cursor-wrap")
        let field = app.textViews["keyboardReferenceField"]
        let seed = String(repeating: "simple words ", count: 20)
        dragSpace(vertical: -17, in: app)
        key("keyboard.key.71", in: app).tap()
        let text = field.value as? String ?? ""
        XCTAssertEqual(text.replacingOccurrences(of: "q", with: ""), seed)
        let index = text.firstIndex(of: "q")
        XCTAssertNotNil(index)
        if let index {
            let distance = text.distance(from: index, to: text.endIndex)
            XCTAssertGreaterThan(distance, 5, "Up must leave the end of a soft-wrapped paragraph")
            XCTAssertLessThan(distance, 100, "One gesture step must not jump across the whole paragraph")
        }
    }

    @MainActor
    private func launchCursorHost(seed: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test-host", "--keyboard-visual-reference", "--reference-telemetry", "--reference-seed", seed]
        app.launch()
        let field = app.textViews["keyboardReferenceField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if !key("keyboard.language", in: app).waitForExistence(timeout: 1) {
            let globe = app.buttons["Next keyboard"]
            XCTAssertTrue(globe.waitForExistence(timeout: 3)); globe.press(forDuration: 1)
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", "OLIV")
            let choice = app.descendants(matching: .any).matching(predicate).firstMatch
            if choice.waitForExistence(timeout: 2) { choice.tap() }
            else {
                let choice = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    .descendants(matching: .any).matching(predicate).firstMatch
                XCTAssertTrue(choice.waitForExistence(timeout: 2)); choice.tap()
            }
        }
        if key("keyboard.language", in: app).label != "Switch to Thai" { key("keyboard.language", in: app).tap() }
        app.buttons["referencePrepareTelemetry"].tap()
        return app
    }

    @MainActor
    private func dragSpace(vertical: CGFloat, horizontal: CGFloat = 0, in app: XCUIApplication) {
        let space = key("keyboard.space", in: app)
        let start = space.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.45,
                    thenDragTo: coordinate(CGPoint(x: space.frame.midX + horizontal, y: space.frame.midY + vertical), in: app),
                    withVelocity: .slow, thenHoldForDuration: 0.15)
    }

    @MainActor
    private func launchHost() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test-host"]
        app.launch()
        let first = app.textViews["keyboardHostFirst"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        if !key("keyboard.language", in: app).waitForExistence(timeout: 1) {
            let globe = app.buttons["Next keyboard"]
            XCTAssertTrue(globe.waitForExistence(timeout: 3), "Enable OLIV on the test device before running this suite")
            globe.press(forDuration: 1)
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", "OLIV")
            let choice = app.descendants(matching: .any).matching(predicate).firstMatch
            if choice.waitForExistence(timeout: 3) {
                choice.tap()
            } else {
                let systemChoice = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    .descendants(matching: .any).matching(predicate).firstMatch
                XCTAssertTrue(systemChoice.waitForExistence(timeout: 1), "The already enabled OLIV keyboard must be present")
                systemChoice.tap()
            }
        }
        let language = key("keyboard.language", in: app)
        XCTAssertTrue(language.waitForExistence(timeout: 5), "These tests require the actual OLIV extension")
        if language.label == "Switch to English" { language.tap() }
        let letters = key("keyboard.letters", in: app)
        if letters.exists { letters.tap() }
        let shift = key("keyboard.shift", in: app)
        if let state = shift.value as? String, state == "On" || state == "Caps Lock" { shift.tap() }
        XCTAssertTrue(key("keyboard.key.71", in: app).waitForExistence(timeout: 3))
        assertText("", in: first)
        assertHostStayedIdle(app)
        return app
    }

    @MainActor
    private func key(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func coordinate(_ point: CGPoint, in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
    }

    @MainActor
    private func assertHostStayedIdle(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.staticTexts["keyboardFixturePhase"].label, "idle", file: file, line: line)
        assertText("", in: app.textViews["keyboardHostSecond"], file: file, line: line)
    }

    @MainActor
    private func assertText(_ expected: String, in field: XCUIElement, diagnostics app: XCUIApplication? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
        let predicate = expected.isEmpty
            ? NSPredicate(format: "value == %@ OR value == nil", expected)
            : NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: field)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        let originalValue = String(describing: field.value)
        var detail = ""
        if result != .completed, let app {
            let surface = key("keyboard.surface", in: app)
            let q = key("keyboard.key.71", in: app)
            let w = key("keyboard.key.77", in: app)
            detail = "surface=\(surface.exists ? String(describing: surface.value) : "missing"); app=\(app.frame); q=\(q.exists ? String(describing: q.frame) : "missing"); qValue=\(q.exists ? String(describing: q.value) : "missing"); w=\(w.exists ? String(describing: w.frame) : "missing")"
            print("KEYBOARD_TOUCH_DIAGNOSTICS \(detail)")
            let description = XCTAttachment(string: detail + "\n" + (surface.exists ? surface.debugDescription : "No keyboard surface"))
            description.name = "keyboard-touch-diagnostics"
            description.lifetime = .keepAlways
            add(description)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "keyboard-touch-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            if expected == "q", (field.value as? String ?? "").isEmpty, q.exists {
                // A separate element-centered tap is a positive control for
                // the temporary DEBUG counters. The original failed result
                // is retained below; this cannot turn a missed gap into a pass.
                q.tap()
                let after = "surface=\(surface.exists ? String(describing: surface.value) : "missing"); qValue=\(q.exists ? String(describing: q.value) : "missing"); field=\(String(describing: field.value))"
                print("KEYBOARD_TOUCH_POSITIVE_CONTROL \(after)")
                detail += "; positiveControl=\(after)"
                assertText("q", in: field, file: file, line: line)
            }
        }
        XCTAssertEqual(result, .completed,
                       "Expected only \(expected.debugDescription), originally got \(originalValue). \(detail)", file: file, line: line)
    }
}
