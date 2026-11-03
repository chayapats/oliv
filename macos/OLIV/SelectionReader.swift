// Selection capture for Command mode (#23).
//
// Command mode edits the text the user selected in another app. Reading it:
//
//   1. Accessibility: kAXSelectedTextAttribute on the focused element. Native
//      Cocoa text views, Notes, Mail, Pages and most web text fields in Safari
//      expose it. Read-only, no side effects.
//   2. Copy fallback: when the focused element doesn't expose its selection
//      (Electron apps such as Slack and VS Code, many browser editors), post a
//      synthetic ⌘C, read the pasteboard, and restore the user's clipboard.
//      Skipped when Accessibility positively reports an empty selection, so an
//      editor that copies the whole line on an empty selection is never asked;
//      VS Code's own "copied from an empty selection" marker is honoured too.
//   3. Nothing selected: the text OLIV just pasted, when Accessibility can
//      prove it still sits right before the caret. It is then selected, so the
//      replacement paste covers exactly it.
//
// Replacement goes through TextInjector's normal paste (⌘V over the live
// selection), so the host app's undo — and OLIV's undo-last-paste shortcut —
// puts the original back.
//
// Testability: the Accessibility calls, the ⌘C poster and the modifier-state
// probe are injectable; tests use a uniquely named pasteboard (never .general).

import AppKit
import ApplicationServices
import Carbon.HIToolbox   // IsSecureEventInputEnabled()

/// The text Command mode will edit, and where it came from.
struct SelectionCapture: Equatable {
    enum Source: String, Equatable {
        case accessibility, copy, recentPaste
    }
    let text: String
    let source: Source
    /// The app that owned the focused element at capture (nil if unknown),
    /// so the replacement can refuse to land in a different app.
    var processID: pid_t?
}

enum SelectionResult: Equatable {
    case selected(SelectionCapture)
    /// Nothing selected and no recent OLIV paste to fall back on.
    case none
    /// A password field is focused: never read, never rewrite.
    case secure
}

/// The Accessibility calls selection capture needs. Faked in tests.
protocol AccessibilityProviding {
    /// The focused element's selected text: nil when unavailable (no focused
    /// element, attribute unsupported, error), "" when nothing is selected.
    func selectedText() -> String?
    /// The focused element's selected range (UTF-16) and full value, when
    /// both are exposed.
    func selectionContext() -> (range: NSRange, value: String)?
    /// Select a UTF-16 range in the focused element. True on success.
    func select(_ range: NSRange) -> Bool
    /// The focused element is a password (secure text) field.
    func focusedIsSecure() -> Bool
    /// The process that owns the focused element.
    func focusedProcessID() -> pid_t?
}

/// Live Accessibility API, with a short messaging timeout so a hung app
/// can't stall the release worker for the system default (6 s).
struct SystemAccessibility: AccessibilityProviding {
    var timeout: Float = 0.3

    private func focused() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement   // type checked above
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func selectedText() -> String? {
        guard let element = focused() else { return nil }
        return attribute(element, kAXSelectedTextAttribute) as? String
    }

