import XCTest
import UIKit

/// Explicit, local visual reference capture. Never grants permissions, enables
/// keyboards, records audio, or contacts OLIV. Run only on a prepared test device.
final class KeyboardVisualReferenceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["OLIV_VISUAL_REFERENCE_TESTS"] == "1" else {
            throw XCTSkip("Opt in with OLIV_VISUAL_REFERENCE_TESTS=1 on an isolated reference device.")
        }
    }

    @MainActor
    func testCaptureCurrentKeyboard() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchHost()
        if let owner = ProcessInfo.processInfo.environment["OLIV_REFERENCE_KEYBOARD"] {
            try selectKeyboard(owner, in: app)
        }
        capture(app, name: "current")
    }

    @MainActor
    func testCaptureAppleEnglishLayers() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchHost()
        try selectKeyboard("English", in: app)
        try captureLayers(app, name: "Apple-English", oliv: false)
    }

    @MainActor
    func testCaptureAppleThaiLayers() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchHost()
        try selectKeyboard("Thai", in: app)
        try captureLayers(app, name: "Apple-Thai", oliv: false)
    }

    @MainActor
    func testCaptureOLIVEnglishAndThaiLayers() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchHost()
        try selectKeyboard("OLIV", in: app)
        let language = element("keyboard.language", in: app)
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        if language.label == "Switch to English" { language.tap() }
        try captureLayers(app, name: "OLIV-English", oliv: true)
        language.tap()
        try captureLayers(app, name: "OLIV-Thai", oliv: true)
    }

    /// The synchronous XCUI press owns the finger. A separate, explicitly
    /// coordinated `simctl io screenshot` can capture it during these 8 seconds.
    /// The before/after attachments do not claim to show a held popup.
    @MainActor
    func testHoldCharacterForExternalScreenshot() throws {
        let app = launchHost()
        try selectKeyboard(ProcessInfo.processInfo.environment["OLIV_REFERENCE_KEYBOARD"] ?? "English", in: app)
        let text = ProcessInfo.processInfo.environment["OLIV_REFERENCE_CHARACTER"] ?? "f"
        let key = try requireKey([text], in: app)
        capture(app, name: "before-hold")
        print("OLIV_VISUAL_REFERENCE_HOLD_BEGIN")
        key.press(forDuration: 8)
        capture(app, name: "after-hold")
    }

    @MainActor
    func testHoldEdgeAndCenterKeysForExternalRecording() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchHost()
        let owner = ProcessInfo.processInfo.environment["OLIV_REFERENCE_KEYBOARD"] ?? "English"
        let thai = ProcessInfo.processInfo.environment["OLIV_REFERENCE_LANGUAGE"] == "thai"
        try selectKeyboard(owner, in: app)
        if owner == "OLIV" {
            let language = element("keyboard.language", in: app)
            if (language.label == "Switch to English") != thai { language.tap() }
            if let letters = existingKey(["keyboard.letters"], in: app) { letters.tap() }
            let shift = element("keyboard.shift", in: app)
            if let value = shift.value as? String, value != "Off" { shift.tap() }
        }
        capture(app, name: "before-feedback-sequence")
        for character in (thai ? ["ๅ", "ิ", "ข"] : ["q", "f", "p"]) {
            let identifiers = [character, "keyboard.key." + String(character.unicodeScalars.first!.value, radix: 16)]
            let key = try requireKey(identifiers, in: app)
            print("OLIV_REFERENCE_PRESS_\(character)_BEGIN")
            key.press(forDuration: 2)
            print("OLIV_REFERENCE_PRESS_\(character)_END")
        }
        capture(app, name: "after-feedback-sequence")
    }

    /// Timing comes from UITextView delegate callbacks in the fixture process.
    /// XCUI gesture markers bound dispatch, not the physical touch-down instant.
    @MainActor
    func testMeasureHeldDelete() throws {
        let owner = ProcessInfo.processInfo.environment["OLIV_REFERENCE_KEYBOARD"] ?? "English"
        let app = launchHost(telemetry: true, seed: owner == "Thai" ? "thai" : "english")
        try selectKeyboard(owner, in: app)
        app.buttons["referencePrepareTelemetry"].tap()
        let field = app.textViews["keyboardReferenceField"]
        let before = (field.value as? String) ?? ""
        XCTAssertGreaterThan(before.count, 200)
        let delete = try requireKey(["keyboard.backspace", "delete", "Delete"], in: app)
        var markers: [[String: Any]] = []
        markers.append(timingMarker("delete-call-begin"))
        print("OLIV_REFERENCE_DELETE_HOLD_BEGIN")
        delete.press(forDuration: 8)
        markers.append(timingMarker("delete-call-returned"))
        let after = (field.value as? String) ?? ""
        XCTAssertLessThan(after.count, before.count)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(field.value as? String, after, "Native deletion must stop after release.")
        markers.append(timingMarker("release-settled"))
        try exportTiming(app, name: owner + "-held-delete", markers: markers)
        capture(app, name: owner + "-after-held-delete")
    }

    /// Deliberately short individual taps and a direct rapid typing burst.
    /// Record the Simulator externally to inspect frame-by-frame key previews.
    @MainActor
    func testMeasureShortTapFeedback() throws {
        let owner = ProcessInfo.processInfo.environment["OLIV_REFERENCE_KEYBOARD"] ?? "English"
        let app = launchHost(telemetry: true)
        try selectKeyboard(owner, in: app)
        if owner == "OLIV" {
            let language = element("keyboard.language", in: app)
            if language.label == "Switch to English" { language.tap() }
            if let letters = existingKey(["keyboard.letters"], in: app) { letters.tap() }
            let shift = element("keyboard.shift", in: app)
            if let value = shift.value as? String, value != "Off" { shift.tap() }
        }
        app.buttons["referencePrepareTelemetry"].tap()
        var markers: [[String: Any]] = []
        for character in ["q", "f", "p"] {
            let identifiers = [character, "keyboard.key." + String(character.unicodeScalars.first!.value, radix: 16)]
            let key = try requireKey(identifiers, in: app)
            markers.append(timingMarker("tap-" + character + "-call-begin"))
            print("OLIV_REFERENCE_SHORT_TAP_\(character)_BEGIN")
            key.press(forDuration: 0.06)
            markers.append(timingMarker("tap-" + character + "-call-returned"))
        }
        markers.append(timingMarker("rapid-type-call-begin"))
        print("OLIV_REFERENCE_RAPID_TYPE_BEGIN")
        app.typeText("qfpqfp")
        markers.append(timingMarker("rapid-type-call-returned"))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(app.textViews["keyboardReferenceField"].value as? String, "qfpqfpqfp")
        try exportTiming(app, name: owner + "-short-taps", markers: markers)
        capture(app, name: owner + "-after-short-taps")
    }

    private func timingMarker(_ name: String) -> [String: Any] {
        ["name": name, "uptime": ProcessInfo.processInfo.systemUptime, "epoch": Date().timeIntervalSince1970]
    }

    @MainActor
    private func exportTiming(_ app: XCUIApplication, name: String, markers: [[String: Any]]) throws {
        let button = app.buttons["referenceExportTelemetry"]
        button.tap()
        let value = try XCTUnwrap(button.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["droppedEvents"] as? Int, 0)
        object["gestureCallMarkers"] = markers
        let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OLIVKeyboardReferences", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + "-timing.json")
        try output.write(to: url, options: .atomic)
        print("OLIV_REFERENCE_TIMING_SAVED \(url.path)")
        let attachment = XCTAttachment(data: output, uniformTypeIdentifier: "public.json")
        attachment.name = name + "-timing.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchHost(telemetry: Bool = false, seed: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test-host", "--keyboard-visual-reference"]
        if telemetry { app.launchArguments.append("--reference-telemetry") }
        if let seed = ProcessInfo.processInfo.environment["OLIV_REFERENCE_SEED"] ?? seed {
            app.launchArguments += ["--reference-seed", seed]
        }
        if ProcessInfo.processInfo.environment["OLIV_REFERENCE_APPEARANCE"] == "dark" {
            app.launchArguments.append("--reference-dark")
        }
        if let hostAppearance = ProcessInfo.processInfo.environment["OLIV_REFERENCE_HOST_APPEARANCE"],
           ["light", "dark"].contains(hostAppearance) {
            app.launchArguments.append("--reference-host-" + hostAppearance)
        }
        if let keyboardAppearance = ProcessInfo.processInfo.environment["OLIV_REFERENCE_KEYBOARD_APPEARANCE"],
           ["light", "dark"].contains(keyboardAppearance) {
            app.launchArguments.append("--reference-keyboard-" + keyboardAppearance)
        }
        if let type = ProcessInfo.processInfo.environment["OLIV_REFERENCE_TYPE"] {
            app.launchArguments += ["--reference-type", type]
        }
        app.launch()
        if ProcessInfo.processInfo.environment["OLIV_REFERENCE_ORIENTATION"] == "landscape" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let field = app.textViews["keyboardReferenceField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists || element("keyboard.surface", in: app).waitForExistence(timeout: 5),
                      "Show the software keyboard on the prepared simulator before capturing references.")
        return app
    }

    @MainActor
    private func captureLayers(_ app: XCUIApplication, name: String, oliv: Bool) throws {
        let letters = oliv ? ["keyboard.letters"] : ["ABC", "กขค", "letters", "Letters", "ตัวอักษร"]
        if let key = existingKey(letters, in: app) { key.tap() }
        let shift = try requireKey(oliv ? ["keyboard.shift"] : ["shift", "Shift"], in: app)
        if oliv, let value = shift.value as? String, value == "On" || value == "Caps Lock" {
            shift.tap()
        }
        capture(app, name: name + "-letters")
        shift.tap()
        capture(app, name: name + "-shift")
        shift.tap()
        try requireKey(oliv ? ["keyboard.numbers"] : ["more", "123", "Numbers"], in: app).tap()
        capture(app, name: name + "-numbers")
        try requireKey(oliv ? ["keyboard.symbols"] : ["#+=", "symbols", "Symbols", "สัญลักษณ์"], in: app).tap()
        capture(app, name: name + "-symbols")
        try requireKey(letters, in: app).tap()
    }

    @MainActor
    private func selectKeyboard(_ name: String, in app: XCUIApplication) throws {
        let isOLIV = element("keyboard.language", in: app).exists
        if name == "OLIV", isOLIV { return }
        if name == "English", !isOLIV, existingKey(["q", "Q"], in: app) != nil { return }
        if name == "Thai", !isOLIV,
           app.keyboards.keys.allElementsBoundByIndex.contains(where: {
               $0.label.unicodeScalars.contains { (0x0E00...0x0E7F).contains(Int($0.value)) }
           }) { return }
        let globe = try requireKey(["keyboard.nextKeyboard", "Next keyboard", "nextKeyboard"], in: app)
        globe.press(forDuration: 1)
        let predicate = name == "Thai"
            ? NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Thai", "ไทย")
            : NSPredicate(format: "label CONTAINS[c] %@", name)
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let choice = owner.descendants(matching: .any).matching(predicate).firstMatch
            if choice.waitForExistence(timeout: 2) { choice.tap(); return }
        }
        capture(app, name: "missing-installed-keyboard-" + name)
        throw XCTSkip("The prepared device must already have the requested keyboard enabled: \(name).")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func existingKey(_ names: [String], in app: XCUIApplication) -> XCUIElement? {
        for name in names {
            let custom = element(name, in: app)
            if custom.exists, custom.isHittable { return custom }
            let native = app.keyboards.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ OR identifier == %@", name, name)).firstMatch
            if native.exists, native.isHittable { return native }
        }
        return nil
    }

    @MainActor
    private func requireKey(_ names: [String], in app: XCUIApplication) throws -> XCUIElement {
        // Switching from an extension to a system keyboard updates the AX tree
        // before the new keyplane finishes becoming hittable.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let key = existingKey(names, in: app) { return key }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        capture(app, name: "unrecognized-control")
        throw XCTSkip("Inspect attached native hierarchy for control labels: \(names.joined(separator: ", ")).")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let appearance = ProcessInfo.processInfo.environment["OLIV_REFERENCE_APPEARANCE"] ?? "light"
        let type = ProcessInfo.processInfo.environment["OLIV_REFERENCE_TYPE"] ?? "default"
        let orientation = ProcessInfo.processInfo.environment["OLIV_REFERENCE_ORIENTATION"] == "landscape" ? "-landscape" : ""
        let hostAppearance = ProcessInfo.processInfo.environment["OLIV_REFERENCE_HOST_APPEARANCE"]
        let keyboardAppearance = ProcessInfo.processInfo.environment["OLIV_REFERENCE_KEYBOARD_APPEARANCE"]
        let independentStyle = hostAppearance != nil || keyboardAppearance != nil
            ? "-host\(hostAppearance ?? appearance)-keyboard\(keyboardAppearance ?? appearance)" : ""
        let tag = "\(name)-\(appearance)-\(type)\(orientation)\(independentStyle)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OLIVKeyboardReferences", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTag = tag.replacingOccurrences(of: "/", with: "_")
        let imageURL = directory.appendingPathComponent(safeTag + ".png")
        try? screenshot.pngRepresentation.write(to: imageURL, options: .atomic)
        print("OLIV_REFERENCE_SAVED \(imageURL.path)")
        let pixels = XCTAttachment(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
        pixels.name = tag + ".png"
        pixels.lifetime = .keepAlways
        add(pixels)

        let native = app.keyboards.descendants(matching: .any).allElementsBoundByIndex
        let custom = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "keyboard.")).allElementsBoundByIndex
        var seen = Set<String>()
        let keys: [[String: Any]] = (native + custom).compactMap { key in
            let frame = key.frame
            let identity = "\(key.elementType.rawValue)|\(key.identifier)|\(key.label)|\(frame)"
            guard seen.insert(identity).inserted else { return nil }
            return ["elementType": key.elementType.rawValue, "identifier": key.identifier,
                    "label": key.label, "value": (key.value as? String) ?? "",
                    "frame": rect(frame), "hittable": key.isHittable]
        }
        let hostPlatformValue = app.staticTexts["referenceConfiguration"].value as? String
        let hostPlatform = hostPlatformValue.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let metadata: [String: Any] = [
            "name": tag, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "requestedHostAppearance": hostAppearance ?? appearance,
            "requestedKeyboardAppearance": keyboardAppearance ?? appearance,
            "hostPlatformAccessibility": hostPlatform ?? ["unavailable": true],
            "pixelWidth": screenshot.image.cgImage?.width ?? 0,
            "pixelHeight": screenshot.image.cgImage?.height ?? 0,
            "applicationFrame": rect(app.frame),
            // Landscape PNGs can retain portrait storage plus EXIF rotation.
            "imageOrientation": screenshot.image.imageOrientation.rawValue,
            "pixelsPerPoint": Double(max(screenshot.image.cgImage?.width ?? 0,
                                          screenshot.image.cgImage?.height ?? 0))
                / max(1, app.frame.width, app.frame.height),
            "keyboardFrames": app.keyboards.allElementsBoundByIndex.map { rect($0.frame) },
            "keys": keys,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: directory.appendingPathComponent(safeTag + "-frames.json"), options: .atomic)
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = tag + "-frames.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let description = app.debugDescription
        try? description.write(to: directory.appendingPathComponent(safeTag + "-hierarchy.txt"), atomically: true, encoding: .utf8)
        let hierarchy = XCTAttachment(string: description)
        hierarchy.name = tag + "-hierarchy.txt"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func rect(_ frame: CGRect) -> [String: Double] {
        ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
}
