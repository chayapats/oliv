import XCTest
import UIKit

@MainActor
final class KeyboardLayoutTests: XCTestCase {
    func testEnglishRowsRespectShiftWithoutChangingKeyPositions() {
        let lowercase = KeyboardLayout.rows(for: KeyboardViewState(language: .english), page: .letters)
        let uppercase = KeyboardLayout.rows(for: KeyboardViewState(language: .english, shift: .on), page: .letters)
        XCTAssertEqual(characters(in: lowercase[0]).joined(), "qwertyuiop")
        XCTAssertEqual(characters(in: lowercase[1]).joined(), "asdfghjkl")
        XCTAssertEqual(characters(in: lowercase[2]).joined(), "zxcvbnm")
        XCTAssertEqual(uppercase.prefix(3).map { characters(in: $0).joined() },
                       ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"])
        XCTAssertEqual(lowercase.map { $0.keys.count }, uppercase.map { $0.keys.count })
        XCTAssertEqual(lowercase[2].keys.first?.kind, .shift)
        XCTAssertEqual(lowercase[2].keys.last?.kind, .backspace)
    }

    func testThaiRowsMatchCapturedAppleMobileLayoutIncludingCombiningMarks() {
        let lower = KeyboardLayout.rows(for: KeyboardViewState(language: .thai), page: .letters)
        let upper = KeyboardLayout.rows(for: KeyboardViewState(language: .thai, shift: .on), page: .letters)
        // Independent reference: Apple-Thai-{letters,shift}-light-default
        // PNG and native key frames captured on iOS 27.0 / iPhone 17.
        let referenceLower = ["ๅ / _ ภ ถ ุ ึ ค ต จ ข ช", "ๆ ไ ำ พ ะ ั ี ร น ย บ ล",
                              "ฟ ห ก ด เ ้ ่ า ส ว ง ฃ", "ผ ป แ อ ิ ื ท ม ใ ฝ"]
        let referenceUpper = ["+ ๑ ๒ ๓ ๔ ู ฿ ๕ ๖ ๗ ๘ ๙", "๐ \" ฎ ฑ ธ ํ ๊ ณ ฯ ญ ฐ ,",
                              "ฤ ฆ ฏ โ ฌ ็ ๋ ษ ศ ซ . ฅ", "( ) ฉ ฮ ฺ ์ ? ฒ ฬ ฦ"]
        XCTAssertEqual(lower.count, 5)
        XCTAssertEqual(lower.prefix(4).map { characters(in: $0) }, referenceLower.map { $0.unicodeScalars.split(separator: " ").map(String.init) })
        XCTAssertEqual(upper.prefix(4).map { characters(in: $0) }, referenceUpper.map { $0.unicodeScalars.split(separator: " ").map(String.init) })
        for rows in [lower, upper] {
            XCTAssertEqual(rows.prefix(4).map { $0.keys.count }, [12, 12, 12, 12])
            XCTAssertTrue(rows.prefix(4).allSatisfy { $0.horizontalInset == 0 && $0.keys.allSatisfy { $0.width == 1 } })
            XCTAssertEqual(rows[3].keys.first?.kind, .shift)
            XCTAssertEqual(rows[3].keys.last?.kind, .backspace)
        }
        let characters = Set((lower + upper).flatMap { self.characters(in: $0) })
        let required = "ัิีึืฺุู็่้๊๋์ํ๐๑๒๓๔๕๖๗๘๙ฤฦฃฅ".unicodeScalars.map { String($0) }
        for character in required {
            XCTAssertTrue(characters.contains(character), "Missing Thai scalar: \(character.unicodeScalars.first!.value)")
        }
        XCTAssertEqual(KeyboardLayout.displayText("่"), "่")
        XCTAssertTrue(characters.contains("่"), "Combining marks are passed raw; Core Text handles their keycap shaping.")
        XCTAssertFalse(characters.contains("◌่"))
        XCTAssertEqual(KeyboardLayout.accessibilityLabel(for: "๊"), "ไม้ตรี")
    }

    func testNumbersSymbolsAndHostSpecificPunctuationRemainAvailable() {
        let state = KeyboardViewState()
        let numbers = KeyboardLayout.rows(for: state, page: .numbers)
        let symbols = KeyboardLayout.rows(for: state, page: .symbols)
        let available = Set((numbers + symbols).flatMap { characters(in: $0) })
        for scalar in "0123456789_/%@#$+=•".unicodeScalars {
            XCTAssertTrue(available.contains(String(scalar)))
        }
        let email = KeyboardLayout.rows(for: KeyboardViewState(keyboardType: .emailAddress), page: .letters)
        let url = KeyboardLayout.rows(for: KeyboardViewState(keyboardType: .URL), page: .letters)
        XCTAssertTrue(characters(in: email.last!).contains("@"))
        XCTAssertTrue(characters(in: email.last!).contains("."))
        XCTAssertTrue(characters(in: url.last!).contains("/"))
        XCTAssertTrue(characters(in: url.last!).contains("."))
    }

    func testNumberAndSymbolPagesMatchAppleLanguageSpecificCurrencyPositions() {
        for language in KeyboardLanguage.allCases {
            let state = KeyboardViewState(language: language)
            let numbers = KeyboardLayout.rows(for: state, page: .numbers)
            let symbols = KeyboardLayout.rows(for: state, page: .symbols)
            // Native Apple-{English,Thai}-{numbers,symbols} captures, 2026-10-03.
            let numberReference = [Array("1234567890").map(String.init),
                                   ["-", "/", ":", ";", "(", ")", language == .thai ? "฿" : "$", "&", "@", "\""],
                                   [".", ",", "?", "!", "'"]]
            let symbolReference = [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                                   ["_", "\\", "|", "~", "<", ">"] + (language == .thai ? ["$", "€", "¥", "•"] : ["€", "£", "¥", "•"]),
                                   [".", ",", "?", "!", "'"]]
            XCTAssertEqual(numbers.prefix(3).map { characters(in: $0) }, numberReference)
            XCTAssertEqual(symbols.prefix(3).map { characters(in: $0) }, symbolReference)
            XCTAssertEqual(numbers[2].keys.first?.kind, .page(.symbols))
            XCTAssertEqual(symbols[2].keys.first?.kind, .page(.numbers))
            XCTAssertEqual(numbers[2].keys.last?.kind, .backspace)
            XCTAssertEqual(symbols[2].keys.last?.kind, .backspace)
        }
    }

    func testThaiKeyActionsInsertRawScalarsAfterMobileLayoutRepositioning() throws {
        let keyboard = hostedKeyboard()
        var actions: [KeyboardAction] = []
        keyboard.onAction = { actions.append($0) }
        for text in ["_", "ฃ", "ุ", "ึ", "ั", "ี", "้", "่", "ิ", "ื"] {
            keyboard.apply(KeyboardViewState(language: .thai))
            let identifier = "keyboard.key." + text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
            try key(identifier, in: keyboard).sendActions(for: .touchUpInside)
            XCTAssertEqual(actions.last, .insert(text))
        }
        keyboard.apply(KeyboardViewState(language: .thai, shift: .on))
        try key("keyboard.key.e05", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(actions.last, .insert("ฅ"))
        XCTAssertEqual(keyboard.shiftState, .off)
    }

    func testNumericHostLayoutsHaveRequiredGlobeAndLocaleDecimalSeparator() {
        for type: UIKeyboardType in [.numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad] {
            let rows = KeyboardLayout.rows(for: KeyboardViewState(keyboardType: type), page: .letters)
            let keys = rows.flatMap(\.keys)
            XCTAssertEqual(keys.filter { $0.kind == .globe }.count, 1)
            XCTAssertTrue(keys.contains { $0.kind == .backspace })
            for digit in "0123456789" { XCTAssertTrue(keys.contains { $0.kind == .character(String(digit)) }) }
            XCTAssertFalse(keys.contains { $0.kind == .character("q") })
        }
        let decimal = KeyboardLayout.rows(for: KeyboardViewState(keyboardType: .decimalPad), page: .letters)
        XCTAssertTrue(decimal.flatMap(\.keys).contains { $0.kind == .character(Locale.current.decimalSeparator ?? ".") })
        let noGlobe = KeyboardLayout.rows(for: KeyboardViewState(needsInputModeSwitchKey: false), page: .letters)
        XCTAssertFalse(noGlobe.flatMap(\.keys).contains { $0.kind == .globe })
        XCTAssertEqual(KeyboardLayout.returnTitle(.search, language: .english), "search")
        XCTAssertEqual(KeyboardLayout.returnTitle(.send, language: .thai), "ส่ง")
    }

    func testOneShotShiftAndCapsLockSurviveHostAutocapitalizationRefresh() throws {
        let keyboard = hostedKeyboard()
        var actions: [KeyboardAction] = []
        keyboard.onAction = { actions.append($0) }
        try key("keyboard.shift", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(keyboard.shiftState, .on)
        try key("keyboard.key.41", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(actions, [.insert("A")])
        XCTAssertEqual(keyboard.shiftState, .off)

        try key("keyboard.shift", in: keyboard).sendActions(for: .touchUpInside)
        try key("keyboard.shift", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(keyboard.shiftState, .locked)
        keyboard.apply(KeyboardViewState(shift: .off))
        XCTAssertEqual(keyboard.shiftState, .locked)
        try key("keyboard.key.42", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(actions.last, .insert("B"))
        XCTAssertEqual(keyboard.shiftState, .locked)
        keyboard.apply(KeyboardViewState(language: .thai, shift: .off))
        XCTAssertEqual(keyboard.shiftState, .off, "English caps lock does not leak into a newly selected Thai layout.")
    }

    func testLanguageSpaceReturnAndSymbolControlsEmitOnlyTheirRequestedActions() throws {
        let keyboard = hostedKeyboard()
        var actions: [KeyboardAction] = []
        keyboard.onAction = { actions.append($0) }
        try key("keyboard.language", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(keyboard.language, .english, "The controller owns persisted language selection.")
        try key("keyboard.space", in: keyboard).sendActions(for: .touchUpInside)
        try key("keyboard.return", in: keyboard).sendActions(for: .touchUpInside)
        try key("keyboard.nextKeyboard", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(actions, [.switchLanguage, .space, .returnKey, .nextKeyboard])
        try key("keyboard.numbers", in: keyboard).sendActions(for: .touchUpInside)
        try key("keyboard.symbols", in: keyboard).sendActions(for: .touchUpInside)
        try key("keyboard.key.5f", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(actions.last, .insert("_"))
    }

    func testBackspaceRepeatsOnlyWhileHeldAndStopsAtCancellation() async throws {
        let keyboard = hostedKeyboard()
        var deletes = 0
        keyboard.onAction = { if $0 == .backspace { deletes += 1 } }
        let delete = try key("keyboard.backspace", in: keyboard)
        delete.sendActions(for: .touchDown)
        XCTAssertEqual(deletes, 1)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertGreaterThan(deletes, 1)
        delete.sendActions(for: .touchUpOutside)
        let released = deletes
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(deletes, released)

        delete.sendActions(for: .touchDown)
        keyboard.cancelActiveTouches()
        let disappeared = deletes
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(deletes, disappeared, "Cancellation must leave no repeating keyboard work behind.")
    }

    func testEveryKeyHasAnAccessibleIdentityAndFitsPortraitOrLandscape() {
        let keyboard = hostedKeyboard()
        for language in KeyboardLanguage.allCases {
            keyboard.apply(KeyboardViewState(language: language))
            for width: CGFloat in [320, 393, 852] {
                keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.preferredHeight(for: width))
                keyboard.layoutIfNeeded()
                for button in keyboard.subviews.compactMap({ $0 as? UIButton }) {
                    XCTAssertFalse(button.accessibilityIdentifier?.isEmpty ?? true)
                    XCTAssertFalse(button.accessibilityLabel?.isEmpty ?? true)
                    XCTAssertTrue(button.frame.width.isFinite && button.frame.height.isFinite)
                    XCTAssertGreaterThan(button.frame.width, 0)
                    XCTAssertGreaterThan(button.frame.height, 0)
                    XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
                    XCTAssertLessThanOrEqual(button.frame.maxX, keyboard.bounds.width + 0.1)
                    XCTAssertLessThanOrEqual(button.frame.maxY, keyboard.bounds.height + 0.1)
                }
            }
        }
    }

    /// UIControl sends its target actions through UIApplication. Give these controls a real
    /// window/scene just as the extension does, instead of testing disconnected view objects.
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
        addTeardownBlock { @MainActor in
            keyboard.cancelActiveTouches()
            window.isHidden = true
            window.rootViewController = nil
        }
        return keyboard
    }

    private func characters(in row: KeyboardRow) -> [String] {
        row.keys.compactMap { if case .character(let text) = $0.kind { text } else { nil } }
    }

    private func key(_ identifier: String, in keyboard: KeyboardView,
                     file: StaticString = #filePath, line: UInt = #line) throws -> UIButton {
        let button = try XCTUnwrap(keyboard.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == identifier },
                                   "Missing keyboard control: \(identifier)", file: file, line: line)
        XCTAssertFalse(button.actions(forTarget: keyboard, forControlEvent: .touchUpInside)?.isEmpty ?? true,
                       "Control has no release target: \(identifier)", file: file, line: line)
        return button
    }
}
