import XCTest

/// Opt-in, real-extension regression across native and asynchronous WebKit
/// editing hosts. Every recorded string is a fixed local synthetic fixture.
final class KeyboardHostDeletionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["OLIV_KEYBOARD_TESTS"] == "1" else {
            throw XCTSkip("Opt in with OLIV_KEYBOARD_TESTS=1 and OLIV enabled on an isolated device.")
        }
    }

    @MainActor func testTextViewEnglishSustainedWordDeletion() throws {
        try verifyAcceleration(host: "textview", language: "english")
    }
    @MainActor func testTextViewThaiSustainedWordDeletion() throws {
        try verifyAcceleration(host: "textview", language: "thai")
    }
    @MainActor func testTextFieldEnglishSustainedWordDeletion() throws {
        try verifyAcceleration(host: "textfield", language: "english")
    }
    @MainActor func testTextFieldThaiSustainedWordDeletion() throws {
        try verifyAcceleration(host: "textfield", language: "thai")
    }
    @MainActor func testWebTextareaEnglishSustainedWordDeletion() throws {
        try verifyAcceleration(host: "web-textarea", language: "english")
    }
    @MainActor func testWebTextareaThaiSustainedWordDeletion() throws {
        try verifyAcceleration(host: "web-textarea", language: "thai")
    }
    @MainActor func testWebContenteditableEnglishSustainedWordDeletion() throws {
        try verifyAcceleration(host: "web-contenteditable", language: "english")
    }
    @MainActor func testWebContenteditableThaiSustainedWordDeletion() throws {
        try verifyAcceleration(host: "web-contenteditable", language: "thai")
    }
    @MainActor func testTextFieldOutsideCancellationStopsAcknowledgedEdits() throws {
        try verifyOutsideCancellation(host: "textfield", language: "english")
    }
    @MainActor func testWebTextareaOutsideCancellationStopsAcknowledgedEdits() throws {
        try verifyOutsideCancellation(host: "web-textarea", language: "thai")
    }
    @MainActor func testWebContenteditableOutsideCancellationStopsAcknowledgedEdits() throws {
        try verifyOutsideCancellation(host: "web-contenteditable", language: "thai")
    }

    @MainActor func testWordDeletionToEmptyRefreshesShiftAndAutomaticReturn() throws {
        let app = try launch(host: "textview", language: "english", seed: "english-short",
                             minimumScalars: 25,
                             extraArguments: ["--reference-sentence-caps", "--reference-auto-return"])
        let original = try state(in: app).text
        XCTAssertTrue(key("keyboard.return", in: app).isEnabled)
        key("keyboard.backspace", in: app).press(forDuration: 4)
        attachDeleteDiagnostics(in: app, name: "textview-word-delete-to-empty")
        let empty = try state(in: app)
        XCTAssertEqual(empty.text, "")
        try assertStable(empty, in: app)

        // Inspect immediately, before tapping any other host control. Async
        // word completion must refresh these traits without a fresh keypress.
        XCTAssertEqual(key("keyboard.shift", in: app).value as? String, "On")
        XCTAssertFalse(key("keyboard.return", in: app).isEnabled)

        let telemetry = try export(app, name: "textview-word-delete-to-empty")
        let changes = try validate(telemetry, original: original, final: empty)
        let first = try XCTUnwrap(changes.first)
        var previousCount = original.unicodeScalars.count
        let removals = changes.map { edit -> (time: Double, count: Int) in
            defer { previousCount = edit.unicodeScalars }
            return (edit.editTime - first.editTime, previousCount - edit.unicodeScalars)
        }
        // UIKit may acknowledge every issued delete separately. Measure the
        // completed burst instead of assuming coalesced notifications. At the
        // 60 ms character cadence, 200 ms cannot remove five plain seed scalars.
        let wordPhase = removals.filter { $0.time >= 0.85 }
        let maximumBurst = wordPhase.map { beginning in
            wordPhase.filter { $0.time >= beginning.time && $0.time - beginning.time <= 0.2 }
                .reduce(0) { $0 + $1.count }
        }.max() ?? 0
        XCTAssertGreaterThanOrEqual(maximumBurst, 5,
                      "The empty-field transition must follow a completed accelerated word pulse")

        let capitalQ = key("keyboard.key.51", in: app)
        XCTAssertTrue(capitalQ.exists, "Empty sentence-caps field must expose uppercase Q")
        capitalQ.tap()
        let fresh = try waitForState(in: app) { $0.text == "Q" }
        try assertStable(fresh, in: app)
        XCTAssertTrue(key("keyboard.return", in: app).isEnabled)
        XCTAssertEqual(key("keyboard.shift", in: app).value as? String, "Off")
    }

    @MainActor
    private func verifyAcceleration(host: String, language: String) throws {
        let app = try launch(host: host, language: language)
        let original = try state(in: app).text
        XCTAssertGreaterThan(original.unicodeScalars.count, 400)
        key("keyboard.backspace", in: app).press(forDuration: 5.8)
        attachDeleteDiagnostics(in: app, name: host + "-" + language)
        let after = try state(in: app)
        try assertStable(after, in: app)
        let telemetry = try export(app, name: host + "-" + language + "-sustained-delete")
        let changes = try validate(telemetry, original: original, final: after)
        let first = try XCTUnwrap(changes.first)

        // WebKit's completed DOM input timestamps avoid mistaking delayed
        // WKScriptMessage delivery for simultaneous host edits. UIKit uses its
        // editing delegate uptime. The clocks are compared only within a host.
        let firstTime = first.editTime
        var previous = original.unicodeScalars.count
        let removals = changes.map { edit -> (time: Double, count: Int) in
            defer { previous = edit.unicodeScalars }
            return (edit.editTime - firstTime, previous - edit.unicodeScalars)
        }
        for phaseStart in [2.45, 4.2] {
            let phase = removals.filter { $0.time >= phaseStart }
            let largestBurst = phase.map { beginning in
                phase.filter { $0.time >= beginning.time && $0.time - beginning.time <= 0.2 }
                    .reduce(0) { $0 + $1.count }
            }.max() ?? 0
            XCTAssertGreaterThanOrEqual(largestBurst, 5,
                "\(host) must complete a multi-scalar word burst after \(phaseStart)s, including sustained holding")
            XCTAssertGreaterThanOrEqual(phase.reduce(0) { $0 + $1.count }, 20,
                "\(host) must continue accelerated deletion rather than fall back to isolated characters")
        }
        XCTAssertFalse(after.text.isEmpty, "A bounded hold must not wipe this long fixture")
        XCTAssertGreaterThan(changes.last?.editTime ?? 0, firstTime + 4.5,
                             "The host must still acknowledge deletes late in the hold")
    }

    @MainActor
    private func verifyOutsideCancellation(host: String, language: String) throws {
        let app = try launch(host: host, language: language)
        let original = try state(in: app).text
        let outside = app.staticTexts["referenceConfiguration"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        key("keyboard.backspace", in: app).coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: outside, withVelocity: .fast, thenHoldForDuration: 1.2)
        let returnedAt = ProcessInfo.processInfo.systemUptime
        attachDeleteDiagnostics(in: app, name: host + "-" + language + "-cancelled")
        let after = try state(in: app)
        try assertStable(after, in: app)
        let telemetry = try export(app, name: host + "-" + language + "-cancelled-delete")
        let changes = try validate(telemetry, original: original, final: after)
        XCTAssertGreaterThanOrEqual(changes.count, 2,
                                    "Cancellation must stop an active repeat, not pass because only the initial delete worked")
        let last = try XCTUnwrap(changes.last)
        XCTAssertGreaterThan(returnedAt - last.uptime, 0.8,
                             "Host edits must stop during the outside hold, before finger-up")
        XCTAssertLessThan(original.unicodeScalars.count - after.text.unicodeScalars.count, 40)

        // A fresh character edit must not restart an abandoned delete task.
        let beforeFreshInput = after.text
        let character = language == "thai" ? "ๆ" : "q"
        let identifier = language == "thai" ? "keyboard.key.e46" : "keyboard.key.71"
        key(identifier, in: app).tap()
        let fresh = try waitForState(in: app) { $0.text == beforeFreshInput + character }
        try assertStable(fresh, in: app)
    }

    @MainActor
    private func launch(host: String, language: String, seed: String? = nil,
                        minimumScalars: Int = 400, extraArguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test-host", "--keyboard-visual-reference",
            "--reference-multi-host-test", "--reference-host-kind", host,
            "--reference-telemetry", "--reference-seed", seed ?? language] + extraArguments
        app.launch()
        let field = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "keyboardReferenceField", "keyboardReferenceField")
        ).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "The selected local host must expose its real editable field")
        field.tap()
        selectOLIV(app, language: language)
        app.buttons["referencePrepareTelemetry"].tap()
        let ready = try waitForState(in: app) {
            $0.readyGeneration > 0 && $0.text.unicodeScalars.count > minimumScalars
        }
        XCTAssertEqual(ready.hostKind, host)
        XCTAssertEqual(ready.acknowledgements, 0)
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
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The real OLIV extension must be active")
        if (toggle.label == "Switch to English") != (language == "thai") { toggle.tap() }
        let letters = key("keyboard.letters", in: app)
        if letters.exists { letters.tap() }
        let shift = key("keyboard.shift", in: app)
        if let value = shift.value as? String, value != "Off" { shift.tap() }
    }

    private struct State: Decodable {
        let hostKind: String
        let readyGeneration: Int
        let acknowledgements: Int
        let text: String
        let failure: String
    }
    private struct Telemetry: Decodable {
        let events: [Edit]
        let droppedEvents: Int
        let failure: String
    }
    private struct Edit: Decodable {
        let kind: String
        let uptime: Double
        let remainingText: String
        let unicodeScalars: Int
        let utf16: Int
        let browserTimeMS: Double?
        let sequence: Int?
        let inputType: String?
        var editTime: Double { browserTimeMS.map { $0 / 1_000 } ?? uptime }
    }

    @MainActor
    private func key(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func attachDeleteDiagnostics(in app: XCUIApplication, name: String) {
        let surface = key("keyboard.surface", in: app)
        let value = surface.exists ? (surface.value as? String ?? "unavailable: surface has no value")
            : "unavailable: keyboard.surface is absent from accessibility hierarchy"
        let attachment = XCTAttachment(string: value)
        attachment.name = "OLIV-multihost-" + name + "-delete-counters.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func state(in app: XCUIApplication) throws -> State {
        let element = app.staticTexts["referenceHostState"]
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        let json = try XCTUnwrap(element.value as? String)
        let value = try JSONDecoder().decode(State.self, from: Data(json.utf8))
        XCTAssertEqual(value.failure, "")
        return value
    }

    @MainActor
    private func waitForState(in app: XCUIApplication, condition: @escaping (State) -> Bool) throws -> State {
        let element = app.staticTexts["referenceHostState"]
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement, let json = element.value as? String,
                  let state = try? JSONDecoder().decode(State.self, from: Data(json.utf8)) else { return false }
            return !state.failure.isEmpty || condition(state)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5), .completed)
        return try state(in: app)
    }

    @MainActor
    private func assertStable(_ expected: State, in app: XCUIApplication) throws {
        let element = app.staticTexts["referenceHostState"]
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement, let json = element.value as? String,
                  let value = try? JSONDecoder().decode(State.self, from: Data(json.utf8)) else { return true }
            return value.text != expected.text || value.acknowledgements != expected.acknowledgements || !value.failure.isEmpty
        }
        let changed = XCTNSPredicateExpectation(predicate: predicate, object: element)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.8), .completed,
                       "No requested deletion may arrive after release or cancellation")
    }

    @MainActor
    private func export(_ app: XCUIApplication, name: String) throws -> Telemetry {
        let button = app.buttons["referenceExportTelemetry"]
        button.tap()
        let json = try XCTUnwrap(button.value as? String)
        let data = Data(json.utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "OLIV-multihost-" + name + ".json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let value = try JSONDecoder().decode(Telemetry.self, from: data)
        XCTAssertEqual(value.droppedEvents, 0)
        XCTAssertEqual(value.failure, "")
        return value
    }

    private func validate(_ telemetry: Telemetry, original: String, final: State) throws -> [Edit] {
        let changes = telemetry.events.filter { $0.kind == "changed" }
        XCTAssertFalse(changes.isEmpty)
        var previous = Array(original.unicodeScalars)
        var previousTime: Double?
        var previousSequence: Int?
        for change in changes {
            let next = Array(change.remainingText.unicodeScalars)
            XCTAssertTrue(previous.starts(with: next), "Every acknowledged delete must preserve the exact scalar prefix")
            XCTAssertLessThan(next.count, previous.count, "Only an actual host deletion counts as progress")
            XCTAssertEqual(change.unicodeScalars, next.count)
            XCTAssertEqual(change.utf16, change.remainingText.utf16.count)
            if let previousTime { XCTAssertGreaterThanOrEqual(change.editTime, previousTime) }
            if let sequence = change.sequence, let previousSequence { XCTAssertGreaterThan(sequence, previousSequence) }
            if let inputType = change.inputType { XCTAssertTrue(inputType.hasPrefix("delete")) }
            previous = next
            previousTime = change.editTime
            previousSequence = change.sequence
        }
        XCTAssertEqual(changes.last?.remainingText, final.text)
        XCTAssertEqual(changes.count, final.acknowledgements)
        return changes
    }
}
