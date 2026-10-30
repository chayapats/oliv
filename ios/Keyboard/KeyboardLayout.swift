import UIKit

enum KeyboardAction: Equatable {
    case insert(String), backspace, backspaceWord, space, returnKey, switchLanguage, nextKeyboard, moveCursor(Int), moveCursorVertically(Int)
}

enum KeyboardLanguage: String, CaseIterable {
    case english, thai

    var spaceLabel: String { self == .thai ? "ไทย" : "English" }
    var otherLanguageLabel: String { self == .thai ? "EN" : "ไทย" }
}

enum KeyboardShiftState: Equatable { case off, on, locked }

struct KeyboardViewState: Equatable {
    var language: KeyboardLanguage
    var shift: KeyboardShiftState
    var keyboardType: UIKeyboardType
    var returnKeyType: UIReturnKeyType
    var needsInputModeSwitchKey: Bool
    var appearance: UIKeyboardAppearance
    var returnKeyEnabled: Bool

    init(language: KeyboardLanguage = .english, shift: KeyboardShiftState = .off,
         keyboardType: UIKeyboardType = .default, returnKeyType: UIReturnKeyType = .default,
         needsInputModeSwitchKey: Bool = true, appearance: UIKeyboardAppearance = .default,
         returnKeyEnabled: Bool = true) {
        self.language = language
        self.shift = shift
        self.keyboardType = keyboardType
        self.returnKeyType = returnKeyType
        self.needsInputModeSwitchKey = needsInputModeSwitchKey
        self.appearance = appearance
        self.returnKeyEnabled = returnKeyEnabled
    }
}

enum KeyboardPage: Equatable { case letters, numbers, symbols }

struct KeyboardKey: Equatable {
    enum Kind: Equatable {
        case character(String), shift, backspace, space, returnKey, language, globe
        case page(KeyboardPage)
    }
    let kind: Kind
    var width: CGFloat = 1
    var alternatives: [String] = []

    var identifier: String {
        switch kind {
        case .character(let text): "keyboard.key." + text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
        case .shift: "keyboard.shift"
        case .backspace: "keyboard.backspace"
        case .space: "keyboard.space"
        case .returnKey: "keyboard.return"
        case .language: "keyboard.language"
        case .globe: "keyboard.nextKeyboard"
        case .page(.letters): "keyboard.letters"
        case .page(.numbers): "keyboard.numbers"
        case .page(.symbols): "keyboard.symbols"
        }
    }
}

struct KeyboardRow {
    let keys: [KeyboardKey]
    var horizontalInset: CGFloat = 0
}

enum KeyboardLayout {
    // Transcribed from Apple's Thai keyboard on iOS 27.0 / iPhone 17, captured
    // by KeyboardVisualReferenceTests on 2026-10-03. This mobile layout differs
    // from desktop Kedmanee: underscore in row 1 and ฃ/ฅ at the end of row 3.
    static let thaiUnshifted: [[String]] = [
        ["ๅ", "/", "_", "ภ", "ถ", "ุ", "ึ", "ค", "ต", "จ", "ข", "ช"],
        ["ๆ", "ไ", "ำ", "พ", "ะ", "ั", "ี", "ร", "น", "ย", "บ", "ล"],
        ["ฟ", "ห", "ก", "ด", "เ", "้", "่", "า", "ส", "ว", "ง", "ฃ"],
        ["ผ", "ป", "แ", "อ", "ิ", "ื", "ท", "ม", "ใ", "ฝ"]
    ]
    static let thaiShifted: [[String]] = [
        ["+", "๑", "๒", "๓", "๔", "ู", "฿", "๕", "๖", "๗", "๘", "๙"],
        ["๐", "\"", "ฎ", "ฑ", "ธ", "ํ", "๊", "ณ", "ฯ", "ญ", "ฐ", ","],
        ["ฤ", "ฆ", "ฏ", "โ", "ฌ", "็", "๋", "ษ", "ศ", "ซ", ".", "ฅ"],
        ["(", ")", "ฉ", "ฮ", "ฺ", "์", "?", "ฒ", "ฬ", "ฦ"]
    ]

    static func isNumberPad(_ type: UIKeyboardType) -> Bool {
        [.numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad].contains(type)
    }

