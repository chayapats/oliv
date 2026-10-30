import XCTest
import UIKit

@MainActor
final class KeyboardCursorNavigationTests: XCTestCase {
    func testVerticalMovesKeepColumnAcrossShortAndEmptyLines() throws {
        var host = Host("abcdef\nx\n\nuvwxyz", caret: 5)
        var navigator = KeyboardCursorNavigation()
        XCTAssertEqual(try host.move(.down, using: &navigator), 3)
        XCTAssertEqual(host.before, "abcdef\nx")
        XCTAssertEqual(try host.move(.down, using: &navigator), 1)
        XCTAssertEqual(host.before, "abcdef\nx\n")
        XCTAssertEqual(try host.move(.down, using: &navigator), 6)
        XCTAssertEqual(host.before, "abcdef\nx\n\nuvwxy")
        XCTAssertEqual(try host.move(.up, using: &navigator), -6)
        XCTAssertEqual(try host.move(.up, using: &navigator), -1)
        XCTAssertEqual(try host.move(.up, using: &navigator), -3)
        XCTAssertEqual(host.caret, 5)
    }

    func testTopBottomAndTrailingEmptyLineStayWithinContext() throws {
        var host = Host("abc\n", caret: 2)
        var navigator = KeyboardCursorNavigation()
        XCTAssertNil(navigator.verticalOffset(.up, context: host.context))
        XCTAssertEqual(try host.move(.down, using: &navigator), 2)
        XCTAssertNil(navigator.verticalOffset(.down, context: host.context))
        XCTAssertEqual(try host.move(.up, using: &navigator), -2)
        XCTAssertEqual(host.caret, 2)
    }

    func testThaiAndJoinedEmojiUseWholeGraphemesButUTF16Offsets() throws {
        let family = "👨‍👩‍👧‍👦"
        let line = "ก้" + family + "ข"
        var host = Host(line + "\nABC", caret: 2)
        var navigator = KeyboardCursorNavigation()
        let source = host.before.utf16.count
        XCTAssertEqual(try host.move(.down, using: &navigator), line.utf16.count + 1 + 2 - source)
        XCTAssertEqual(host.before, line + "\nAB")
        XCTAssertEqual(try host.move(.up, using: &navigator), source - (line.utf16.count + 3))
        XCTAssertEqual(host.before, "ก้" + family)
    }

    func testCRLFRemainsOneGraphemeAndTwoOffsetUnits() throws {
        var host = Host("ab\r\ncd", caret: 1)
        var navigator = KeyboardCursorNavigation()
        XCTAssertEqual(try host.move(.down, using: &navigator), 4)
        XCTAssertEqual(host.before, "ab\r\nc")
        XCTAssertEqual(try host.move(.up, using: &navigator), -4)
    }

    func testMissingAndTruncatedContextsRejectUnknownColumnsAndEdges() {
        let id = UUID()
        var navigator = KeyboardCursorNavigation()
        XCTAssertNil(navigator.verticalOffset(.up, context: .init(documentID: id, before: nil, after: "one\ntwo")))
        XCTAssertNil(navigator.verticalOffset(.down, context: .init(documentID: id, before: "one\nt", after: nil)))
        XCTAssertEqual(navigator.verticalOffset(.up, context: .init(documentID: id, before: "one\nt", after: nil)), -4)
        navigator.reset()
        XCTAssertNil(navigator.verticalOffset(.up, context: .init(documentID: id, before: "partial\nx", after: "", beforeIsTruncated: true)))
        XCTAssertNil(navigator.verticalOffset(.down, context: .init(documentID: id, before: "abc", after: "\nx", afterIsTruncated: true)))
        XCTAssertEqual(navigator.verticalOffset(.up, context: .init(documentID: id, before: "partial\nabc\nd", after: "", beforeIsTruncated: true)), -4)
    }

    func testSelectionAndCaretInsideJoinedGraphemeCannotMove() {
        let id = UUID()
        var navigator = KeyboardCursorNavigation()
        XCTAssertNil(navigator.verticalOffset(.down, context: .init(documentID: id, before: "a", after: "\nb", selected: "a")))
        XCTAssertNil(navigator.verticalOffset(.down, context: .init(documentID: id, before: "a", after: "\u{301}\nb")))
        XCTAssertNil(navigator.verticalOffset(.up, context: .init(documentID: id, before: "ab\r", after: "\ncd")))
    }

