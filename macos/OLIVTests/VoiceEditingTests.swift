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
    /// Focus moves to this process after the first capture (app switch).
    var pidAfterCapture: pid_t?
    let selects = Log<NSRange>()
    let reads = Log<Int>()

    func selectedText() -> String? { reads.append(1); return selected }
    func selectionContext() -> (range: NSRange, value: String)? { context }
    func select(_ range: NSRange) -> Bool {
        selects.append(range)
        if let context { selected = (context.value as NSString).substring(with: range) }
        return true
    }
    func focusedIsSecure() -> Bool { secure }
    func focusedProcessID() -> pid_t? {
        defer { if let next = pidAfterCapture { pid = next } }
        return pid
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
        let reader = SelectionReader(pasteboard: pasteboard, accessibility: ax)
        let pasteboard = self.pasteboard!
        let copies = self.copies
        reader.copyPoster = {
            copies.append(1)
            if let copied {
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
        XCTAssertEqual(result, .selected(SelectionCapture(text: "ส่งไฟล์ deck มาด่วน", source: .accessibility, processID: 42)))
        XCTAssertTrue(copies.all.isEmpty, "no ⌘C when Accessibility exposes the selection")
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    func testCopyFallbackReadsTheSelectionAndRestoresTheClipboard() {
        ax.selected = nil   // e.g. an Electron app
        let result = reader(copying: "selected in Slack").capture(recentPaste: nil)
        XCTAssertEqual(result, .selected(SelectionCapture(text: "selected in Slack", source: .copy, processID: 42)))
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
        XCTAssertEqual(result, .selected(SelectionCapture(text: pasted, source: .recentPaste, processID: 42)))
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
        let target = SelectionCapture(text: "ส่งไฟล์ deck มาด่วน", source: .accessibility, processID: 42)
        let result = VoiceEditRunner.finishCommand(instruction: "ทำให้สุภาพขึ้น", target: target,
                                                   job: job(transformer: transformer), injector: injector())
        XCTAssertEqual(result.outcome, .pastedOK)
        XCTAssertEqual(result.pastedText, "รบกวนส่งไฟล์ deck มาให้หน่อยครับ")
        XCTAssertEqual(pastes.all, ["รบกวนส่งไฟล์ deck มาให้หน่อยครับ"], "⌘V over the live selection")
        XCTAssertEqual(transformer.calls.all.first?.1, "ทำให้สุภาพขึ้น")
        XCTAssertEqual(transformer.calls.all.first?.2, "ส่งไฟล์ deck มาด่วน")
        XCTAssertEqual(result.notice?.text, "Edited · Control + Shift + Z undoes it")
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    func testARejectedOrFailedTransformLeavesTheOriginalUntouched() {
        let target = SelectionCapture(text: "ทำไม build พัง", source: .copy, processID: 42)
        for transformer in [
            FakeTransformer { _, _, text in TransformResult(applied: false, text: text, flag: "answered") },
            FakeTransformer { _, _, _ in throw ModelDown() },
        ] {
            let result = VoiceEditRunner.finishCommand(instruction: "ทำให้สุภาพขึ้น", target: target,
                                                       job: job(transformer: transformer), injector: injector())
            XCTAssertEqual(result.outcome, .nothingToDo)
            XCTAssertNil(result.pastedText)
            XCTAssertTrue(result.notice?.text.contains("unchanged") == true)
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
        ax.pid = 99   // focus is now in another app
        let result = VoiceEditRunner.finishCommand(
            instruction: "สั้นลง", target: SelectionCapture(text: "original", source: .accessibility, processID: 42),
            job: job(transformer: transformer), injector: injector())
        XCTAssertEqual(result.outcome, .pasteNeedsManual)
        XCTAssertTrue(pastes.all.isEmpty, "never pasted into the other app")
        XCTAssertEqual(pasteboard.string(forType: .string), "edited")
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
        result = VoiceEditRunner.finishTranslation(
            transcript: thai,
            job: job(.translate, transformer: FakeTransformer { _, _, text in
                TransformResult(applied: false, text: text, flag: "termLost") }),
            injector: injector())
        XCTAssertEqual(result.pastedText, thai, "never loses what was said")
        XCTAssertNotNil(result.notice)
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
        XCTAssertEqual(pastes.all, ["I'll deploy the hotfix at 5 p.m.", thai, "Let's sync after lunch", thai])
    }

    // MARK: Policy and settings

    func testShortcutRouting() {
        let primary = HotkeyChord(key: .rightOption), secondary = HotkeyChord(key: .rightControl)
        var config = VoiceEditConfiguration()
        XCTAssertNil(VoiceEditPolicy.translationChord(config, primary: primary, secondary: secondary))
        config.translateWithSecondary = true
        XCTAssertEqual(VoiceEditPolicy.translationChord(config, primary: primary, secondary: secondary), secondary)
        XCTAssertNil(VoiceEditPolicy.translationChord(config, primary: primary, secondary: nil))
        XCTAssertNil(VoiceEditPolicy.translationChord(config, primary: primary, secondary: primary))
        config.commandChord = HotkeyChord(key: .rightCommand)
        XCTAssertEqual(VoiceEditPolicy.commandChord(config, others: [primary, secondary]), HotkeyChord(key: .rightCommand))
        config.commandChord = HotkeyChord(keys: [.rightOption, .rightCommand])
        XCTAssertNil(VoiceEditPolicy.commandChord(config, others: [primary]), "shares Right Option with push-to-talk")
        XCTAssertEqual(VoiceEditPolicy.dictationMode(bundleID: "COM.TINYSPECK.SLACKMACGAP",
                                                     translationApps: ["com.tinyspeck.slackmacgap"]), .translate)
        XCTAssertEqual(VoiceEditPolicy.dictationMode(bundleID: "com.apple.notes",
                                                     translationApps: ["com.tinyspeck.slackmacgap"]), .dictate)
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

    private func run(_ mode: DictationMode, selection: String?, app: String = "com.apple.notes",
                     verbatim: Set<String> = [], pastes: Log<String>, undos: Log<Int>,
                     copies: Log<Int>) async -> DictationController {
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
        let controller = DictationController(appState: state, injector: injector, captureWorker: worker)
        controller.sidecar = client
        controller.cleanupModelReady = { true }
        controller.frontmostBundleID = { app }
        controller.verbatimApps = verbatim
        let ax = FakeAccessibility()
        ax.selected = selection
        let reader = SelectionReader(pasteboard: pasteboard, accessibility: ax)
        reader.copyPoster = { copies.append(1); return true }
        reader.modifiersHeld = { false }
        reader.secureInputCheck = { false }
        reader.copyTimeout = 0.05
        controller.selectionReader = reader

        let started = expectation(description: "recording")
        let idle = expectation(description: "back to idle")
        var sawRecording = false
        let observation = state.$status.sink { status in
            if status == .recording, !sawRecording { sawRecording = true; started.fulfill() }
            if status == .idle, sawRecording { idle.fulfill() }
        }
        controller.handlePress(mode: mode)
        await fulfillment(of: [started], timeout: 2)
        // Let the capture start complete before releasing.
        try? await Task.sleep(nanoseconds: 250_000_000)
        controller.handleRelease()
        await fulfillment(of: [idle], timeout: 10)
        withExtendedLifetime(observation) {}
        return controller
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
