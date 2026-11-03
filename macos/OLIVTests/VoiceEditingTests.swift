// Command mode (#23) and translation (#24). Hermetic: a uniquely named
// pasteboard, a fake Accessibility layer, fake ⌘C/⌘V/⌘Z posters and the
// model-free native fixture. No real keys, no models, no Accessibility grant.

import AppKit
import Combine
import XCTest
@testable import OLIV

/// Thread-safe recorder for the fake key posters (they run on the worker).
private final class Log<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class FakeAccessibility: AccessibilityProviding, @unchecked Sendable {
    var selected: String?
    var context: (range: NSRange, value: String)?
    var secure = false
    var pid: pid_t? = 42
    /// The focused field and its window, by identity (nil: not exposed).
    var element: NSString? = "text-field-1"
    var window: NSString? = "window-1"
    /// The selected range Accessibility reports; falls back to `context`.
    var range: NSRange?
    let selects = Log<NSRange>()
    let reads = Log<Int>()

    func selectedText() -> String? { reads.append(1); return selected }
    func selectionContext() -> (range: NSRange, value: String)? { context }
    func select(_ range: NSRange) -> Bool {
        selects.append(range)
        if let context {
            selected = (context.value as NSString).substring(with: range)
            self.range = range
        }
        return true
    }
    func focusedIsSecure() -> Bool { secure }
    func focusSnapshot() -> FocusSnapshot {
        reads.append(1)
        return FocusSnapshot(processID: pid, element: element.map { AXIdentity($0) },
                             window: window.map { AXIdentity($0) },
                             selectedRange: range ?? context?.range, selectedText: selected)
    }
}

private struct FakeTransformer: TextTransforming {
    var reply: (DictationMode, String, String) throws -> TransformResult
    let calls = Log<(DictationMode, String, String)>()
    func transform(mode: DictationMode, instruction: String, text: String) throws -> TransformResult {
        calls.append((mode, instruction, text))
        return try reply(mode, instruction, text)
    }
}

private struct ModelDown: Error {}

