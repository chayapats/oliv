// TranscriptLog — the in-memory "Recent…" history behind the menu (0.1.5).
// Pure value type: prepend-newest, cap at 10, skip empty/whitespace; Entry
// renders a single-line 40-char preview for the submenu label. Privacy is by
// construction — nothing here persists, so quit clears everything.

import XCTest
@testable import OLIV

final class TranscriptLogTests: XCTestCase {
    func testAddPrependsNewestFirst() {
        var log = TranscriptLog()
        log.add("หนึ่ง")
        log.add("สอง")
        XCTAssertEqual(log.entries.map(\.text), ["สอง", "หนึ่ง"])
    }

    func testAddIgnoresEmptyAndWhitespaceOnly() {
        var log = TranscriptLog()
        log.add("")
        log.add("   \n\t")
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testCapKeepsTenNewest() {
        var log = TranscriptLog()
        for i in 1...12 { log.add("t\(i)") }
        XCTAssertEqual(log.entries.count, 10)
        XCTAssertEqual(log.entries.first?.text, "t12")
        XCTAssertEqual(log.entries.last?.text, "t3")
    }

    func testPreviewShortTextUnchanged() {
        let entry = TranscriptLog.Entry(text: "สั้น ๆ พอ")
        XCTAssertEqual(entry.preview, "สั้น ๆ พอ")
    }

    func testPreviewTruncatesTo40CharsWithEllipsis() {
        let entry = TranscriptLog.Entry(text: String(repeating: "ก", count: 45))
        XCTAssertEqual(entry.preview, String(repeating: "ก", count: 40) + "…")
    }

    func testPreviewCollapsesNewlinesToOneLine() {
        // Format commands can put real line breaks in a transcript; a menu
        // label must stay one line.
        let entry = TranscriptLog.Entry(text: "บรรทัดแรก\nบรรทัดสอง")
        XCTAssertEqual(entry.preview, "บรรทัดแรก บรรทัดสอง")
    }
}
