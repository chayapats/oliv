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
// puts the original back. Right before it, `verify` checks that the live
// selection is still the captured one (same app, field, window, range and
// text); if not, or if it can't tell, the edit goes to the clipboard instead.
//
// Testability: the Accessibility calls, the ⌘C poster and the modifier-state
// probe are injectable; tests use a uniquely named pasteboard (never .general).

import AppKit
import ApplicationServices
import Carbon.HIToolbox   // IsSecureEventInputEnabled()

/// An Accessibility element, compared by identity (CFEqual): the same text
/// field read twice is equal, another field is not. Tests use strings.
struct AXIdentity: Equatable {
    let ref: CFTypeRef
    init(_ ref: CFTypeRef) { self.ref = ref }
    static func == (a: AXIdentity, b: AXIdentity) -> Bool { CFEqual(a.ref, b.ref) }
}

/// Where a selection lives: the focused element and its window, the app,
/// and the selection as Accessibility reports it (each nil when unknown).
struct FocusSnapshot: Equatable {
    var processID: pid_t?
    var element: AXIdentity?
    var window: AXIdentity?
    var selectedRange: NSRange?
    var selectedText: String?
}

/// The text Command mode will edit, and where it came from.
struct SelectionCapture: Equatable {
    enum Source: String, Equatable {
        case accessibility, copy, recentPaste
    }
    let text: String
    let source: Source
    /// Where the selection was at capture, so the replacement can refuse to
    /// land anywhere else. nil: unknown, and the edit is never pasted.
    var focus: FocusSnapshot?

    /// The app that owned the focused element at capture (nil if unknown).
    var processID: pid_t? { focus?.processID }
}

/// Is the captured selection still the one the user has, right before the
/// edit replaces it?
enum TargetCheck: Equatable {
    /// Same app, same field and window, same selection: safe to paste.
    case same
    /// Focus moved to another app.
    case otherApp
    /// Another field or window, or a different selection.
    case changed
    /// Accessibility can't tell (no focused element, the app not answering).
    case unverifiable
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
    /// The focused element, its window, app and selection, read together.
    func focusSnapshot() -> FocusSnapshot
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

    func focusSnapshot() -> FocusSnapshot {
        guard let element = focused() else { return FocusSnapshot() }
        var snapshot = FocusSnapshot(element: AXIdentity(element))
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success { snapshot.processID = pid }
        if let window = attribute(element, kAXWindowAttribute),
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            snapshot.window = AXIdentity(window)
        }
        if let rangeValue = attribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {   // type checked above
                snapshot.selectedRange = NSRange(location: range.location, length: range.length)
            }
        }
        snapshot.selectedText = attribute(element, kAXSelectedTextAttribute) as? String
        return snapshot
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
        // Where the selection lives, read once it is final (after selecting a
        // recent paste), for `verify` to compare before replacing it.
        func selected(_ text: String, _ source: SelectionCapture.Source) -> SelectionResult {
            .selected(SelectionCapture(text: text, source: source, focus: accessibility.focusSnapshot()))
        }
        let axText = accessibility.selectedText()
        if let axText, !axText.isEmpty {
            return selected(axText, .accessibility)
        }
        // Accessibility says "nothing selected" and proves it with a caret in
        // a readable value: trust it. Otherwise it may simply not know.
        let context = accessibility.selectionContext()
        let knownEmpty = axText == "" && context.map { $0.range.length == 0 } == true
        if !knownEmpty, let copied = copySelection(), !copied.isEmpty {
            return selected(copied, .copy)
        }
        if let recentPaste, !recentPaste.isEmpty, selectRecentPaste(recentPaste, context: context) {
            return selected(recentPaste, .recentPaste)
        }
        return .none
    }

    /// Right before replacing: is `capture`'s selection still exactly what
    /// the user has selected? Same app, same focused element and window, the
    /// same range, and the same text: read through Accessibility when that is
    /// how it was captured, or copied again (⌘C, clipboard restored) when
    /// the app only answers ⌘C. Anything else must not be pasted over.
    func verify(_ capture: SelectionCapture) -> TargetCheck {
        guard let was = capture.focus else { return .unverifiable }
        let now = accessibility.focusSnapshot()
        if let moved = Self.moved(from: was, to: now) { return moved }
        switch capture.source {
        case .accessibility, .recentPaste:
            guard let text = now.selectedText else { return .unverifiable }
            return text == capture.text ? .same : .changed
        case .copy:
            if secureInputCheck() || accessibility.focusedIsSecure() { return .unverifiable }
            guard let copied = copySelection() else { return .changed }
            guard copied == capture.text else { return .changed }
            // The copy takes a moment: the user may have moved the cursor or
            // switched apps meanwhile, and the copied text proves nothing about
            // what is selected now. Look again before allowing the replace.
            return Self.moved(from: was, to: accessibility.focusSnapshot()) ?? .same
        }
    }

    /// Why `now` is no longer the app, field, window and selection of `was`,
    /// or nil when it still is.
    static func moved(from was: FocusSnapshot, to now: FocusSnapshot) -> TargetCheck? {
        guard let pid = was.processID, let element = was.element else { return .unverifiable }
        guard let nowPID = now.processID else { return .unverifiable }
        if nowPID != pid { return .otherApp }
        guard let nowElement = now.element else { return .unverifiable }
        guard nowElement == element else { return .changed }
        if let window = was.window, now.window != window { return .changed }
        // Apps that don't expose a selection range (Electron: Slack, VS Code)
        // are checked by app, field, window and selected text only. Selecting
        // an identical copy of the same text elsewhere while the model runs
        // would get the edit; that is accepted on purpose, so these apps keep
        // in-place replacement, and undo-last-paste puts the text back.
        if let range = was.selectedRange {
            guard let nowRange = now.selectedRange else { return .unverifiable }
            guard nowRange == range else { return .changed }
        }
        return nil
    }

    /// The focused app, field, window and selection right now (Command mode
    /// freezes this when the key comes up), or nil while a password field or
    /// secure input is active: nothing is read there.
    func focusNow() -> FocusSnapshot? {
        if secureInputCheck() || accessibility.focusedIsSecure() { return nil }
        return accessibility.focusSnapshot()
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
}