    func testStaleHostContextDoesNotRepeatAndExternalCaretChangeResetsColumn() throws {
        var host = Host("abcdef\nx\nuvwxyz", caret: 5)
        var navigator = KeyboardCursorNavigation()
        let original = host.context
        XCTAssertEqual(try host.move(.down, using: &navigator), 3)
        XCTAssertNil(navigator.verticalOffset(.down, context: original))
        // A user now taps column zero rather than acknowledging the expected end.
        host.caret = 7
        XCTAssertEqual(try host.move(.down, using: &navigator), 2)
        XCTAssertEqual(host.before, "abcdef\nx\n")
    }

    func testNewDocumentAndExplicitResetLosePreferredColumn() throws {
        var host = Host("abcdef\nx\nuvwxyz", caret: 5)
        var navigator = KeyboardCursorNavigation()
        _ = try host.move(.down, using: &navigator)
        host.documentID = UUID()
        XCTAssertEqual(try host.move(.down, using: &navigator), 2)
        XCTAssertEqual(host.before, "abcdef\nx\nu")
        navigator.reset()
        XCTAssertEqual(try host.move(.up, using: &navigator), -2)
    }

    func testCoreTextWrapEstimatesSameColumnWithoutSplittingEmoji() throws {
        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let glyphWidth = ("a" as NSString).size(withAttributes: [.font: font]).width
        let layout = KeyboardCursorNavigation.Layout(estimatedLineWidth: glyphWidth * 4 + 0.1, font: font)
        var host = Host("abcdefghijkl", caret: 2)
        var navigator = KeyboardCursorNavigation()
        XCTAssertEqual(try host.move(.down, using: &navigator, layout: layout), 4)
        XCTAssertEqual(host.caret, 6)
        XCTAssertEqual(try host.move(.down, using: &navigator, layout: layout), 4)
        XCTAssertEqual(try host.move(.up, using: &navigator, layout: layout), -4)
        XCTAssertEqual(try host.move(.up, using: &navigator, layout: layout), -4)
        var emojiHost = Host("a👨‍👩‍👧‍👦bcd👨‍👩‍👧‍👦ef", caret: 1)
        navigator.reset()
        let offset = try emojiHost.move(.down, using: &navigator, layout: layout)
        XCTAssertGreaterThan(offset, 0)
        XCTAssertEqual(emojiHost.before + emojiHost.after, emojiHost.text)
    }

    func testInvalidEstimatedWidthFallsBackToHardLines() throws {
        for width in [CGFloat.zero, -1, .infinity, .nan] {
            var host = Host("ab\ncd", caret: 1)
            var navigator = KeyboardCursorNavigation()
            let layout = KeyboardCursorNavigation.Layout(estimatedLineWidth: width, font: .systemFont(ofSize: 17))
            XCTAssertEqual(try host.move(.down, using: &navigator, layout: layout), 3)
        }
    }

