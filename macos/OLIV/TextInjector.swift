// Paste-at-cursor text injection — a Swift port of app/inject.py (W1-T5).
//
// macOS has no public "type this Unicode string into the focused control" API
// that works everywhere, so we use the classic pattern every dictation tool
// uses (and that Wave-1 debugged): snapshot the pasteboard → write our text →
// synthesize Cmd+V → restore the snapshot. Posting per-character events is
// unreliable for arbitrary Unicode (dead keys, combining marks, emoji, IME);
// the pasteboard round-trips any string byte-for-byte and one Cmd+V is atomic
// from the target app's point of view.
//
// The changeCount / paste-window design (verbatim port of inject.py's, see its
// docstring for the full rationale): there is NO public signal that a paste was
// *consumed* — a read doesn't bump NSPasteboard.changeCount. So after writing
// our text we remember its changeCount, post Cmd+V, then wait a bounded ~1s:
//   • changeCount stays == ours the whole window → WE still own the pasteboard,
//     safe to restore the user's original. (restored = true)
//   • changeCount advances → some OTHER writer took over (clipboard manager,
//     user copy); we back off and do NOT restore, to avoid clobbering newer
//     content. (restored = false)
//
// Accessibility gate (same contract as inject.py): if CGPreflightPostEventAccess
// is false we SET the clipboard, do NOT post Cmd+V, and do NOT restore — the
// text must stay available for a manual Cmd+V. posted = false, usedFallback =
// true.
//
// What snapshot/restore does and does NOT preserve (port of inject.py): every
// declared type's materialized NSData round-trips byte-for-byte (plain text,
// RTF, HTML, images, file URLs, custom binary — verified incl. Thai combining
// marks + emoji). NOT preserved: lazily *promised* data (drag/file promises) —
// if data(forType:) is nil at snapshot time there is nothing to save, so that
// flavor is dropped; and the pasteboard owner association itself.
//
// Testability: the pasteboard is injectable (default .general) so tests use a
// uniquely-named NSPasteboard and never clobber the user's clipboard, and the
// Accessibility check + Cmd+V poster are overridable closures so the decision
// logic is exercised hermetically WITHOUT posting real keys (permissions) —
// mirroring how app/__main__.py's --clipboard-unittest mocks check_post_access /
// _post_cmd_v. See TextInjectorTests.

import AppKit
import Carbon.HIToolbox   // IsSecureEventInputEnabled()
import CoreGraphics
import Foundation

/// Outcome of an inject() call. Superset of app.inject.InjectResult.
struct InjectResult: Equatable {
    /// True iff we successfully synthesized Cmd+V.
    let posted: Bool
    /// True iff we put the user's original clipboard back afterwards.
    let restored: Bool
    /// True iff we WANTED to paste but couldn't (missing Accessibility / post
    /// error) and left the text on the clipboard for a manual Cmd+V.
    let usedFallback: Bool
    /// The effective paste mode.
    let mode: String
    /// Number of characters written to the pasteboard.
    let textLength: Int
    /// Human-readable explanation of what happened / what to do next.
    let notes: String
}

final class TextInjector {
    enum Mode: String {
        case clipboardRestore = "clipboard_restore"
        case clipboardOnly = "clipboard_only"
    }

    /// A faithful, restorable capture of the pasteboard: per item, each declared
    /// type's concrete Data, plus the changeCount token at snapshot time. Port
    /// of app.inject.ClipboardSnapshot.
    struct ClipboardSnapshot {
        let items: [[String: Data]]
        let changeCount: Int

        var isEmpty: Bool { !items.contains { !$0.isEmpty } }

        func summary() -> String {
            if isEmpty { return "empty (no items)" }
            let parts = items.enumerated().map { index, item -> String in
                let bits = item.map { type, data in "\(type) [\(data.count) bytes]" }
                return "item\(index): " + bits.joined(separator: ", ")
            }
            return "\(items.count) item(s): " + parts.joined(separator: " | ")
        }
    }

    /// kVK_ANSI_V — layout-independent hardware keycode, so Cmd+<this> is Cmd+V
    /// on any keyboard layout.
    private static let keyCodeV: CGKeyCode = 9

    private let pasteboard: NSPasteboard

    /// Overridable for hermetic tests. Default preflights macOS Accessibility
    /// (Quartz CGPreflightPostEventAccess, never prompts).
    var postAccessCheck: () -> Bool = { CGPreflightPostEventAccess() }
    /// Overridable for hermetic tests. Default synthesizes Cmd+V via CGEvent.
    var cmdVPoster: () -> Bool = TextInjector.defaultPostCmdV
    /// Overridable for hermetic tests. True when macOS "secure input" is active
    /// (a password field is focused): the OS blocks synthesized key events, so a
    /// Cmd+V we post would be silently dropped. We detect this up front and leave
    /// the text on the clipboard for a manual paste rather than "posting" a Cmd+V
    /// the target never sees (which would read as a silent failure — A2).
    var secureInputCheck: () -> Bool = { IsSecureEventInputEnabled() }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    // MARK: Snapshot / restore (port of save_clipboard / restore_saved_clipboard)