    func selectionContext() -> (range: NSRange, value: String)? {
        guard let element = focused(),
              let rangeValue = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              let text = attribute(element, kAXValueAttribute) as? String else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }   // type checked above
        return (NSRange(location: range.location, length: range.length), text)
    }

    func select(_ range: NSRange) -> Bool {
        guard let element = focused() else { return false }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func focusedIsSecure() -> Bool {
        guard let element = focused() else { return false }
        return attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole as String
    }

    func focusedProcessID() -> pid_t? {
        guard let element = focused() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}

final class SelectionReader {
    /// kVK_ANSI_C — layout-independent, like TextInjector's ⌘V.
    private static let keyCodeC: CGKeyCode = 8
    /// Pasteboard flavour VS Code writes on copy; marks an empty-selection
    /// copy of the whole line.
    static let vscodeEditorData = NSPasteboard.PasteboardType("vscode-editor-data")

    private let pasteboard: NSPasteboard
    private let clipboard: TextInjector
    let accessibility: AccessibilityProviding

    /// Overridable for tests. Default posts ⌘C to the frontmost app.
    var copyPoster: () -> Bool = { TextInjector.postCommandKey(SelectionReader.keyCodeC) }
    /// Overridable for tests. True while the user still holds a modifier
    /// (the Command mode shortcut is often a modifier chord): a ⌘C posted
    /// then would reach the app as ⌘⌥C or similar.
    var modifiersHeld: () -> Bool = {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty
    }
    var secureInputCheck: () -> Bool = { IsSecureEventInputEnabled() }
    /// How long to wait for the app to answer ⌘C.
    var copyTimeout: TimeInterval = 0.35
    var modifierTimeout: TimeInterval = 0.6

    init(pasteboard: NSPasteboard = .general,
         accessibility: AccessibilityProviding = SystemAccessibility()) {
        self.pasteboard = pasteboard
        self.clipboard = TextInjector(pasteboard: pasteboard)
        self.accessibility = accessibility
    }

    /// What Command mode should edit right now. `recentPaste` is the text
    /// OLIV last pasted (nil when unknown or already undone).
    func capture(recentPaste: String?) -> SelectionResult {
        if secureInputCheck() || accessibility.focusedIsSecure() { return .secure }
        let pid = accessibility.focusedProcessID()
        let axText = accessibility.selectedText()
        if let axText, !axText.isEmpty {
            return .selected(SelectionCapture(text: axText, source: .accessibility, processID: pid))
        }
        // Accessibility says "nothing selected" and proves it with a caret in
        // a readable value: trust it. Otherwise it may simply not know.
        let context = accessibility.selectionContext()
        let knownEmpty = axText == "" && context.map { $0.range.length == 0 } == true
        if !knownEmpty, let copied = copySelection(), !copied.isEmpty {
            return .selected(SelectionCapture(text: copied, source: .copy, processID: pid))
        }
        if let recentPaste, !recentPaste.isEmpty, selectRecentPaste(recentPaste, context: context) {
            return .selected(SelectionCapture(text: recentPaste, source: .recentPaste, processID: pid))
        }
        return .none
    }

    /// The copy fallback: ⌘C, read the text, put the user's clipboard back.
    /// nil when the app didn't copy anything (nothing selected, or ⌘C is not
    /// copy there).
    func copySelection() -> String? {
        let deadline = Date().addingTimeInterval(modifierTimeout)
        while modifiersHeld() && Date() < deadline { Thread.sleep(forTimeInterval: 0.015) }
        let saved = clipboard.snapshot()
        let before = pasteboard.changeCount
        guard copyPoster() else { return nil }
        let copyDeadline = Date().addingTimeInterval(copyTimeout)
        while pasteboard.changeCount == before && Date() < copyDeadline {
            Thread.sleep(forTimeInterval: 0.015)
        }
        guard pasteboard.changeCount != before else { return nil }
        // Some apps clear the pasteboard, then write: let the write land.
        Thread.sleep(forTimeInterval: 0.03)
        let copied = pasteboard.string(forType: .string)
        let lineCopy = Self.isEmptySelectionCopy(pasteboard)
        clipboard.restore(saved)
        return lineCopy ? nil : copied
    }

    /// VS Code copies the whole line when nothing is selected and says so in
    /// its own pasteboard flavour.
    static func isEmptySelectionCopy(_ pasteboard: NSPasteboard) -> Bool {
        guard let data = pasteboard.data(forType: vscodeEditorData),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["isFromEmptySelection"] as? Bool == true
    }

    /// Select `text` if it ends exactly at the caret (the paste OLIV just
    /// made, untouched since). Verified by reading the selection back.
    func selectRecentPaste(_ text: String,
                           context: (range: NSRange, value: String)?) -> Bool {
        guard let context, context.range.length == 0 else { return false }
        let value = context.value as NSString
        let length = (text as NSString).length
        let end = context.range.location
        guard length > 0, end >= length, end <= value.length else { return false }
        let range = NSRange(location: end - length, length: length)
        guard value.substring(with: range) == text,
              accessibility.select(range) else { return false }
        return accessibility.selectedText() == text
    }

    /// The app now holding focus, to compare with `SelectionCapture.processID`.
    func focusedProcessID() -> pid_t? { accessibility.focusedProcessID() }
}
