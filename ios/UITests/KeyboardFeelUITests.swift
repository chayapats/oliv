import XCTest

/// Actual extension gestures and host-side edit observations. Only fixed
/// synthetic text is used; these tests never start audio or contact a server.
final class KeyboardFeelUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["OLIV_KEYBOARD_TESTS"] == "1" else {
            throw XCTSkip("Opt in with OLIV_KEYBOARD_TESTS=1 and OLIV already enabled on an isolated device.")
        }
    }

    @MainActor
    func testEnglishHeldDeleteAcceleratesIntoWordsAndReleaseStops() throws {
        try verifyAcceleratedDeletion(language: "english")
    }

    @MainActor
    func testThaiHeldDeleteAcceleratesIntoWordsAndReleaseStops() throws {
        try verifyAcceleratedDeletion(language: "thai")
    }

    @MainActor
    func testBriefDeletePressesRemoveExactlyOneCharacterEach() throws {
        let app = launchReference(language: "english")
        let field = app.textViews["keyboardReferenceField"]
        var expected = try XCTUnwrap(field.value as? String)
        let delete = key("keyboard.backspace", in: app)
        for _ in 0..<4 {
            delete.press(forDuration: 0.06)
            expected.removeLast()
            XCTAssertEqual(field.value as? String, expected)
        }
        assertStable(expected, field: field)
    }

    @MainActor
    func testSlidingDeleteOutsideStopsBeforeTheFingerIsReleased() throws {
        let app = launchReference(language: "english")
        let field = app.textViews["keyboardReferenceField"]
        let original = try XCTUnwrap(field.value as? String)
        let delete = key("keyboard.backspace", in: app)
        let q = key("keyboard.key.71", in: app)
        let outside = coordinate(CGPoint(x: q.frame.midX, y: q.frame.minY - 100), in: app)
        delete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: outside, withVelocity: .fast, thenHoldForDuration: 1.2)
        let returnedAt = ProcessInfo.processInfo.systemUptime
        let after = try XCTUnwrap(field.value as? String)
        XCTAssertNotEqual(after, original)
        assertStable(after, field: field)
        let telemetry = try exportTelemetry(app, name: "OLIV-delete-cancelled-outside")
        let changes = try validateDeletionTrace(telemetry, original: original)
        let last = try XCTUnwrap(changes.last)
        XCTAssertGreaterThan(returnedAt - last.uptime, 0.8,
                             "Delete must stop during the 1.2-second outside hold, not only on finger-up")
        XCTAssertLessThan(original.unicodeScalars.count - after.unicodeScalars.count, 40,
                          "A one-second hold must not continue deleting while the finger is outside")
    }

    @MainActor
    func testCancelledDeleteCannotResumeAfterSwitchingField() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test-host"]
        app.launch()
        let first = app.textViews["keyboardHostFirst"]
        let second = app.textViews["keyboardHostSecond"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        selectOLIV(app, language: "english")
        let seed = String(repeating: "safe words ", count: 8)
        first.typeText(seed)
        XCTAssertEqual(first.value as? String, seed)

        let delete = key("keyboard.backspace", in: app)
        let q = key("keyboard.key.71", in: app)
        delete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8,
                   thenDragTo: coordinate(CGPoint(x: q.frame.midX, y: q.frame.minY - 100), in: app),
                   withVelocity: .fast, thenHoldForDuration: 1)
        let stopped = try XCTUnwrap(first.value as? String)
        XCTAssertTrue(Array(seed.unicodeScalars).starts(with: stopped.unicodeScalars))
        XCTAssertLessThan(stopped.count, seed.count)
        second.tap()
        selectOLIV(app, language: "english")
        key("keyboard.key.71", in: app).tap()
        assertStable("q", field: second)
        XCTAssertEqual(first.value as? String, stopped)
        XCTAssertEqual(app.staticTexts["keyboardFixturePhase"].label, "idle")
    }

    @MainActor
    private func verifyAcceleratedDeletion(language: String) throws {
        let app = launchReference(language: language)
        let field = app.textViews["keyboardReferenceField"]
        let original = try XCTUnwrap(field.value as? String)
        XCTAssertGreaterThan(original.unicodeScalars.count, 400)
        key("keyboard.backspace", in: app).press(forDuration: 4.3)
        let after = try XCTUnwrap(field.value as? String)
        assertStable(after, field: field)
        let telemetry = try exportTelemetry(app, name: "OLIV-" + language + "-held-delete")
        let changes = try validateDeletionTrace(telemetry, original: original)
        let first = try XCTUnwrap(changes.first)
        XCTAssertGreaterThan(changes.count, 1)
        XCTAssertLessThan(changes[1].uptime - first.uptime, 0.32,
                          "The requested quicker initial hold must reach the real host")
        let late = changes.filter { $0.uptime - first.uptime >= 0.85 }
        XCTAssertFalse(late.isEmpty)

        // Observe completed edits, not the view's requested repeat policy.
        // If the proxy returns stale context after deleteBackward(), a guarded
        // word operation can silently degrade to one character; this must fail.
        var previousCount = original.unicodeScalars.count
        var removals: [(time: Double, count: Int)] = []
        for change in changes {
            removals.append((change.uptime, previousCount - change.unicodeScalars))
            previousCount = change.unicodeScalars
        }
        let accelerated = removals.filter { $0.time - first.uptime >= 0.85 }
        let maximumBurst = accelerated.map { beginning in
            accelerated.filter { $0.time >= beginning.time && $0.time - beginning.time <= 0.2 }
                .reduce(0) { $0 + $1.count }
        }.max() ?? 0
        XCTAssertGreaterThanOrEqual(maximumBurst, 5,
                                    "A real accelerated word pulse must remove multiple scalars, not one stale-context deletion")
        let earlyBurst = accelerated.filter { $0.time - first.uptime < 1.25 }
            .reduce(0) { $0 + $1.count }
        XCTAssertGreaterThanOrEqual(earlyBurst, 5, "Words must begin by 1.25 seconds in the real host")
        XCTAssertGreaterThanOrEqual(accelerated.reduce(0) { $0 + $1.count }, 20,
                                    "The completed word phase must delete more than slow character repeats")
        let removed = original.unicodeScalars.count - after.unicodeScalars.count
        XCTAssertLessThan(removed, 150,
                          "A 4.3-second hold on this fixture must not over-delete whole sentences")
        XCTAssertEqual(changes.last?.remainingText, after)
    }

    @MainActor
    private func launchReference(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test-host", "--keyboard-visual-reference",
                               "--reference-telemetry", "--reference-seed", language]
        app.launch()
        let field = app.textViews["keyboardReferenceField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        selectOLIV(app, language: language)
        app.buttons["referencePrepareTelemetry"].tap()
        return app
    }

    @MainActor
    private func selectOLIV(_ app: XCUIApplication, language: String) {
        if !key("keyboard.language", in: app).waitForExistence(timeout: 1) {
            let globe = app.buttons["Next keyboard"]
            XCTAssertTrue(globe.waitForExistence(timeout: 3), "Enable OLIV before this opt-in suite")
            globe.press(forDuration: 1)
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", "OLIV")
            let choice = app.descendants(matching: .any).matching(predicate).firstMatch
            if choice.waitForExistence(timeout: 2) { choice.tap() }
            else {
                let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    .descendants(matching: .any).matching(predicate).firstMatch
                XCTAssertTrue(system.waitForExistence(timeout: 2))
                system.tap()
            }
        }
        let toggle = key("keyboard.language", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Must exercise the actual OLIV extension")
        let isThai = toggle.label == "Switch to English"
        if isThai != (language == "thai") { toggle.tap() }
        let letters = key("keyboard.letters", in: app)
        if letters.exists { letters.tap() }
        let shift = key("keyboard.shift", in: app)
        if let value = shift.value as? String, value != "Off" { shift.tap() }
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
    private func assertStable(_ expected: String, field: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(field.value as? String, expected, file: file, line: line)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", expected), object: field)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.8), .completed,
                       "No repeat may survive release or cancellation", file: file, line: line)
    }

    private struct Telemetry: Decodable {
        let events: [Edit]
        let droppedEvents: Int
    }
    private struct Edit: Decodable {
        let kind: String
        let uptime: Double
        let remainingText: String
        let unicodeScalars: Int
        let utf16: Int
    }

    @MainActor
    private func exportTelemetry(_ app: XCUIApplication, name: String) throws -> Telemetry {
        let button = app.buttons["referenceExportTelemetry"]
        button.tap()
        let json = try XCTUnwrap(button.value as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name + "-telemetry.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let telemetry = try JSONDecoder().decode(Telemetry.self, from: data)
        XCTAssertEqual(telemetry.droppedEvents, 0)
        return telemetry
    }

    private func validateDeletionTrace(_ telemetry: Telemetry, original: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws -> [Edit] {
        let changes = telemetry.events.filter { $0.kind == "changed" }
        XCTAssertFalse(changes.isEmpty, file: file, line: line)
        var previous = Array(original.unicodeScalars)
        for change in changes {
            let next = Array(change.remainingText.unicodeScalars)
            XCTAssertTrue(previous.starts(with: next), "Deletion must preserve the exact remaining scalar prefix",
                          file: file, line: line)
            XCTAssertEqual(change.unicodeScalars, next.count, file: file, line: line)
            XCTAssertEqual(change.utf16, change.remainingText.utf16.count, file: file, line: line)
            previous = next
        }
        return changes
    }
}
