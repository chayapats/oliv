// TextInjector clipboard round-trip tests — ports of app/__main__.py's
// --clipboard-unittest (_run_clipboard_unittest). Hermetic: every test uses a
// uniquely-NAMED NSPasteboard (never .general) so the user's real clipboard is
// untouched. The CGEvent posting path is NOT exercised (it needs Accessibility);
// instead the Accessibility check and Cmd+V poster are overridden closures, so
// the InjectResult decision logic is asserted deterministically — mirroring how
// the Python test mocks check_post_access / _post_cmd_v.

import AppKit
import XCTest
@testable import OLIV

final class TextInjectorTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        // Unique custom name per test => hermetic, no clobbering .general.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.oliv.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func currentString() -> String? {
        pasteboard.string(forType: .string)
    }

    // --clipboard-unittest [1]/[2]: Thai with combining marks survives byte-exact
    // through a save → clobber → restore round-trip.
    func testThaiCombiningMarksRoundTrip() {
        let injector = TextInjector(pasteboard: pasteboard)
        let thai = "สวัสดีครับ ผมใช้ ไฟล์จูน กับโมเดลนี้" // combining vowel/tone marks
        pasteboard.clearContents()
        pasteboard.setString(thai, forType: .string)
        let snapshot = injector.snapshot()

        pasteboard.clearContents()
        pasteboard.setString("CLOBBERED", forType: .string)
        injector.restore(snapshot)

        XCTAssertEqual(currentString(), thai)
        XCTAssertEqual(currentString()?.utf8.map { $0 }, Array(thai.utf8)) // byte-identical
    }

    // --clipboard-unittest [1]: mixed Thai+English+emoji fidelity.
    func testMixedAndEmojiRoundTrip() {
        let injector = TextInjector(pasteboard: pasteboard)
        for sample in [
            "OLIV ทดสอบ paste ภาษาไทย + English mixed ✓",
            "กราฟาน้ำ ✓ 🎙️",
            "family 👨‍👩‍👧‍👦 flag 🇹🇭 skin 👋🏽", // ZWJ + regional indicators + modifier
        ] {
            pasteboard.clearContents()
            pasteboard.setString(sample, forType: .string)
            let snapshot = injector.snapshot()
            pasteboard.clearContents()
            pasteboard.setString("x", forType: .string)
            injector.restore(snapshot)
            XCTAssertEqual(currentString(), sample)
            XCTAssertEqual(Array(currentString()!.utf8), Array(sample.utf8))
        }
    }

    // --clipboard-unittest [3]: multiple representations on one item round-trip
    // (string + HTML + arbitrary custom binary — all 256 byte values).
    func testMultipleRepresentationsRoundTrip() {
        let injector = TextInjector(pasteboard: pasteboard)
        let htmlType = NSPasteboard.PasteboardType(rawValue: "public.html")
        let customType = NSPasteboard.PasteboardType(rawValue: "com.oliv.test.binary")
        let rawBytes = Data((0...255).map { UInt8($0) })

        let item = NSPasteboardItem()
        item.setString("multi ไทย ✓", forType: .string)
        item.setString("<b>ไทย</b>", forType: htmlType)
        item.setData(rawBytes, forType: customType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let snapshot = injector.snapshot()
        pasteboard.clearContents()
        pasteboard.setString("CLOBBERED", forType: .string)
        injector.restore(snapshot)

        XCTAssertEqual(pasteboard.string(forType: .string), "multi ไทย ✓")
        XCTAssertEqual(pasteboard.string(forType: htmlType), "<b>ไทย</b>")
        XCTAssertEqual(pasteboard.data(forType: customType), rawBytes)
    }

    // A previously-empty clipboard restores to empty (clearContents path).
    func testEmptySnapshotRestoresEmpty() {
        let injector = TextInjector(pasteboard: pasteboard)
        pasteboard.clearContents()
        let snapshot = injector.snapshot()
        XCTAssertTrue(snapshot.isEmpty)

        pasteboard.setString("NOISE", forType: .string)
        injector.restore(snapshot)
        XCTAssertNil(currentString())
    }

    // --clipboard-unittest [4]: posted=True path (posting mocked) restores the
    // original clipboard.
    func testInjectPostedRestoresOriginal() {
        let injector = TextInjector(pasteboard: pasteboard)
        injector.postAccessCheck = { true }
        injector.secureInputCheck = { false }
        injector.cmdVPoster = { true }

        pasteboard.clearContents()
        pasteboard.setString("ORIGINAL-A", forType: .string)

        let result = injector.inject("INJECTED-A", restoreClipboard: true, pasteTimeout: 0.05)
        XCTAssertTrue(result.posted)
        XCTAssertTrue(result.restored)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(currentString(), "ORIGINAL-A")
    }

    // --clipboard-unittest [5]: gated posted=False path (Accessibility missing)
    // leaves the injected text on the clipboard and does NOT restore.
    func testInjectGatedLeavesTextNotRestored() {
        let injector = TextInjector(pasteboard: pasteboard)
        var posterCalls = 0
        injector.postAccessCheck = { false }
        injector.cmdVPoster = { posterCalls += 1; return true }

        pasteboard.clearContents()
        pasteboard.setString("ORIGINAL-B", forType: .string)

        let result = injector.inject("INJECTED-B", restoreClipboard: true, pasteTimeout: 0.05)
        XCTAssertFalse(result.posted)
        XCTAssertFalse(result.restored)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(posterCalls, 0, "must not synthesize keys when Accessibility is missing")
        XCTAssertEqual(currentString(), "INJECTED-B")
    }

    // --clipboard-unittest [6]: clipboard_only mode sets the text, never posts,
    // never restores — even with Accessibility available.
    func testInjectClipboardOnlyNeverPosts() {
        let injector = TextInjector(pasteboard: pasteboard)
        var posterCalls = 0
        injector.postAccessCheck = { true }
        injector.cmdVPoster = { posterCalls += 1; return true }

        pasteboard.clearContents()
        pasteboard.setString("ORIGINAL-C", forType: .string)

        let result = injector.inject("INJECTED-C", mode: .clipboardOnly)
        XCTAssertFalse(result.posted)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(posterCalls, 0)
        XCTAssertEqual(currentString(), "INJECTED-C")
    }

    // Posted but external writer bumps changeCount during the wait => back off,
    // do NOT restore (avoid clobbering newer content).
    func testInjectExternalWriterPreventsRestore() {
        let injector = TextInjector(pasteboard: pasteboard)
        injector.postAccessCheck = { true }
        injector.secureInputCheck = { false }
        injector.cmdVPoster = {
            // Simulate an external writer grabbing the pasteboard right after our
            // Cmd+V post — the changeCount advances past our own write.
            self.pasteboard.clearContents()
            self.pasteboard.setString("EXTERNAL", forType: .string)
            return true
        }
        pasteboard.clearContents()
        pasteboard.setString("ORIGINAL-D", forType: .string)

        let result = injector.inject("INJECTED-D", restoreClipboard: true, pasteTimeout: 0.2)
        XCTAssertTrue(result.posted)
        XCTAssertFalse(result.restored)
        XCTAssertEqual(currentString(), "EXTERNAL")
    }

    // A2: with secure input active (a password field focused) the OS would drop a
    // synthesized Cmd+V, so we must NOT post it — leave the text on the clipboard
    // (usedFallback) for a real, user-typed ⌘V. Accessibility is granted here, so
    // this proves the secure-input gate is independent of the Accessibility gate.
    func testInjectSecureInputLeavesTextNotPosted() {
        let injector = TextInjector(pasteboard: pasteboard)
        var posterCalls = 0
        injector.postAccessCheck = { true }
        injector.secureInputCheck = { true }          // password field focused
        injector.cmdVPoster = { posterCalls += 1; return true }

        pasteboard.clearContents()
        pasteboard.setString("ORIGINAL-E", forType: .string)

        let result = injector.inject("INJECTED-E", restoreClipboard: true, pasteTimeout: 0.05)
        XCTAssertFalse(result.posted)
        XCTAssertTrue(result.usedFallback)
        XCTAssertFalse(result.restored)
        XCTAssertEqual(posterCalls, 0, "must not synthesize Cmd+V under secure input")
        XCTAssertEqual(currentString(), "INJECTED-E", "text stays on the clipboard for manual ⌘V")
    }
}