    func testUIKitTextPositionsCountUTF16InsteadOfSwiftCharacters() throws {
        let view = UITextView()
        view.text = "ก้👨‍👩‍👧‍👦a"
        let offset = "ก้👨‍👩‍👧‍👦".utf16.count
        let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: offset))
        XCTAssertEqual(view.offset(from: view.beginningOfDocument, to: position), offset)
        let range = try XCTUnwrap(view.textRange(from: view.beginningOfDocument, to: position))
        XCTAssertEqual(view.text(in: range), "ก้👨‍👩‍👧‍👦")
        XCTAssertNotEqual(offset, "ก้👨‍👩‍👧‍👦".count)
    }

    func testStagedCrossingRestoresColumnWithOnlyCurrentParagraphVisible() throws {
        var host = ParagraphHost("abcdefghij\nx\nabcdefghij", caret: 5)
        var navigator = KeyboardCursorNavigation()
        XCTAssertEqual(try host.move(.down, using: &navigator), [5, 1, 1])
        XCTAssertEqual(host.caret, 12)
        XCTAssertEqual(try host.move(.down, using: &navigator), [1, 5])
        XCTAssertEqual(host.caret, 18)
        XCTAssertEqual(try host.move(.up, using: &navigator), [-5, -1])
        XCTAssertEqual(host.caret, 12)
        XCTAssertEqual(try host.move(.up, using: &navigator), [-1, -1, -5])
        XCTAssertEqual(host.caret, 5)
    }

    func testIdenticalNonemptyParagraphsDoNotConfuseProbeAcknowledgement() throws {
        var host = ParagraphHost("qqqqqq\nqqqqqq\nqqqqqq", caret: 20)
        var navigator = KeyboardCursorNavigation()
        XCTAssertEqual(try host.move(.up, using: &navigator), [-6, -1])
        XCTAssertEqual(host.caret, 13)
        XCTAssertEqual(try host.move(.up, using: &navigator), [-6, -1])
        XCTAssertEqual(host.caret, 6)
        XCTAssertEqual(try host.move(.down, using: &navigator), [1, 6])
        XCTAssertEqual(host.caret, 13)
    }

    func testSettledClampedTopAndBottomRollBackToOriginalCaret() throws {
        for direction in [KeyboardCursorNavigation.Direction.up, .down] {
            var host = ParagraphHost("abcdef", caret: 3)
            var navigator = KeyboardCursorNavigation()
            XCTAssertEqual(try host.move(direction, using: &navigator, settleClamp: true),
                           direction == .up ? [-3, -1, 3] : [3, 1, -3])
            XCTAssertEqual(host.caret, 3)
        }
    }

    func testStagedThaiEmojiOffsetsAreUTF16AndGraphemeSafe() throws {
        var host = ParagraphHost("ก้👨‍👩‍👧‍👦x\nabcd", caret: 5)
        var navigator = KeyboardCursorNavigation()
        _ = try host.move(.up, using: &navigator)
        XCTAssertEqual(host.caret, 1)
        XCTAssertEqual(host.before, "ก้")
        _ = try host.move(.down, using: &navigator)
        XCTAssertEqual(host.caret, 5)
    }

    func testStagedWindowMoveAcknowledgesOnceAndRejectsDocumentChange() throws {
        var host = Host("abc\ndef", caret: 1)
        var navigator = KeyboardCursorNavigation()
        let initial = host.context
        XCTAssertEqual(navigator.beginVertical(.down, context: initial), .adjust(4))
        XCTAssertEqual(navigator.advance(context: initial), .wait)
        host.caret = 5
        XCTAssertEqual(navigator.advance(context: host.context), .completed)
        XCTAssertEqual(navigator.advance(context: host.context), .unavailable)
        XCTAssertEqual(navigator.beginVertical(.up, context: host.context), .adjust(-4))
        host.documentID = UUID()
        XCTAssertEqual(navigator.advance(context: host.context), .unavailable)
        XCTAssertEqual(navigator.timeout(context: host.context), .unavailable)
    }

    func testClippedAndUnacknowledgedBoundaryContextsNeverAuthorizeCorrection() {
        let id = UUID()
        var navigator = KeyboardCursorNavigation()
        XCTAssertEqual(navigator.beginVertical(.up, context: .init(documentID: id, before: "ab", after: nil,
                                                                  beforeIsTruncated: true)), .unavailable)
        let end = KeyboardCursorNavigation.Context(documentID: id, before: "abc", after: nil)
        XCTAssertEqual(navigator.beginVertical(.up, context: end), .adjust(-3))
        let start = KeyboardCursorNavigation.Context(documentID: id, before: nil, after: "abc")
        XCTAssertEqual(navigator.advance(context: start), .adjust(-1))
        XCTAssertEqual(navigator.advance(context: .init(documentID: id, before: nil, after: nil)), .completed)
        XCTAssertEqual(navigator.timeout(context: start), .unavailable)
        XCTAssertEqual(navigator.beginVertical(.up, context: end), .adjust(-3))
        XCTAssertEqual(navigator.timeout(context: end), .unavailable,
                       "A stale unacknowledged boundary move cannot authorize rollback")
    }

    func testBlankParagraphSequenceKeepsPreferredColumnInBothDirections() throws {
        var host = ParagraphHost("abcdef\n\n\nuvwxyz", caret: 5)
        var navigator = KeyboardCursorNavigation()
        XCTAssertEqual(try host.move(.down, using: &navigator, settleClamp: true), [1, 1])
        XCTAssertEqual(host.caret, 7)
        XCTAssertEqual(try host.move(.down, using: &navigator, settleClamp: true), [1])
        XCTAssertEqual(host.caret, 8)
        XCTAssertEqual(try host.move(.down, using: &navigator, settleClamp: true), [1, 5])
        XCTAssertEqual(host.caret, 14)
        XCTAssertEqual(try host.move(.up, using: &navigator, settleClamp: true), [-5, -1])
        XCTAssertEqual(host.caret, 8)
        XCTAssertEqual(try host.move(.up, using: &navigator, settleClamp: true), [-1])
        XCTAssertEqual(host.caret, 7)
        XCTAssertEqual(try host.move(.up, using: &navigator, settleClamp: true), [-1, -1])
        XCTAssertEqual(host.caret, 5)
    }

    func testEmptyDocumentIssuesOnlyOneProbePerRequestedMove() {
        let context = KeyboardCursorNavigation.Context(documentID: UUID(), before: nil, after: nil)
        var navigator = KeyboardCursorNavigation()
        for direction in [KeyboardCursorNavigation.Direction.up, .down] {
            XCTAssertEqual(navigator.beginVertical(direction, context: context), .adjust(direction == .up ? -1 : 1))
            XCTAssertEqual(navigator.advance(context: context), .wait)
            XCTAssertEqual(navigator.advance(context: context), .wait)
            XCTAssertEqual(navigator.beginVertical(direction, context: context), .wait)
            XCTAssertEqual(navigator.timeout(context: context), .completed)
            XCTAssertEqual(navigator.advance(context: context), .unavailable)
            XCTAssertEqual(navigator.timeout(context: context), .unavailable)
        }
    }

    func testEmptyParagraphProbeStillRejectsSelectionAndDocumentChanges() {
        let id = UUID()
        let empty = KeyboardCursorNavigation.Context(documentID: id, before: nil, after: nil)
        var navigator = KeyboardCursorNavigation()
        XCTAssertEqual(navigator.beginVertical(.down, context: empty), .adjust(1))
        XCTAssertEqual(navigator.advance(context: .init(documentID: UUID(), before: nil, after: nil)), .unavailable)
        XCTAssertEqual(navigator.beginVertical(.up, context: empty), .adjust(-1))
        XCTAssertEqual(navigator.timeout(context: .init(documentID: id, before: nil, after: nil, selected: "x")), .unavailable)
        XCTAssertEqual(navigator.beginVertical(.down, context: empty), .adjust(1))
        XCTAssertEqual(navigator.advance(context: .init(documentID: id, before: nil, after: "abc",
                                                       afterIsTruncated: true)), .unavailable)
    }
}

