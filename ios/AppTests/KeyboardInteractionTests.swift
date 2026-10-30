import XCTest
import UIKit

@MainActor
final class KeyboardInteractionTests: XCTestCase {
    func testDisabledReturnCannotEmitActionAndBecomesUsableWhenHostEnablesIt() throws {
        let keyboard = hostedKeyboard()
        var actions: [KeyboardAction] = []
        keyboard.onAction = { actions.append($0) }
        keyboard.apply(KeyboardViewState(returnKeyType: .send, returnKeyEnabled: false))
        let button = try key("keyboard.return", in: keyboard)
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled),
                      "Assistive technology must observe the actual disabled state")
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(actions.isEmpty)
        let inactiveColor = button.backgroundColor

        keyboard.apply(KeyboardViewState(returnKeyType: .send, returnKeyEnabled: true))
        XCTAssertTrue(button.isEnabled)
        XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
        XCTAssertNotEqual(button.backgroundColor, inactiveColor)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(actions, [.returnKey])
    }

    func testGapHitRegionsChooseNearestKeyWithoutChangingKeycapFrames() throws {
        let keyboard = hostedKeyboard()
        let q = try key("keyboard.key.71", in: keyboard)
        let w = try key("keyboard.key.77", in: keyboard)
        let original = try keycapFrame(q, in: keyboard)
        let wFrame = try keycapFrame(w, in: keyboard)
        let gap = wFrame.minX - original.maxX
        XCTAssertGreaterThan(gap, 0)
        let nearQ = CGPoint(x: original.maxX + gap * 0.25, y: original.midY)
        let nearW = CGPoint(x: original.maxX + gap * 0.75, y: original.midY)
        XCTAssertTrue(keyboard.hitTest(nearQ, with: nil) === q)
        XCTAssertTrue(keyboard.hitTest(nearW, with: nil) === w)
        XCTAssertTrue(q.point(inside: q.convert(nearQ, from: keyboard), with: nil),
                      "UIControl must also accept its owned gap when starting tracking")
        XCTAssertFalse(w.point(inside: w.convert(nearQ, from: keyboard), with: nil))
        XCTAssertTrue(w.point(inside: w.convert(nearW, from: keyboard), with: nil))
        XCTAssertTrue(q.frame.contains(nearQ), "The actual control must cover the gap, not only override hitTest")
        XCTAssertTrue(w.frame.contains(nearW))
        XCTAssertEqual(try keycapFrame(q, in: keyboard), original)
        XCTAssertNil(keyboard.hitTest(CGPoint(x: -1, y: original.midY), with: nil))
    }

    func testDisabledReturnGapDoesNotRedirectTouchToSpace() throws {
        let keyboard = hostedKeyboard()
        keyboard.apply(KeyboardViewState(returnKeyType: .send, returnKeyEnabled: false))
        keyboard.layoutIfNeeded()
        let space = try key("keyboard.space", in: keyboard)
        let enter = try key("keyboard.return", in: keyboard)
        let enterFrame = try keycapFrame(enter, in: keyboard)
        let point = CGPoint(x: enterFrame.minX - 0.1, y: enterFrame.midY)
        XCTAssertFalse(keyboard.hitTest(point, with: nil) === space,
                       "A disabled Return must not accidentally insert a space")
    }

    func testFloatingPopupKeepsNativeGapAndStaysInsideKeyboardAtBothEdges() throws {
        let containment = CGRect(x: 0, y: 0, width: 393, height: 240)
        for x: CGFloat in [3, 179, 356] {
            let anchor = CGRect(x: x, y: 100, width: 34, height: 44)
            let popup = KeyboardPopupView(text: "a", keyFrame: anchor, containment: containment, style: .init())
            XCTAssertTrue(containment.contains(popup.frame))
            XCTAssertEqual(popup.frame.width, 58.333, accuracy: 0.001)
            XCTAssertEqual(popup.frame.height, 35.667, accuracy: 0.001)
            XCTAssertEqual(anchor.minY - popup.frame.maxY, 3, accuracy: 0.001)
            XCTAssertFalse(popup.frame.intersects(anchor), "Native iOS 27 leaves the pressed key separate")
            XCTAssertFalse(popup.isUserInteractionEnabled)
            XCTAssertFalse(popup.isAccessibilityElement)
            XCTAssertTrue(popup.accessibilityElementsHidden)
            XCTAssertNil(popup.hitTest(CGPoint(x: popup.bounds.midX, y: popup.bounds.midY), with: nil))
            let shape = try XCTUnwrap(popup.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
            let path = try XCTUnwrap(shape.path)
            XCTAssertTrue(path.contains(CGPoint(x: popup.bounds.midX, y: popup.bounds.midY)))
            XCTAssertFalse(path.contains(CGPoint(x: 0, y: 0)), "Preview corners must stay rounded")
            XCTAssertTrue(popup.bounds.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingBoxOfPath))
        }
    }

    func testPopupGlyphRemainsVisibleAboveItsMaterialInLightAndDark() throws {
        for dark in [false, true] {
            let keyboard = hostedKeyboard()
            let popup = KeyboardPopupView(text: "f", keyFrame: CGRect(x: 145, y: 100, width: 33, height: 43),
                                         containment: keyboard.bounds,
                                         style: .init(fill: dark ? UIColor(white: 0.3, alpha: 1) : .white,
                                                      bottomFill: dark ? UIColor(white: 0.36, alpha: 1) : .white,
                                                      foreground: dark ? .white : .black))
            keyboard.addSubview(popup)
            popup.layoutIfNeeded()
            XCTAssertGreaterThan(try renderedInkPixels(popup, interior: popup.bounds.insetBy(dx: 10, dy: 10), dark: dark), 100,
                                 "An opaque popup material must never cover its character label")
        }
    }

    func testCompactPreviewsPreserveEveryGlyphWithoutClipping() throws {
        for language in KeyboardLanguage.allCases {
            var characters = Set<String>()
            for shift: KeyboardShiftState in [.off, .on] {
                for page: KeyboardPage in [.letters, .numbers, .symbols] {
                    let rows = KeyboardLayout.rows(for: .init(language: language, shift: shift), page: page)
                    for key in rows.flatMap(\.keys) {
                        if case .character(let text) = key.kind { characters.insert(text) }
                    }
                }
            }
            for text in characters {
                let popup = KeyboardPopupView(text: text, keyFrame: CGRect(x: 150, y: 110, width: 33, height: 43),
                                              containment: CGRect(x: 0, y: 0, width: 393, height: 240),
                                              style: .init(usesThaiMetrics: language == .thai))
                let label = try XCTUnwrap(popup.subviews.compactMap { $0 as? KeyboardMarkLabel }.first)
                let compact = try renderedInkBounds(label)
                label.frame.size.height = 100
                let spacious = try renderedInkBounds(label)
                XCTAssertEqual(compact.width, spacious.width, accuracy: 0.667, text)
                XCTAssertEqual(compact.height, spacious.height, accuracy: 0.667, text)
                XCTAssertGreaterThan(compact.minY, 0, text)
                XCTAssertLessThan(compact.maxY, popup.bounds.height, text)
            }
        }
    }

    func testWideSpaceOwnsBothInteriorEdgesAndAdjacentGapHalves() throws {
        let keyboard = hostedKeyboard()
        let space = try key("keyboard.space", in: keyboard)
        let visible = try keycapFrame(space, in: keyboard)
        for x in [visible.minX + 1, visible.maxX - 1, visible.minX - 1, visible.maxX + 1] {
            let point = CGPoint(x: x, y: visible.midY)
            XCTAssertTrue(keyboard.hitTest(point, with: nil) === space)
            XCTAssertTrue(space.point(inside: space.convert(point, from: keyboard), with: nil))
        }
    }

    func testFirstRowPopupNeverDrawsIntoHostApplication() {
        let containment = CGRect(x: 0, y: 0, width: 393, height: 240)
        let popup = KeyboardPopupView(text: "่", keyFrame: CGRect(x: 3, y: 5, width: 28, height: 44),
                                      containment: containment, style: .init())
        XCTAssertTrue(containment.contains(popup.frame))
        XCTAssertGreaterThanOrEqual(popup.frame.minY, 0)
        XCTAssertEqual(popup.subviews.compactMap { $0 as? UILabel }.first?.text, "่",
                       "Thai combining marks stay raw; the renderer omits the shaping anchor")
    }

    func testFirstRowPreviewClearsThePressedKeyInBothLanguagesAndOrientations() throws {
        let keyboard = hostedKeyboard()
        for language in KeyboardLanguage.allCases {
            keyboard.apply(KeyboardViewState(language: language))
            for width: CGFloat in [393, 724] {
                keyboard.frame.size = CGSize(width: width, height: keyboard.preferredHeight(for: width))
                keyboard.layoutIfNeeded()
                let identifier = language == .english ? "keyboard.key.71" : "keyboard.key.e45"
                let button = try key(identifier, in: keyboard)
                let cap = try keycapFrame(button, in: keyboard)
                button.sendActions(for: .touchDown)
                let preview = try XCTUnwrap(keyboard.subviews.compactMap { $0 as? KeyboardPopupView }.first)
                XCTAssertTrue(keyboard.bounds.contains(preview.frame))
                XCTAssertEqual(cap.minY - preview.frame.maxY, 3, accuracy: 0.334,
                               "The entire first-row preview must sit above the fingertip's key")
                XCTAssertFalse(preview.frame.intersects(cap))
                let referenceDistance: CGFloat = width > 540
                    ? (language == .english ? 154 : 157) : (language == .english ? 205 : 210)
                XCTAssertEqual(keyboard.bounds.height - cap.minY, referenceDistance, accuracy: 0.334,
                               "Reserving preview room must preserve the key's screen position")
                keyboard.cancelActiveTouches()
            }
        }
    }

    func testPhysicalKeysRequestOneSubtleHapticWithoutReleaseDuplicates() throws {
        let keyboard = hostedKeyboard()
        var events: [KeyboardHapticFeedback.Event] = []
        keyboard.onHapticRequested = { event, intensity in
            XCTAssertGreaterThan(intensity, 0)
            XCTAssertLessThanOrEqual(intensity, 0.6)
            events.append(event)
        }
        let q = try key("keyboard.key.71", in: keyboard)
        q.sendActions(for: .touchDown)
        q.sendActions(for: .touchUpInside)
        let space = try key("keyboard.space", in: keyboard)
        space.sendActions(for: .touchDown)
        space.sendActions(for: .touchUpInside)
        XCTAssertEqual(events, [.keyPress, .keyPress])
        keyboard.cancelActiveTouches()
        XCTAssertEqual(events.count, 2)
    }

    func testDeleteRequestsHostEditBeforeHapticPlayback() throws {
        let keyboard = hostedKeyboard()
        var events: [String] = []
        keyboard.onAction = { if $0 == .backspace { events.append("delete") } }
        keyboard.onHapticRequested = { _, _ in events.append("haptic") }
        let delete = try key("keyboard.backspace", in: keyboard)
        delete.sendActions(for: .touchDown)
        delete.sendActions(for: .touchUpInside)
        XCTAssertEqual(events, ["delete", "haptic"], "Feedback must not delay or duplicate the initial host edit")
    }

    func testDeleteHoldSignalsBoundTheRepeatAndHapticLifetime() async throws {
        let keyboard = hostedKeyboard()
        var holds: [Bool] = []
        var events: [KeyboardHapticFeedback.Event] = []
        keyboard.onDeleteHoldChanged = { holds.append($0) }
        keyboard.onHapticRequested = { event, _ in events.append(event) }
        let delete = try key("keyboard.backspace", in: keyboard)
        delete.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(550))
        delete.sendActions(for: .touchUpInside)
        XCTAssertEqual(holds, [true, false])
        XCTAssertEqual(events.first, .keyPress)
        XCTAssertTrue(events.contains(.deleteRepeat))
        let count = events.count
        keyboard.cancelActiveTouches()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(holds, [true, false], "Repeated cleanup cannot re-end a hold")
        XCTAssertEqual(events.count, count, "Release must stop repeated haptic requests")
    }

    func testReleasingOneFingerDoesNotRemoveAnotherKeysPreview() async throws {
        let keyboard = hostedKeyboard()
        var actions: [KeyboardAction] = []
        keyboard.onAction = { actions.append($0) }
        let q = try key("keyboard.key.71", in: keyboard)
        let w = try key("keyboard.key.77", in: keyboard)
        q.sendActions(for: .touchDown)
        w.sendActions(for: .touchDown)
        let activePreview = try XCTUnwrap(keyboard.subviews.compactMap { $0 as? KeyboardPopupView }.first)
        q.sendActions(for: .touchUpInside)
        XCTAssertTrue(activePreview.superview === keyboard)
        XCTAssertEqual(actions, [.insert("q")])
        w.sendActions(for: .touchUpInside)
        XCTAssertTrue(activePreview.superview === keyboard, "A committed key keeps its preview briefly visible")
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertNil(activePreview.superview)
        XCTAssertEqual(actions, [.insert("q"), .insert("w")])
    }

    func testOldPreviewDismissalCannotRemoveANewHeldKeysFeedback() async throws {
        let keyboard = hostedKeyboard()
        let q = try key("keyboard.key.71", in: keyboard)
        let w = try key("keyboard.key.77", in: keyboard)
        q.sendActions(for: .touchDown)
        q.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(20))
        w.sendActions(for: .touchDown)
        let newer = try XCTUnwrap(keyboard.subviews.compactMap { $0 as? KeyboardPopupView }.first)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(newer.superview === keyboard, "The previous key's delay must not dismiss a held neighbor")
        w.sendActions(for: .touchUpInside)
        keyboard.cancelActiveTouches()
        XCTAssertNil(newer.superview, "Lifecycle cancellation removes delayed feedback immediately")
    }

    func testHeldShiftUpdatesLettersImmediatelyAndSurvivesHostRefreshUntilRelease() throws {
        let keyboard = hostedKeyboard()
        var actions: [KeyboardAction] = []
        keyboard.onAction = { actions.append($0) }
        let shift = try key("keyboard.shift", in: keyboard)
        shift.sendActions(for: .touchDown)
        XCTAssertEqual(keyboard.shiftState, .on)
        let upperF = try key("keyboard.key.46", in: keyboard)
        upperF.sendActions(for: .touchDown)
        upperF.sendActions(for: .touchUpInside)
        keyboard.apply(KeyboardViewState(shift: .off))
        XCTAssertEqual(keyboard.shiftState, .on, "Autocapitalization must not end a physical Shift chord")
        shift.sendActions(for: .touchUpInside)
        XCTAssertEqual(keyboard.shiftState, .off)
        XCTAssertEqual(actions, [.insert("F")])
    }

    func testCancelledShiftRestoresCaseAndDoesNotSeedCapsLock() throws {
        let keyboard = hostedKeyboard()
        let shift = try key("keyboard.shift", in: keyboard)
        shift.sendActions(for: .touchDown)
        XCTAssertEqual(keyboard.shiftState, .on)
        shift.sendActions(for: .touchCancel)
        XCTAssertEqual(keyboard.shiftState, .off)
        shift.sendActions(for: .touchDown)
        shift.sendActions(for: .touchUpInside)
        XCTAssertEqual(keyboard.shiftState, .on)
    }

    func testCancellingHeldCharacterSuppressesItsLaterReleaseButNotANewPress() throws {
        let keyboard = hostedKeyboard()
        var actions: [KeyboardAction] = []
        keyboard.onAction = { actions.append($0) }
        let q = try key("keyboard.key.71", in: keyboard)
        q.sendActions(for: .touchDown)
        keyboard.cancelActiveTouches()
        q.sendActions(for: .touchUpInside)
        XCTAssertTrue(actions.isEmpty, "A stale release after lifecycle cancellation must not type")
        q.sendActions(for: .touchDown)
        q.sendActions(for: .touchUpInside)
        XCTAssertEqual(actions, [.insert("q")])
    }

    func testCancellingHeldDeleteDoesNotDeleteAgainOnLateRelease() throws {
        let keyboard = hostedKeyboard()
        var actions: [KeyboardAction] = []
        keyboard.onAction = { actions.append($0) }
        let delete = try key("keyboard.backspace", in: keyboard)
        delete.sendActions(for: .touchDown)
        XCTAssertEqual(actions, [.backspace])
        keyboard.cancelActiveTouches()
        delete.sendActions(for: .touchUpInside)
        XCTAssertEqual(actions, [.backspace])
    }

    func testThaiToneMarkHasNoDottedCircleAndSaraAmKeepsRawText() throws {
        let label = KeyboardMarkLabel(frame: CGRect(x: 0, y: 0, width: 27, height: 37.333))
        label.usesThaiKeycapMetrics = true
        label.font = .systemFont(ofSize: 24)
        label.textColor = .black
        label.text = "่"
        let tone = try renderedInkBounds(label)
        XCTAssertLessThan(tone.width, 3.5, "A dotted circle or visible shaping anchor would widen this mark")
        XCTAssertLessThan(tone.height, 8)
        XCTAssertLessThan(tone.maxY, 18, "The tone mark belongs above the key's center")
        XCTAssertEqual(label.text, "่")

        label.text = "ำ"
        XCTAssertTrue(KeyboardMarkLabel.isIsolatedThaiMark("ำ"))
        let saraAm = try renderedInkBounds(label)
        XCTAssertGreaterThan(saraAm.height, 15)
        XCTAssertLessThan(saraAm.width, 15)
        XCTAssertGreaterThan(saraAm.minX, 5)
        XCTAssertEqual(label.text, "ำ", "The hidden shaping anchor must never become user text")
        XCTAssertNotEqual(saraAm, tone, "Changing text must invalidate its cached outline")
    }

    func testPageControlsUseMeasuredTrackingAndThaiCurrencyHasNumericMetrics() throws {
        let label = KeyboardMarkLabel(frame: CGRect(x: 0, y: 0, width: 45.333, height: 43))
        label.font = .systemFont(ofSize: 20)
        label.textColor = .black
        label.text = "#+="
        label.setPageControl(target: .symbols, source: .numbers, language: .english)
        let control = try renderedInkBounds(label)
        XCTAssertEqual(control.width, 23.667, accuracy: 0.667)
        XCTAssertEqual(control.height, 7.667, accuracy: 0.667)
        XCTAssertEqual(control.midY, 20.834, accuracy: 0.667)
        XCTAssertEqual(label.text, "#+=")

        label.frame.size.width = 33.333
        label.font = .systemFont(ofSize: 24)
        label.text = "฿"
        label.setPageControl(target: nil, source: .numbers, language: .thai)
        label.englishKeycapPage = .numbers
        let currency = try renderedInkBounds(label)
        XCTAssertEqual(currency.height, 18.667, accuracy: 0.667)
        XCTAssertLessThan(currency.maxY, 30.5)
        XCTAssertTrue(KeyboardMarkLabel.hasEnglishKeycapMetrics("$", page: .symbols),
                      "Thai's symbol page must reuse the measured dollar glyph")
    }

    func testShiftDeleteAndReturnIconsRemainVisibleAboveKeycapsInLightAndDark() throws {
        let keyboard = hostedKeyboard()
        for dark in [false, true] {
            keyboard.apply(KeyboardViewState(appearance: dark ? .dark : .light))
            keyboard.layoutIfNeeded()
            for identifier in ["keyboard.shift", "keyboard.backspace", "keyboard.return"] {
                let button = try key(identifier, in: keyboard)
                button.layoutIfNeeded()
                let pixels = try renderedControlInkPixels(button, dark: dark)
                XCTAssertGreaterThan(pixels, 20,
                                     "\(identifier) must render visible icon pixels above its keycap in \(dark ? "dark" : "light") mode")
            }
        }
    }

    func testLandscapeEnglishAndThaiKeepNativeRowsHeaderAndBottomInset() throws {
        let keyboard = hostedKeyboard()
        keyboard.apply(KeyboardViewState(needsInputModeSwitchKey: false))
        keyboard.frame.size = CGSize(width: 724, height: keyboard.preferredHeight(for: 724))
        keyboard.layoutIfNeeded()
        XCTAssertEqual(keyboard.bounds.height, 204)
        let q = try keycapFrame(key("keyboard.key.71", in: keyboard), in: keyboard)
        XCTAssertEqual(q.minX, 4, accuracy: 0.334)
        XCTAssertEqual(keyboard.bounds.height - q.minY, 154, accuracy: 0.334, "Extra preview space must not move bottom-anchored keys")
        XCTAssertEqual(q.width, 66.333, accuracy: 0.334)
        XCTAssertEqual(q.height, 32, accuracy: 0.334)
        let englishReturn = try keycapFrame(key("keyboard.return", in: keyboard), in: keyboard)
        XCTAssertEqual(keyboard.bounds.height - englishReturn.maxY, 2, accuracy: 0.334)

        keyboard.apply(KeyboardViewState(language: .thai, needsInputModeSwitchKey: false))
        keyboard.frame.size.height = keyboard.preferredHeight(for: 724)
        keyboard.layoutIfNeeded()
        XCTAssertEqual(keyboard.bounds.height, 207)
        let thai = try keycapFrame(key("keyboard.key.e45", in: keyboard), in: keyboard)
        XCTAssertEqual(thai.minX, 3, accuracy: 0.334)
        XCTAssertEqual(keyboard.bounds.height - thai.minY, 157, accuracy: 0.334)
        XCTAssertEqual(thai.width, 55.333, accuracy: 0.334)
        XCTAssertEqual(thai.height, 27, accuracy: 0.334)
        let thaiReturn = try keycapFrame(key("keyboard.return", in: keyboard), in: keyboard)
        XCTAssertEqual(keyboard.bounds.height - thaiReturn.maxY, 2, accuracy: 0.334)
    }

    func testLandscapeThaiGlyphUsesSmallerMeasuredInkAndRestoresPortrait() throws {
        let label = KeyboardMarkLabel(frame: CGRect(x: 0, y: 0, width: 55.333, height: 27))
        label.usesThaiKeycapMetrics = true
        label.font = .systemFont(ofSize: 24)
        label.textColor = .black
        label.text = "ๅ"
        let portrait = try renderedInkBounds(label)
        label.usesLandscapeMetrics = true
        let landscape = try renderedInkBounds(label)
        XCTAssertEqual(landscape.height, 13, accuracy: 0.667)
        XCTAssertLessThan(landscape.height, portrait.height - 3)
        label.usesLandscapeMetrics = false
        XCTAssertEqual(try renderedInkBounds(label), portrait)
    }

    private func renderedControlInkPixels(_ button: UIButton, dark: Bool) throws -> Int {
        let cap = try XCTUnwrap(button.subviews.first { $0.accessibilityIdentifier == "keyboard.keycap" })
        return try renderedInkPixels(button, interior: cap.frame.insetBy(dx: 8, dy: 8), dark: dark)
    }

    private func renderedInkPixels(_ view: UIView, interior: CGRect, dark: Bool) throws -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            (dark ? UIColor.black : UIColor.white).setFill()
            context.fill(view.bounds)
            view.layer.render(in: context.cgContext)
        }
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Sample only the keycap's interior, excluding its rounded border and
        // the transparent hit-cell margin. A covered UIImage gives zero here.
        var count = 0
        for y in max(0, Int(interior.minY * 3))..<min(height, Int(interior.maxY * 3)) {
            for x in max(0, Int(interior.minX * 3))..<min(width, Int(interior.maxX * 3)) {
                let value = bytes[(y * width + x) * 4]
                if dark ? value > 220 : value < 50 { count += 1 }
            }
        }
        return count
    }

    private func renderedInkBounds(_ label: UILabel) throws -> CGRect {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: label.bounds.size, format: format).image { context in
            UIColor.white.setFill()
            // The renderer rounds fractional point sizes to whole pixels.
            // Fill that last pixel too, so it cannot be mistaken for glyph ink.
            context.fill(CGRect(x: 0, y: 0, width: ceil(label.bounds.width), height: ceil(label.bounds.height)))
            label.drawText(in: label.bounds)
        }
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4] < 128 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        XCTAssertGreaterThanOrEqual(right, left, "Expected a visible glyph")
        return CGRect(x: CGFloat(left) / 3, y: CGFloat(top) / 3,
                      width: CGFloat(max(0, right - left + 1)) / 3,
                      height: CGFloat(max(0, bottom - top + 1)) / 3)
    }

    private func hostedKeyboard() -> KeyboardView {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 300))
        let controller = UIViewController()
        window.rootViewController = controller
        let keyboard = KeyboardView()
        keyboard.frame = CGRect(x: 0, y: 0, width: 393, height: keyboard.preferredHeight(for: 393))
        controller.view.addSubview(keyboard)
        window.isHidden = false
        window.layoutIfNeeded()
        keyboard.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            keyboard.cancelActiveTouches()
            window.isHidden = true
            window.rootViewController = nil
        }
        return keyboard
    }

    private func keycapFrame(_ button: UIButton, in keyboard: KeyboardView) throws -> CGRect {
        let cap = try XCTUnwrap(button.subviews.first { $0.accessibilityIdentifier == "keyboard.keycap" })
        return button.convert(cap.frame, to: keyboard)
    }

    private func key(_ identifier: String, in keyboard: KeyboardView,
                     file: StaticString = #filePath, line: UInt = #line) throws -> UIButton {
        try XCTUnwrap(keyboard.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == identifier },
                      "Missing keyboard control: \(identifier)", file: file, line: line)
    }
}