    /// Snapshot the pasteboard for later faithful restore. Read-only. Per-type
    /// reads are individually guarded so one unreadable/promised flavor can't
    /// abort the whole snapshot.
    func snapshot() -> ClipboardSnapshot {
        var items: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var dataByType: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type.rawValue] = data
                }
            }
            items.append(dataByType)
        }
        return ClipboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    /// Rewrite the pasteboard from a snapshot. An empty snapshot is restored as
    /// an emptied pasteboard (so a previously-empty clipboard round-trips to
    /// empty). Never throws for a single bad type.
    @discardableResult
    func restore(_ snapshot: ClipboardSnapshot) -> Bool {
        pasteboard.clearContents()
        var newItems: [NSPasteboardItem] = []
        for dataByType in snapshot.items {
            let item = NSPasteboardItem()
            var wroteAny = false
            for (type, data) in dataByType {
                if item.setData(data, forType: NSPasteboard.PasteboardType(type)) {
                    wroteAny = true
                }
            }
            if wroteAny { newItems.append(item) }
        }
        if !newItems.isEmpty { pasteboard.writeObjects(newItems) }
        return true
    }

    // MARK: Public entry point (port of inject_text)

    /// Paste `text` at the focused app's cursor via clipboard + Cmd+V. Never
    /// throws for the expected failure modes (missing Accessibility) — those
    /// come back as a degraded InjectResult with usedFallback = true.
    @discardableResult
    func inject(
        _ text: String,
        mode: Mode = .clipboardRestore,
        restoreClipboard: Bool = true,
        pasteTimeout: TimeInterval = 1.0
    ) -> InjectResult {
        let textLength = text.count

        // Snapshot the current clipboard first (read-only), for a possible restore.
        let snapshot = self.snapshot()

        // Write our text; remember the changeCount so the paste-window poll can
        // tell "we still own it" from "someone else wrote".
        let ownChangeCount = setString(text)

        // clipboard_only: set and stop. Never post, never restore.
        if mode == .clipboardOnly {
            return InjectResult(
                posted: false,
                restored: false,
                usedFallback: false,
                mode: mode.rawValue,
                textLength: textLength,
                notes: "clipboard_only mode: text placed on the clipboard; no keys "
                    + "synthesized and clipboard not restored. Paste manually with Cmd+V."
            )
        }

        // clipboard_restore: gate on Accessibility.
        if !postAccessCheck() {
            return InjectResult(
                posted: false,
                restored: false,
                usedFallback: true,
                mode: mode.rawValue,
                textLength: textLength,
                notes: "Accessibility not granted: could not synthesize Cmd+V. Text left "
                    + "on the clipboard for manual paste; original clipboard intentionally NOT "
                    + "restored so the text stays available. Grant Accessibility in System "
                    + "Settings › Privacy & Security › Accessibility, then relaunch."
            )
        }

        // Secure input active (a password field is focused): the OS drops
        // synthesized key events, so posting Cmd+V would fail silently. Degrade
        // to the same clipboard-fallback as missing Accessibility — the text
        // stays available for a real (user-typed) Cmd+V, which secure input
        // still honours.
        if secureInputCheck() {
            return InjectResult(
                posted: false,
                restored: false,
                usedFallback: true,
                mode: mode.rawValue,
                textLength: textLength,
                notes: "Secure input is active (a password field is focused): a synthesized "
                    + "Cmd+V would be ignored, so it was not posted. Text left on the clipboard "
                    + "for a manual Cmd+V; original clipboard intentionally NOT restored."
            )
        }

        // Post the synthetic Cmd+V.
        let posted = cmdVPoster()
        if !posted {
            return InjectResult(
                posted: false,
                restored: false,
                usedFallback: true,
                mode: mode.rawValue,
                textLength: textLength,
                notes: "Cmd+V synthesis failed unexpectedly despite Accessibility being "
                    + "granted; text left on the clipboard for manual paste, original not restored."
            )
        }

        // Posted OK. Optionally restore the original after the app has had its
        // bounded chance to read our text.
        if !restoreClipboard {
            return InjectResult(
                posted: true,
                restored: false,
                usedFallback: false,
                mode: mode.rawValue,
                textLength: textLength,
                notes: "posted Cmd+V; restoreClipboard = false, so injected text left on the clipboard."
            )
        }

        let externallyChanged = waitForPasteWindow(ownChangeCount: ownChangeCount, timeout: pasteTimeout)
        if externallyChanged {
            return InjectResult(
                posted: true,
                restored: false,
                usedFallback: false,
                mode: mode.rawValue,
                textLength: textLength,
                notes: "posted Cmd+V; another writer changed the clipboard during the paste "
                    + "window, so the original was NOT restored (avoided clobbering newer content)."
            )
        }

        restore(snapshot)
        return InjectResult(
            posted: true,
            restored: true,
            usedFallback: false,
            mode: mode.rawValue,
            textLength: textLength,
            notes: "posted Cmd+V; waited up to \(pasteTimeout)s for the paste, then restored "
                + "the original clipboard (\(snapshot.summary()))."
        )
    }

    // MARK: Internals

    /// Write `text` as a UTF-8 string, returning the resulting changeCount.
    private func setString(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Bounded wait after posting Cmd+V. Polls changeCount up to `timeout`;
    /// returns true if an EXTERNAL writer changed the pasteboard (caller must
    /// NOT restore). Port of inject.py's _wait_for_paste_window.
    private func waitForPasteWindow(ownChangeCount: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            if pasteboard.changeCount != ownChangeCount { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return pasteboard.changeCount != ownChangeCount
    }

    /// Synthesize Cmd+V key down/up via CGEvent, posted to the HID event tap so
    /// the frontmost app sees a real paste shortcut. Port of _post_cmd_v.
    /// Assumes the caller already verified Accessibility.
    private static func defaultPostCmdV() -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else {
            return false
        }
        // Carry the Command modifier on both edges so the shortcut fires even
        // with no physical modifier down.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