    static func rows(for state: KeyboardViewState, page: KeyboardPage) -> [KeyboardRow] {
        if isNumberPad(state.keyboardType) { return numberPad(state) }
        var rows: [KeyboardRow]
        switch page {
        case .letters:
            if state.language == .thai {
                let letters = state.shift == .off ? thaiUnshifted : thaiShifted
                rows = letters.enumerated().map { index, row in
                    var keys = row.map(character)
                    if index == 3 {
                        keys.insert(KeyboardKey(kind: .shift), at: 0)
                        keys.append(KeyboardKey(kind: .backspace))
                    }
                    return KeyboardRow(keys: keys)
                }
            } else {
                let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
                rows = letters.enumerated().map { index, row in
                    var keys = row.map { character(state.shift == .off ? String($0) : String($0).uppercased()) }
                    if index == 2 {
                        keys.insert(KeyboardKey(kind: .shift, width: 1.45), at: 0)
                        keys.append(KeyboardKey(kind: .backspace, width: 1.45))
                    }
                    return KeyboardRow(keys: keys, horizontalInset: index == 1 ? 0.048 : 0)
                }
            }
        case .numbers:
            rows = [KeyboardRow(keys: Array("1234567890").map { character(String($0)) }),
                    KeyboardRow(keys: ["-", "/", ":", ";", "(", ")", state.language == .thai ? "฿" : "$", "&", "@", "\""].map(character)),
                    KeyboardRow(keys: [KeyboardKey(kind: .page(.symbols), width: 1.5)]
                        + [".", ",", "?", "!", "'"].map { var key = character($0); key.width = 1.3; return key }
                        + [KeyboardKey(kind: .backspace, width: 1.5)])]
        case .symbols:
            rows = [KeyboardRow(keys: ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map(character)),
                    KeyboardRow(keys: (["_", "\\", "|", "~", "<", ">"]
                        + (state.language == .thai ? ["$", "€", "¥", "•"] : ["€", "£", "¥", "•"])).map(character)),
                    KeyboardRow(keys: [KeyboardKey(kind: .page(.numbers), width: 1.5)]
                        + [".", ",", "?", "!", "'"].map { var key = character($0); key.width = 1.3; return key }
                        + [KeyboardKey(kind: .backspace, width: 1.5)])]
        }
        var bottom = [KeyboardKey(kind: .page(page == .letters ? .numbers : .letters), width: 1.25)]
        if state.needsInputModeSwitchKey { bottom.append(KeyboardKey(kind: .globe, width: 0.95)) }
        bottom.append(KeyboardKey(kind: .language, width: 1.1))
        if state.keyboardType == .emailAddress || state.keyboardType == .URL {
            bottom.append(KeyboardKey(kind: .character(state.keyboardType == .emailAddress ? "@" : "/"), width: 0.9))
        }
        bottom.append(KeyboardKey(kind: .space, width: state.needsInputModeSwitchKey ? 4.2 : 5.15))
        if state.keyboardType == .emailAddress || state.keyboardType == .URL {
            bottom.append(KeyboardKey(kind: .character("."), width: 0.9, alternatives: [".com", ".co.th", ".org", ".net"]))
        }
        bottom.append(KeyboardKey(kind: .returnKey, width: 2.1))
        rows.append(KeyboardRow(keys: bottom))
        return rows
    }

    static func displayText(_ text: String) -> String {
        // Core Text supplies the standalone Thai-mark anchor. Prefixing U+25CC adds
        // a second dotted circle in UIKit, so keep both keycap and insertion text raw.
        text
    }

    static func accessibilityLabel(for text: String) -> String {
        let names = ["ั": "ไม้หันอากาศ", "ิ": "สระอิ", "ี": "สระอี", "ึ": "สระอึ", "ื": "สระอือ",
                     "ุ": "สระอุ", "ู": "สระอู", "ฺ": "พินทุ", "็": "ไม้ไต่คู้", "่": "ไม้เอก",
                     "้": "ไม้โท", "๊": "ไม้ตรี", "๋": "ไม้จัตวา", "์": "ทัณฑฆาต", "ํ": "นิคหิต"]
        return names[text] ?? text
    }

    static func returnTitle(_ type: UIReturnKeyType, language: KeyboardLanguage) -> String {
        let thai = language == .thai
        switch type {
        case .go: return thai ? "ไป" : "go"
        case .search, .google, .yahoo: return thai ? "ค้นหา" : "search"
        case .send: return thai ? "ส่ง" : "send"
        case .join: return thai ? "เข้าร่วม" : "join"
        case .next: return thai ? "ถัดไป" : "next"
        case .done: return thai ? "เสร็จ" : "done"
        case .route: return thai ? "เส้นทาง" : "route"
        case .emergencyCall: return thai ? "ฉุกเฉิน" : "emergency"
        case .continue: return thai ? "ต่อไป" : "continue"
        default: return thai ? "ขึ้นบรรทัด" : "return"
        }
    }

    private static func character(_ text: String) -> KeyboardKey {
        let lower = text.lowercased()
        let accents: [String: [String]] = [
            "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"], "e": ["è", "é", "ê", "ë", "ē"],
            "i": ["ì", "í", "î", "ï", "ī"], "o": ["ò", "ó", "ô", "ö", "œ", "õ", "ø", "ō"],
            "u": ["ù", "ú", "û", "ü", "ū"], "c": ["ç", "ć", "č"], "n": ["ñ", "ń"], "s": ["ß", "ś", "š"],
            "y": ["ÿ", "ý"], "ข": ["ฃ"], "ค": ["ฅ"], "ฯ": ["๚", "๛"], ".": ["…"],
            "'": ["‘", "’"], "\"": ["“", "”"], "-": ["–", "—", "•"], "$": ["€", "£", "¥", "฿"]
        ]
        var alternatives = accents[lower] ?? []
        if text != lower { alternatives = alternatives.map { $0.uppercased() } }
        return KeyboardKey(kind: .character(text), alternatives: alternatives)
    }

    private static func numberPad(_ state: KeyboardViewState) -> [KeyboardRow] {
        var rows = ["123", "456", "789"].map { KeyboardRow(keys: $0.map { character(String($0)) }) }
        var last: [KeyboardKey]
        switch state.keyboardType {
        case .decimalPad: last = [character(Locale.current.decimalSeparator ?? ".")]
        case .phonePad: last = [KeyboardKey(kind: .character("+"), alternatives: ["*", "#"])]
        default: last = [KeyboardKey(kind: state.needsInputModeSwitchKey ? .globe : .returnKey)]
        }
        last += [character("0"), KeyboardKey(kind: .backspace)]
        rows.append(KeyboardRow(keys: last))
        // A globe is required even for host-requested decimal/phone layouts.
        if state.needsInputModeSwitchKey && (state.keyboardType == .decimalPad || state.keyboardType == .phonePad) {
            rows.append(KeyboardRow(keys: [KeyboardKey(kind: .globe), KeyboardKey(kind: .returnKey, width: 2)]))
        }
        return rows
    }
}