final class VoiceEditingTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var ax: FakeAccessibility!
    private let copies = Log<Int>()
    private let pastes = Log<String>()
    private let undos = Log<Int>()

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.oliv.test.voice.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("the user's clipboard", forType: .string)
        ax = FakeAccessibility()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    /// A reader whose ⌘C makes the "app" copy `copied` (nil: copies nothing).
    private func reader(copying copied: String? = nil, extraType: (NSPasteboard.PasteboardType, Data)? = nil) -> SelectionReader {
        reader(copying: Box(copied), extraType: extraType)
    }

    private func reader(copying box: Box<String?>, extraType: (NSPasteboard.PasteboardType, Data)? = nil) -> SelectionReader {
        let reader = SelectionReader(pasteboard: pasteboard, accessibility: ax)
        let pasteboard = self.pasteboard!
        let copies = self.copies
        reader.copyPoster = {
            copies.append(1)
            if let copied = box.value {
                pasteboard.clearContents()
                pasteboard.setString(copied, forType: .string)
                if let extraType { pasteboard.setData(extraType.1, forType: extraType.0) }
            }
            return true
        }
        reader.modifiersHeld = { false }
        reader.secureInputCheck = { false }
        reader.copyTimeout = 0.1
        return reader
    }

    private func injector() -> TextInjector {
        let injector = TextInjector(pasteboard: pasteboard)
        let pasteboard = self.pasteboard!
        let pastes = self.pastes, undos = self.undos
        injector.postAccessCheck = { true }
        injector.secureInputCheck = { false }
        injector.cmdVPoster = { pastes.append(pasteboard.string(forType: .string) ?? ""); return true }
        injector.cmdZPoster = { undos.append(1); return true }
        return injector
    }

    private func captured(_ result: SelectionResult) -> SelectionCapture? {
        if case .selected(let capture) = result { return capture }
        return nil
    }

    /// `text` selected through Accessibility in the fake's current field.
    private func axTarget(_ text: String) -> SelectionCapture {
        ax.selected = text
        return SelectionCapture(text: text, source: .accessibility, focus: ax.focusSnapshot())
    }

    private func job(_ mode: DictationMode = .command, block: VoiceEditPolicy.Block? = nil,
                     transformer: TextTransforming?, reader: SelectionReader? = nil,
                     recentPaste: String? = nil, modelReady: Bool = true) -> VoiceEditJob {
        VoiceEditJob(mode: mode, block: block, transformer: transformer,
                     reader: reader ?? self.reader(), recentPaste: recentPaste,
                     modelReady: modelReady, undoHint: "Control + Shift + Z")
    }

    // MARK: Selection capture

    func testAccessibilitySelectionIsReadWithoutTouchingTheClipboard() {
        ax.selected = "ส่งไฟล์ deck มาด่วน"
        let result = reader(copying: "should not copy").capture(recentPaste: nil)
        XCTAssertEqual(result, .selected(SelectionCapture(text: "ส่งไฟล์ deck มาด่วน", source: .accessibility,
                                                          focus: ax.focusSnapshot())))
        XCTAssertEqual(captured(result)?.processID, 42)
        XCTAssertTrue(copies.all.isEmpty, "no ⌘C when Accessibility exposes the selection")
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    func testCopyFallbackReadsTheSelectionAndRestoresTheClipboard() {
        ax.selected = nil   // e.g. an Electron app
        let result = reader(copying: "selected in Slack").capture(recentPaste: nil)
        XCTAssertEqual(captured(result)?.text, "selected in Slack")
        XCTAssertEqual(captured(result)?.source, .copy)
        XCTAssertEqual(copies.all.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard",
                       "the user's clipboard comes back after the ⌘C fallback")
    }

    func testCopyFallbackThatCopiesNothingMeansNoSelection() {
        ax.selected = nil
        XCTAssertEqual(reader(copying: nil).capture(recentPaste: nil), .none)
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    func testVSCodeLineCopyFromAnEmptySelectionIsIgnored() {
        ax.selected = nil
        let marker = Data(#"{"version":1,"isFromEmptySelection":true,"mode":"plaintext"}"#.utf8)
        let reader = reader(copying: "the whole current line\n", extraType: (SelectionReader.vscodeEditorData, marker))
        XCTAssertEqual(reader.capture(recentPaste: nil), .none)
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    func testAKnownEmptySelectionSkipsCopyAndUsesTheRecentPaste() {
        let pasted = "รบกวนส่งไฟล์ deck มาให้หน่อยครับ"
        let value = "สวัสดีครับ " + pasted
        ax.selected = ""
        ax.context = (NSRange(location: (value as NSString).length, length: 0), value)
        let result = reader(copying: "must not copy").capture(recentPaste: pasted)
        XCTAssertEqual(captured(result)?.text, pasted)
        XCTAssertEqual(captured(result)?.source, .recentPaste)
        XCTAssertEqual(captured(result)?.focus?.selectedText, pasted, "where it lives is read after selecting it")
        XCTAssertTrue(copies.all.isEmpty, "Accessibility proved nothing is selected")
        XCTAssertEqual(ax.selects.all, [NSRange(location: ("สวัสดีครับ " as NSString).length,
                                                length: (pasted as NSString).length)])
    }

    func testARecentPasteThatIsNoLongerBeforeTheCaretIsNotSelected() {
        let value = "OLIV pasted this, then the user kept typing"
        ax.selected = ""
        ax.context = (NSRange(location: (value as NSString).length, length: 0), value)
        XCTAssertEqual(reader().capture(recentPaste: "OLIV pasted"), .none)
        XCTAssertTrue(ax.selects.all.isEmpty)
    }

    func testPasswordFieldsAreNeverRead() {
        ax.selected = "hunter2"
        ax.secure = true
        XCTAssertEqual(reader(copying: "hunter2").capture(recentPaste: nil), .secure)
        let secureInput = reader(copying: "hunter2")
        ax.secure = false
        secureInput.secureInputCheck = { true }
        XCTAssertEqual(secureInput.capture(recentPaste: nil), .secure)
        XCTAssertTrue(copies.all.isEmpty)
    }

    // MARK: Command mode replacement

    func testCommandModeReplacesTheSelectionThroughThePastePath() {
        let transformer = FakeTransformer { _, _, _ in
            TransformResult(applied: true, text: "รบกวนส่งไฟล์ deck มาให้หน่อยครับ", flag: "ok")
        }
        let target = axTarget("ส่งไฟล์ deck มาด่วน")
        let result = VoiceEditRunner.finishCommand(instruction: "ทำให้สุภาพขึ้น", target: target,
                                                   job: job(transformer: transformer), injector: injector())
        XCTAssertEqual(result.outcome, .pastedOK)
        XCTAssertEqual(result.pastedText, "รบกวนส่งไฟล์ deck มาให้หน่อยครับ")
        XCTAssertEqual(pastes.all, ["รบกวนส่งไฟล์ deck มาให้หน่อยครับ"], "⌘V over the live selection")
        XCTAssertEqual(transformer.calls.all.first?.1, "ทำให้สุภาพขึ้น")
        XCTAssertEqual(transformer.calls.all.first?.2, "ส่งไฟล์ deck มาด่วน")
        XCTAssertEqual(result.notice?.text, "Edited · Control + Shift + Z undoes it")
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
        // Kept with the Recent entry, for a wrong-result report.
        XCTAssertEqual(result.edit, TranscriptLog.VoiceEdit(
            mode: .command, heard: "ทำให้สุภาพขึ้น", selection: "ส่งไฟล์ deck มาด่วน", applied: true, flag: "ok"))
    }

    func testARejectedOrFailedTransformLeavesTheOriginalUntouched() {
        let target = SelectionCapture(text: "ทำไม build พัง", source: .copy, focus: ax.focusSnapshot())
        let unsure = "OLIV wasn’t sure about that edit — your text is unchanged"
        for (transformer, notice) in [
            (FakeTransformer { _, _, text in TransformResult(applied: false, text: text, flag: "answered") }, unsure),
            // Cut off at the token limit (rust/crates/oliv-text/src/transform.rs).
            (FakeTransformer { _, _, text in TransformResult(applied: false, text: text, flag: "unfinished") }, unsure),
            (FakeTransformer { _, _, _ in throw ModelDown() },
             "Couldn’t reach the on-device model — your text is unchanged"),
        ] {
            let result = VoiceEditRunner.finishCommand(instruction: "ทำให้สุภาพขึ้น", target: target,
                                                       job: job(transformer: transformer), injector: injector())
            XCTAssertEqual(result.outcome, .nothingToDo)
            XCTAssertNil(result.pastedText)
            XCTAssertNil(result.edit, "nothing landed, so nothing goes to Recent")
            XCTAssertEqual(result.notice?.text, notice)
        }
        XCTAssertTrue(pastes.all.isEmpty, "nothing was pasted over the selection")
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    func testAnEmptyInstructionNeverReachesTheModel() {
        let transformer = FakeTransformer { _, _, _ in XCTFail("no instruction"); throw ModelDown() }
        let result = VoiceEditRunner.finishCommand(
            instruction: "  ", target: SelectionCapture(text: "x", source: .accessibility),
            job: job(transformer: transformer), injector: injector())
        XCTAssertEqual(result.outcome, .nothingToDo)
        XCTAssertTrue(pastes.all.isEmpty)
    }

    func testSwitchingAppsLeavesTheEditOnTheClipboardInstead() {
        let transformer = FakeTransformer { _, _, _ in TransformResult(applied: true, text: "edited", flag: "ok") }
        let target = axTarget("original")
        ax.pid = 99   // focus is now in another app
        let result = VoiceEditRunner.finishCommand(
            instruction: "สั้นลง", target: target, job: job(transformer: transformer), injector: injector())
        XCTAssertEqual(result.outcome, .pasteNeedsManual)
        XCTAssertEqual(result.notice?.text, "You switched apps — the edit is on the clipboard")
        XCTAssertTrue(pastes.all.isEmpty, "never pasted into the other app")
        XCTAssertEqual(pasteboard.string(forType: .string), "edited")
    }

    /// The model takes a second or more; the user may select something else
    /// in the same app meanwhile. The edit replaces only the selection it was
    /// made for; anything else gets the edit on the clipboard.
    func testAnEditOnlyReplacesTheSelectionItWasMadeFor() {
        let transformer = FakeTransformer { _, _, _ in TransformResult(applied: true, text: "edited", flag: "ok") }
        func edit(after change: (FakeAccessibility) -> Void) -> VoiceEditResult {
            ax.pid = 42
            ax.element = "text-field-1"
            ax.window = "window-1"
            ax.range = NSRange(location: 4, length: 8)
            let target = axTarget("original")
            change(ax)
            return VoiceEditRunner.finishCommand(instruction: "สั้นลง", target: target,
                                                 job: job(transformer: transformer), injector: injector())
        }
        let changes: [(String, (FakeAccessibility) -> Void, String)] = [
            ("other text selected", { $0.selected = "other words"; $0.range = NSRange(location: 20, length: 11) },
             "Your selection changed — the edit is on the clipboard"),
            ("the same words selected elsewhere", { $0.range = NSRange(location: 40, length: 8) },
             "Your selection changed — the edit is on the clipboard"),
            ("another field", { $0.element = "text-field-2" },
             "Your selection changed — the edit is on the clipboard"),
            ("another window", { $0.window = "window-2" },
             "Your selection changed — the edit is on the clipboard"),
            ("no focused element", { $0.element = nil },
             "Couldn’t confirm your selection — the edit is on the clipboard"),
            ("selection not readable", { $0.selected = nil },
             "Couldn’t confirm your selection — the edit is on the clipboard"),
            ("range not readable", { $0.range = nil },
             "Couldn’t confirm your selection — the edit is on the clipboard"),
        ]
        for (name, change, notice) in changes {
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)
            let result = edit(after: change)
            XCTAssertEqual(result.outcome, .pasteNeedsManual, name)
            XCTAssertEqual(result.notice?.text, notice, name)
            XCTAssertEqual(pasteboard.string(forType: .string), "edited", "\(name): the edit waits on the clipboard")
        }
        XCTAssertTrue(pastes.all.isEmpty, "never pasted over something else")
        let result = edit(after: { _ in })
        XCTAssertEqual(result.outcome, .pastedOK, "the same selection is replaced")
        XCTAssertEqual(pastes.all, ["edited"])
    }

    /// Apps that only answer ⌘C (Electron): the selection is copied again
    /// right before replacing it, and the user's clipboard comes back.
    func testACopiedSelectionIsCopiedAgainBeforeItIsReplaced() {
        let transformer = FakeTransformer { _, _, _ in TransformResult(applied: true, text: "edited", flag: "ok") }
        ax.selected = nil
        let copied = Box<String?>("selected in Slack")
        let reader = reader(copying: copied)
        guard let target = captured(reader.capture(recentPaste: nil)) else { return XCTFail("no capture") }
        XCTAssertEqual(target.source, .copy)
        XCTAssertEqual(reader.verify(target), .same)
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
        for (now, expected) in [("something else", TargetCheck.changed), (nil, .changed)] as [(String?, TargetCheck)] {
            copied.value = now
            XCTAssertEqual(reader.verify(target), expected)
            XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
        }
        copied.value = "something else"
        let result = VoiceEditRunner.finishCommand(instruction: "สั้นลง", target: target,
                                                   job: job(transformer: transformer, reader: reader),
                                                   injector: injector())
        XCTAssertEqual(result.outcome, .pasteNeedsManual)
        XCTAssertTrue(pastes.all.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "edited",
                       "the clipboard restore after re-copying never wipes the edit")
        copied.value = "selected in Slack"
        XCTAssertEqual(VoiceEditRunner.finishCommand(instruction: "สั้นลง", target: target,
                                                     job: job(transformer: transformer, reader: reader),
                                                     injector: injector()).outcome, .pastedOK)
        XCTAssertEqual(pastes.all, ["edited"])
    }

    /// The selection is read after the microphone closes. If the app, the
    /// window or the selection moved since the key came up, nothing is read
    /// as the target and nothing is edited.
    func testASelectionThatMovedSinceReleaseIsNotEdited() {
        ax.selected = "the text the user selected"
        ax.range = NSRange(location: 0, length: 26)
        let transformer = FakeTransformer { _, _, _ in XCTFail("must not transform"); throw ModelDown() }
        let reader = reader(copying: "x")
        let ax = self.ax!
        let moves: [(String, () -> Void, String)] = [
            ("another app", { ax.pid = 43 }, "You switched apps before OLIV read your selection — your text is unchanged"),
            ("another window", { ax.window = "window-2" }, "Your selection changed while OLIV was listening — your text is unchanged"),
            ("another range", { ax.range = NSRange(location: 4, length: 4) }, "Your selection changed while OLIV was listening — your text is unchanged"),
            ("other text, same range", { ax.selected = "something else entirely!!" }, "Your selection changed while OLIV was listening — your text is unchanged"),
        ]
        for (name, move, notice) in moves {
            let saved = (ax.pid, ax.window, ax.range, ax.selected)
            var frozen = job(transformer: transformer, reader: reader)
            frozen.releaseFocus = reader.focusNow()
            move()
            let prepared = VoiceEditRunner.prepareCommand(frozen)
            XCTAssertNil(prepared.target, name)
            XCTAssertEqual(prepared.refusal?.notice?.text, notice, name)
            (ax.pid, ax.window, ax.range, ax.selected) = saved
        }
        var frozen = job(transformer: transformer, reader: reader)
        frozen.releaseFocus = reader.focusNow()
        XCTAssertEqual(VoiceEditRunner.prepareCommand(frozen).target?.text, "the text the user selected", "nothing moved")
    }

    /// The re-copy takes a moment: moving the cursor, the window or the app
    /// while it runs must not let the edit replace what is selected after.
    func testFocusThatMovesDuringTheReCopyIsCaught() {
        ax.selected = nil
        ax.range = NSRange(location: 0, length: 17)
        let copied = Box<String?>("selected in Slack")
        let reader = reader(copying: copied)
        guard let target = captured(reader.capture(recentPaste: nil)) else { return XCTFail("no capture") }
        XCTAssertEqual(target.source, .copy)
        let copy = reader.copyPoster
        let ax = self.ax!
        let moves: [(String, () -> Void, TargetCheck)] = [
            ("another app", { ax.pid = 43 }, .otherApp),
            ("another window", { ax.window = "window-2" }, .changed),
            ("the cursor", { ax.range = NSRange(location: 3, length: 0) }, .changed),
        ]
        for (name, move, expected) in moves {
            let saved = (ax.pid, ax.window, ax.range)
            reader.copyPoster = { let posted = copy(); move(); return posted }
            XCTAssertEqual(reader.verify(target), expected, name)
            (ax.pid, ax.window, ax.range) = saved
        }
        reader.copyPoster = copy
        XCTAssertEqual(reader.verify(target), .same, "nothing moved")
    }

    func testCommandModeRefusesVerbatimAppsAndPasswordManagersBeforeReading() {
        ax.selected = "secret selection"
        let transformer = FakeTransformer { _, _, _ in XCTFail("must not transform"); throw ModelDown() }
        for block in [VoiceEditPolicy.Block.verbatim, .passwordManager] {
            let prepared = VoiceEditRunner.prepareCommand(job(block: block, transformer: transformer,
                                                              reader: reader(copying: "x")))
            XCTAssertNil(prepared.target)
            XCTAssertEqual(prepared.refusal?.outcome, .nothingToDo)
        }
        XCTAssertTrue(ax.reads.all.isEmpty, "the selection is never read")
        XCTAssertTrue(copies.all.isEmpty)
        XCTAssertEqual(VoiceEditPolicy.block(bundleID: "com.1Password.1password", verbatimApps: []), .passwordManager)
        XCTAssertEqual(VoiceEditPolicy.block(bundleID: "COM.APPLE.TERMINAL", verbatimApps: ["com.apple.terminal"]), .verbatim)
        XCTAssertNil(VoiceEditPolicy.block(bundleID: "com.apple.notes", verbatimApps: ["com.apple.terminal"]))
        XCTAssertNil(VoiceEditPolicy.block(bundleID: nil, verbatimApps: ["com.apple.terminal"]))
    }

    func testCommandModeExplainsWhatItNeeds() {
        let transformer = FakeTransformer { _, _, _ in XCTFail(); throw ModelDown() }
        ax.selected = nil
        var prepared = VoiceEditRunner.prepareCommand(job(transformer: transformer, reader: reader(copying: nil)))
        XCTAssertEqual(prepared.refusal?.notice?.text, "Select some text first, then hold the Command mode shortcut")
        prepared = VoiceEditRunner.prepareCommand(job(transformer: transformer, modelReady: false))
        XCTAssertTrue(prepared.refusal?.notice?.text.contains("cleanup model") == true)
        ax.selected = String(repeating: "ก", count: VoiceEditRunner.maxSelection + 1)
        prepared = VoiceEditRunner.prepareCommand(job(transformer: transformer))
        XCTAssertTrue(prepared.refusal?.notice?.text.contains("too long") == true)
    }

    // MARK: Translation

    func testTranslationPastesEnglishOrFallsBackToWhatWasSaid() {
        let thai = "เดี๋ยวผม deploy ตัว hotfix ตอนห้าโมง"
        var result = VoiceEditRunner.finishTranslation(
            transcript: thai,
            job: job(.translate, transformer: FakeTransformer { _, _, _ in
                TransformResult(applied: true, text: "I'll deploy the hotfix at 5 p.m.", flag: "ok") }),
            injector: injector())
        XCTAssertEqual(result.pastedText, "I'll deploy the hotfix at 5 p.m.")
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.edit, TranscriptLog.VoiceEdit(
            mode: .translation, heard: thai, selection: nil, applied: true, flag: "ok"))
        result = VoiceEditRunner.finishTranslation(
            transcript: thai,
            job: job(.translate, transformer: FakeTransformer { _, _, text in
                TransformResult(applied: false, text: text, flag: "termLost") }),
            injector: injector())
        XCTAssertEqual(result.pastedText, thai, "never loses what was said")
        XCTAssertNotNil(result.notice)
        XCTAssertEqual(result.edit, TranscriptLog.VoiceEdit(
            mode: .translation, heard: thai, selection: nil, applied: false, flag: "termLost"))
        // Cut off at the token limit: the transcript, never half a translation.
        result = VoiceEditRunner.finishTranslation(
            transcript: thai,
            job: job(.translate, transformer: FakeTransformer { _, _, text in
                TransformResult(applied: false, text: text, flag: "unfinished") }),
            injector: injector())
        XCTAssertEqual(result.pastedText, thai)
        XCTAssertEqual(result.notice?.text, "Couldn’t translate that — pasted what you said")
        XCTAssertEqual(result.edit?.flag, "unfinished")
        result = VoiceEditRunner.finishTranslation(
            transcript: "Let's sync after lunch",
            job: job(.translate, transformer: FakeTransformer { _, _, text in
                TransformResult(applied: false, text: text, flag: "noThai") }),
            injector: injector())
        XCTAssertNil(result.notice, "already English: nothing to report")
        result = VoiceEditRunner.finishTranslation(
            transcript: thai,
            job: job(.translate, block: .verbatim, transformer: FakeTransformer { _, _, _ in
                XCTFail("verbatim apps are never translated"); throw ModelDown() }),
            injector: injector())
        XCTAssertEqual(result.pastedText, thai)
        XCTAssertEqual(result.edit, TranscriptLog.VoiceEdit(
            mode: .translation, heard: thai, selection: nil, applied: false, flag: "blocked"))
        XCTAssertEqual(pastes.all, ["I'll deploy the hotfix at 5 p.m.", thai, thai, "Let's sync after lunch", thai])
    }

    // MARK: Policy and settings

    func testShortcutRouting() {
        let primary = HotkeyChord(key: .rightOption), secondary = HotkeyChord(key: .rightControl)
        let undo = HotkeyChord.defaultUndo
        var config = VoiceEditConfiguration()
        XCTAssertEqual(VoiceEditPolicy.bindings(config, pushToTalk: [primary, secondary], undo: undo),
                       ShortcutBindings(dictation: [primary, secondary]))
        config.translateWithSecondary = true
        var bindings = VoiceEditPolicy.bindings(config, pushToTalk: [primary, secondary], undo: undo)
        XCTAssertEqual(bindings.translation, secondary)
        XCTAssertEqual(bindings.dictation, [primary])
        XCTAssertNil(VoiceEditPolicy.bindings(config, pushToTalk: [primary], undo: undo).translation)
        config.commandChord = HotkeyChord(key: .rightCommand)
        bindings = VoiceEditPolicy.bindings(config, pushToTalk: [primary, secondary], undo: undo)
        XCTAssertEqual(bindings.command, HotkeyChord(key: .rightCommand))
        XCTAssertFalse(bindings.commandPaused || bindings.translationPaused)
        XCTAssertEqual(VoiceEditPolicy.dictationMode(bundleID: "COM.TINYSPECK.SLACKMACGAP",
                                                     translationApps: ["com.tinyspeck.slackmacgap"]), .translate)
        XCTAssertEqual(VoiceEditPolicy.dictationMode(bundleID: "com.apple.notes",
                                                     translationApps: ["com.tinyspeck.slackmacgap"]), .dictate)
    }

    /// Pressing a shortcut that contains another one's keys fires the other
    /// first. Such voice-editing shortcuts are paused, never half-working.
    func testOverlappingShortcutsPauseVoiceEditing() {
        let primary = HotkeyChord(key: .rightOption)
        let primaryPlusCommand = HotkeyChord(keys: [.rightOption, .rightCommand])
        let leftControl = HotkeyChord(key: .modifierKey(keyCode: 0x3B))
        let undo = HotkeyChord.defaultUndo   // Left Control + Left Shift + Z
        let translate = VoiceEditConfiguration(translateWithSecondary: true)
        for (pushToTalk, why) in [([primary, primaryPlusCommand], "the secondary contains the primary"),
                                  ([primaryPlusCommand, primary], "the primary contains the secondary"),
                                  ([primary, leftControl], "undo contains the secondary")] {
            let bindings = VoiceEditPolicy.bindings(translate, pushToTalk: pushToTalk, undo: undo)
            XCTAssertNil(bindings.translation, why)
            XCTAssertTrue(bindings.translationPaused, why)
            XCTAssertEqual(bindings.dictation, pushToTalk, "\(why): the secondary dictates instead")
        }
        for (command, why) in [(primaryPlusCommand, "contains push-to-talk"),
                               (leftControl, "is part of undo"),
                               (HotkeyChord(key: .rightControl), "is the secondary")] {
            let bindings = VoiceEditPolicy.bindings(VoiceEditConfiguration(commandChord: command),
                                                    pushToTalk: [primary, HotkeyChord(key: .rightControl)], undo: undo)
            XCTAssertNil(bindings.command, "Command mode \(why)")
            XCTAssertTrue(bindings.commandPaused, "Command mode \(why)")
        }
        // Sharing a key is not overlapping: neither press completes the other.
        XCTAssertFalse(VoiceEditPolicy.overlaps(primaryPlusCommand, HotkeyChord(keys: [.rightOption, .rightControl])))
        let bindings = VoiceEditPolicy.bindings(
            VoiceEditConfiguration(commandChord: HotkeyChord(keys: [.rightCommand, .rightControl])),
            pushToTalk: [primaryPlusCommand], undo: undo)
        XCTAssertEqual(bindings.command, HotkeyChord(keys: [.rightCommand, .rightControl]))
    }

    @MainActor
    func testSettingsAreOffByDefaultAndPersist() {
        let suite = "com.oliv.test.voiceedit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceEditSettings(defaults: defaults)
        XCTAssertFalse(store.commandEnabled)
        XCTAssertFalse(store.translateWithSecondary)
        XCTAssertNil(store.configuration.commandChord, "no Command mode tap until it is turned on")
        var changes = 0
        store.onChange = { changes += 1 }
        store.commandEnabled = true
        store.translateWithSecondary = true
        store.addTranslationApp("  Com.Apple.Mail ")
        XCTAssertEqual(changes, 3)
        let reloaded = VoiceEditSettings(defaults: defaults)
        XCTAssertEqual(reloaded.configuration, VoiceEditConfiguration(
            commandChord: HotkeyChord(key: .rightCommand), translateWithSecondary: true,
            translationApps: ["com.apple.mail"]))
    }

    // MARK: Through the sidecar protocol

    func testSidecarTransformWireFormat() throws {
        let client = SidecarClient(command: [try NativeTestSupport.executable(), "sidecar"])
        defer { client.close() }
        XCTAssertEqual(try client.transform(mode: .command, instruction: "สั้นลง", text: "ข้อความยาว"),
                       TransformResult(applied: true, text: "[command|สั้นลง] ข้อความยาว", flag: "ok"))
        XCTAssertEqual(try client.transform(mode: .translate, instruction: "", text: "KEEP ไว้"),
                       TransformResult(applied: false, text: "KEEP ไว้", flag: "answered"))
    }
}

/// The whole press → release → replace → undo loop on the controller, with
/// the native fixture standing in for the sidecar.
@MainActor
final class CommandModeControllerTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var client: SidecarClient!
    /// The last controller's state (its Recent entries).
    private var state: AppState!

    override func setUpWithError() throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.oliv.test.command.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("the user's clipboard", forType: .string)
        client = SidecarClient(command: [try NativeTestSupport.executable(), "sidecar"])
    }

    override func tearDown() {
        client.close()
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func makeController(selection: String?, app: String = "com.apple.notes",
                                verbatim: Set<String> = [], pastes: Log<String>, undos: Log<Int>,
                                copies: Log<Int>) -> (DictationController, AppState) {
        let worker = CaptureWorker(start: { _, _ in }, stop: {
            var stats = AudioCapture.CaptureStats()
            stats.deviceLive = true
            return CapturedAudio(samples: [0.25, -0.25], stats: stats)
        }, close: {}, isDeviceLive: { true })
        let injector = TextInjector(pasteboard: pasteboard)
        let pasteboard = self.pasteboard!
        injector.postAccessCheck = { true }
        injector.secureInputCheck = { false }
        injector.cmdVPoster = { pastes.append(pasteboard.string(forType: .string) ?? ""); return true }
        injector.cmdZPoster = { undos.append(1); return true }
        let state = AppState()
        self.state = state
        let controller = DictationController(appState: state, injector: injector, captureWorker: worker)
        controller.sidecar = client
        controller.cleanupModelReady = { true }
        controller.frontmostBundleID = { app }
        controller.verbatimApps = verbatim
        controller.startTap = { _ in }   // never a real event tap
        let ax = FakeAccessibility()
        ax.selected = selection
        let reader = SelectionReader(pasteboard: pasteboard, accessibility: ax)
        reader.copyPoster = { copies.append(1); return true }
        reader.modifiersHeld = { false }
        reader.secureInputCheck = { false }
        reader.copyTimeout = 0.05
        controller.selectionReader = reader
        return (controller, state)
    }

    /// Press, wait for the recording, release, wait for idle.
    private func run(_ mode: DictationMode, selection: String?, app: String = "com.apple.notes",
                     verbatim: Set<String> = [], pastes: Log<String>, undos: Log<Int>,
                     copies: Log<Int>) async -> DictationController {
        let (controller, state) = makeController(selection: selection, app: app, verbatim: verbatim,
                                                 pastes: pastes, undos: undos, copies: copies)
        let shortcut: HoldShortcut = switch mode {
        case .dictate: .pushToTalk
        case .translate: .translation
        case .command: .command
        }
        let started = expectation(description: "recording")
        let idle = expectation(description: "back to idle")
        var sawRecording = false
        let observation = state.$status.sink { status in
            if status == .recording, !sawRecording { sawRecording = true; started.fulfill() }
            if status == .idle, sawRecording { idle.fulfill() }
        }
        controller.handlePress(shortcut)
        await fulfillment(of: [started], timeout: 2)
        // Let the capture start complete before releasing.
        try? await Task.sleep(nanoseconds: 250_000_000)
        controller.handleRelease(shortcut)
        await fulfillment(of: [idle], timeout: 10)
        withExtendedLifetime(observation) {}
        return controller
    }

    /// Hold push-to-talk, tap the translation shortcut: its press is ignored
    /// (already recording), and so must its release be.
    func testOnlyTheShortcutThatStartedARecordingEndsIt() async {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        let (controller, state) = makeController(selection: nil, pastes: pastes, undos: undos, copies: copies)
        let idle = expectation(description: "back to idle")
        var sawProcessing = false
        let observation = state.$status.sink { status in
            if status == .processing { sawProcessing = true }
            if status == .idle, sawProcessing { idle.fulfill() }
        }
        controller.handlePress(.pushToTalk)
        XCTAssertEqual(state.status, .recording)
        try? await Task.sleep(nanoseconds: 250_000_000)
        controller.handlePress(.translation)
        controller.handleRelease(.translation)
        XCTAssertEqual(state.status, .recording, "the translation shortcut's release leaves push-to-talk recording")
        controller.handlePress(.command)
        controller.handleRelease(.command)
        XCTAssertEqual(state.status, .recording, "so does Command mode's")
        controller.handleRelease(.pushToTalk)
        XCTAssertEqual(state.status, .processing)
        await fulfillment(of: [idle], timeout: 10)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(pastes.all, ["Hello world."], "dictated as push-to-talk started it")
    }

    /// Every shortcut change re-checks overlaps: an undo shortcut that now
    /// contains Command mode's key pauses Command mode at once, and freeing
    /// it brings Command mode back, without touching anything else.
    func testChangingUndoRechecksTheVoiceEditingShortcuts() {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        let (controller, _) = makeController(selection: nil, pastes: pastes, undos: undos, copies: copies)
        let rightCommand = HotkeyChord(key: .rightCommand)
        controller.hotkeyChords = [HotkeyChord(key: .rightOption), HotkeyChord(key: .rightControl)]
        controller.undoHotkeyChord = .defaultUndo
        controller.voiceEdit = VoiceEditConfiguration(commandChord: rightCommand, translateWithSecondary: true)
        controller.sidecar = nil   // nothing to warm
        controller.start()
        defer { controller.stop() }
        XCTAssertEqual(controller.installedBindings?.command, rightCommand)
        XCTAssertEqual(controller.installedBindings?.translation, HotkeyChord(key: .rightControl))

        controller.applyUndoHotkey(HotkeyChord(keys: [.rightCommand, .regularKey(keyCode: 0x06, characters: "z")]))
        XCTAssertNil(controller.installedBindings?.command, "undo now contains Command mode's key")
        XCTAssertEqual(controller.installedBindings?.commandPaused, true)
        XCTAssertEqual(controller.installedBindings?.translation, HotkeyChord(key: .rightControl))

        controller.applyUndoHotkey(HotkeyChord(keys: [.rightControl, .regularKey(keyCode: 0x06, characters: "z")]))
        XCTAssertEqual(controller.installedBindings?.command, rightCommand, "freed again")
        XCTAssertNil(controller.installedBindings?.translation, "undo now contains the secondary")
        XCTAssertEqual(controller.installedBindings?.dictation,
                       [HotkeyChord(key: .rightOption), HotkeyChord(key: .rightControl)])

        controller.applyUndoHotkey(.defaultUndo)
        XCTAssertEqual(controller.installedBindings, ShortcutBindings(
            dictation: [HotkeyChord(key: .rightOption)], translation: HotkeyChord(key: .rightControl),
            command: rightCommand))
    }

    /// A secondary shortcut that contains the primary's keys never gets a
    /// translation tap of its own (it would lose to plain dictation).
    func testAnOverlappingTranslationShortcutIsNotInstalled() {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        let (controller, _) = makeController(selection: nil, pastes: pastes, undos: undos, copies: copies)
        let primary = HotkeyChord(key: .rightOption)
        let secondary = HotkeyChord(keys: [.rightOption, .rightCommand])
        controller.hotkeyChords = [primary, secondary]
        controller.voiceEdit = VoiceEditConfiguration(translateWithSecondary: true)
        controller.sidecar = nil   // nothing to warm
        controller.start()
        defer { controller.stop() }
        XCTAssertNil(controller.installedBindings?.translation)
        XCTAssertEqual(controller.installedBindings?.translationPaused, true)
        XCTAssertEqual(controller.installedBindings?.dictation, [primary, secondary])
    }

    func testCommandModeReplacesTheSelectionAndUndoRestoresIt() async {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        let controller = await run(.command, selection: "ส่งไฟล์มาด่วน", pastes: pastes, undos: undos, copies: copies)
        // The fixture transcribes the instruction as "Hello world." and echoes
        // the transform request: the selection was replaced with the rewrite.
        XCTAssertEqual(pastes.all, ["[command|Hello world.] ส่งไฟล์มาด่วน"])
        XCTAssertTrue(controller.hasUndoablePaste)
        controller.handleUndo()
        XCTAssertEqual(undos.all.count, 1, "undo-last-paste sends ⌘Z, restoring the original in the host app")
        XCTAssertFalse(controller.hasUndoablePaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    /// A wrong-result report about an edit needs what was selected and what
    /// was asked, not only the instruction's transcript.
    func testRecentEntriesKeepWhatAnEditWasMadeFrom() async throws {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        _ = await run(.command, selection: "ส่งไฟล์มาด่วน", pastes: pastes, undos: undos, copies: copies)
        var entry = try XCTUnwrap(state.transcripts.entries.first)
        XCTAssertEqual(entry.text, "[command|Hello world.] ส่งไฟล์มาด่วน")
        XCTAssertEqual(entry.details?.raw, "hello world", "the instruction, before cleanup")
        XCTAssertEqual(entry.details?.voiceEdit, TranscriptLog.VoiceEdit(
            mode: .command, heard: "Hello world.", selection: "ส่งไฟล์มาด่วน", applied: true, flag: "ok"))
        let report = ResultReport.mac(entry: entry, appVersion: "0.2.2", build: "19", macOSVersion: "15.6")
        XCTAssertEqual(report.source, "ส่งไฟล์มาด่วน")
        XCTAssertEqual(report.instruction, "Hello world.")
        XCTAssertEqual(report.mode, "Command mode · edit applied")

        _ = await run(.translate, selection: nil, pastes: pastes, undos: undos, copies: copies)
        entry = try XCTUnwrap(state.transcripts.entries.first)
        XCTAssertEqual(entry.text, "[translate|] Hello world.")
        XCTAssertEqual(entry.details?.voiceEdit, TranscriptLog.VoiceEdit(
            mode: .translation, heard: "Hello world.", selection: nil, applied: true, flag: "ok"))

        _ = await run(.dictate, selection: nil, pastes: pastes, undos: undos, copies: copies)
        entry = try XCTUnwrap(state.transcripts.entries.first)
        XCTAssertEqual(entry.text, "Hello world.")
        XCTAssertNotNil(entry.details)
        XCTAssertNil(entry.details?.voiceEdit)
    }

    func testARejectedEditNeverPastes() async {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        let controller = await run(.command, selection: "KEEP this text", pastes: pastes, undos: undos, copies: copies)
        XCTAssertTrue(pastes.all.isEmpty, "the selection is left exactly as it was")
        XCTAssertFalse(controller.hasUndoablePaste, "undo has nothing of ours to take back")
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    func testVerbatimAppsAreNeverRewritten() async {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        _ = await run(.command, selection: "ls -la", app: "com.apple.Terminal",
                      verbatim: ["com.apple.terminal"], pastes: pastes, undos: undos, copies: copies)
        XCTAssertTrue(pastes.all.isEmpty)
        XCTAssertTrue(copies.all.isEmpty, "the selection is not even copied")
    }

    func testTranslationShortcutPastesTheTranslation() async {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        _ = await run(.translate, selection: nil, pastes: pastes, undos: undos, copies: copies)
        XCTAssertEqual(pastes.all, ["[translate|] Hello world."])
        XCTAssertTrue(copies.all.isEmpty, "translation never reads the selection")
    }

    func testPlainDictationIsUnchanged() async {
        let pastes = Log<String>(), undos = Log<Int>(), copies = Log<Int>()
        _ = await run(.dictate, selection: "anything", pastes: pastes, undos: undos, copies: copies)
        XCTAssertEqual(pastes.all, ["Hello world."])
        XCTAssertTrue(copies.all.isEmpty)
    }
}