@MainActor
private struct Host {
    let text: String
    var caret: Int
    var documentID = UUID()
    init(_ text: String, caret: Int) { self.text = text; self.caret = caret }
    var split: String.Index { text.index(text.startIndex, offsetBy: caret) }
    var before: String { String(text[..<split]) }
    var after: String { String(text[split...]) }
    var context: KeyboardCursorNavigation.Context { .init(documentID: documentID, before: before, after: after) }

    mutating func move(_ direction: KeyboardCursorNavigation.Direction, using navigator: inout KeyboardCursorNavigation,
                       layout: KeyboardCursorNavigation.Layout? = nil) throws -> Int {
        let offset = try XCTUnwrap(navigator.verticalOffset(direction, context: context, layout: layout))
        let newOffset = before.utf16.count + offset
        let destination = String.Index(utf16Offset: newOffset, in: text)
        XCTAssertTrue(text.indices.contains(destination) || destination == text.endIndex)
        caret = text.distance(from: text.startIndex, to: destination)
        return offset
    }
}

/// Models UIKit's paragraph-only snapshots, with nil at paragraph edges.
@MainActor
private struct ParagraphHost {
    let text: String
    var caret: Int
    var documentID = UUID()
    init(_ text: String, caret: Int) { self.text = text; self.caret = caret }
    var split: String.Index { text.index(text.startIndex, offsetBy: caret) }
    var before: String { String(text[..<split]) }
    var context: KeyboardCursorNavigation.Context {
        let fullBefore = before
        let fullAfter = String(text[split...])
        let prefix = fullBefore.lastIndex(where: { $0.isNewline }).map {
            String(fullBefore[fullBefore.index(after: $0)...])
        } ?? fullBefore
        let suffix = String(fullAfter.prefix(while: { !$0.isNewline }))
        return .init(documentID: documentID, before: prefix.isEmpty ? nil : prefix,
                     after: suffix.isEmpty ? nil : suffix)
    }
    mutating func move(_ direction: KeyboardCursorNavigation.Direction, using navigator: inout KeyboardCursorNavigation,
                       settleClamp: Bool = false) throws -> [Int] {
        var step = navigator.beginVertical(direction, context: context)
        var adjustments: [Int] = []
        for _ in 0..<8 {
            switch step {
            case .adjust(let offset):
                adjustments.append(offset)
                let destinationUTF16 = min(text.utf16.count, max(0, before.utf16.count + offset))
                let destination = String.Index(utf16Offset: destinationUTF16, in: text)
                XCTAssertTrue(text.indices.contains(destination) || destination == text.endIndex)
                caret = text.distance(from: text.startIndex, to: destination)
                step = navigator.advance(context: context)
            case .wait:
                guard settleClamp else { XCTFail("Unexpected unacknowledged move"); return adjustments }
                step = navigator.timeout(context: context)
            case .completed: return adjustments
            case .unavailable: XCTFail("Unexpected rejected paragraph move"); return adjustments
            }
        }
        XCTFail("Paragraph move exceeded bounded adjustment count")
        return adjustments
    }
}
