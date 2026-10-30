import UIKit
import CoreText

/// Vertical movement using only the text visible to UITextDocumentProxy.
/// Hard line columns are grapheme counts. Optional wrapping estimates visual
/// columns with public CoreText metrics; host font, insets, bidi layout and
/// caret affinity are unavailable to a keyboard, so that mode is approximate.
@MainActor
struct KeyboardCursorNavigation {
    enum Direction { case up, down }
    enum Step: Equatable { case adjust(Int), wait, completed, unavailable }

    struct Context {
        let documentID: UUID
        let before: String?
        let after: String?
        let selected: String?
        /// A caller that knows it cut a context window can reject destinations
        /// whose columns depend on that missing edge. The proxy itself exposes
        /// no completeness flag, so ordinary contexts use their available bounds.
        var beforeIsTruncated = false
        var afterIsTruncated = false

        init(documentID: UUID, before: String?, after: String?, selected: String? = nil,
             beforeIsTruncated: Bool = false, afterIsTruncated: Bool = false) {
            self.documentID = documentID
            self.before = before
            self.after = after
            self.selected = selected
            self.beforeIsTruncated = beforeIsTruncated
            self.afterIsTruncated = afterIsTruncated
        }
    }

    struct Layout {
        let estimatedLineWidth: CGFloat
        let font: UIFont
    }

    private enum Column { case grapheme(Int), visual(CGFloat) }
    private struct Row {
        let start: Int
        let end: Int
        let line: CTLine?
        let lineUTF16Start: Int
    }
    private var preferredColumn: Column?
    private var pendingSource: Context?
    private var expectedContext: Context?
    private enum Phase {
        case window(source: Context, expected: Context)
        case boundary(source: Context)
        case probe(boundary: Context)
        case target(source: Context, expected: Context)
        case restore(source: Context, expected: Context)
    }
    private struct Journey {
        let direction: Direction
        let source: Context
        let paragraph: String
        let prefixUTF16: Int
        let suffixUTF16: Int
        let column: Column
        let layout: Layout?
        var phase: Phase
    }
    private var journey: Journey?

    /// Call on gesture end, horizontal motion or an edit. Unexpected context or
    /// document changes also reset the preference; an unacknowledged movement
    /// returns nil instead of issuing the same adjustment twice.
    mutating func reset() {
        preferredColumn = nil
        pendingSource = nil
        expectedContext = nil
        journey = nil
    }

    /// One requested vertical move. UIKit commonly exposes only the current
    /// paragraph. At a visible row edge this stages a paragraph-boundary move,
    /// a one-unit separator probe, then a column adjustment in fresh context.
    /// There is at most one outstanding host adjustment. The caller polls
    /// advance and owns a short acknowledgement deadline (for example 60 ms).
    /// Crossing assumes the visible context reaches a paragraph boundary; the
    /// one-unit probe assumes an LF separator. The public proxy cannot prove
    /// those assumptions for clipped host windows or an unobserved CRLF. Only
    /// destinations computed from visible text can guarantee grapheme safety.
    mutating func beginVertical(_ direction: Direction, context: Context,
                                layout: Layout? = nil) -> Step {
        guard journey == nil else { return .wait }
        guard context.selected?.isEmpty != false else { reset(); return .unavailable }
        if let expectedContext, !equivalent(context, expectedContext) { reset() }
        if context.before != nil, direction == .up || context.after != nil,
           let offset = verticalOffset(direction, context: context, layout: layout), let expectedContext {
            let paragraph = paragraphParts(context)
            journey = Journey(direction: direction, source: context, paragraph: paragraph.text,
                              prefixUTF16: paragraph.prefix.utf16.count, suffixUTF16: paragraph.suffix.utf16.count,
                              column: preferredColumn ?? .grapheme(paragraph.prefix.count), layout: layout,
                              phase: .window(source: context, expected: expectedContext))
            return .adjust(offset)
        }
        guard !context.beforeIsTruncated, !context.afterIsTruncated else { reset(); return .unavailable }
        let parts = paragraphParts(context)
        let validLayout = usable(layout)
        if parts.text.isEmpty {
            // Both nil can mean an empty paragraph or unavailable context. One
            // user-requested LF probe also clamps safely at an empty document
            // edge. Identical empty neighbors cannot acknowledge it, so the
            // deadline completes that single probe without replay or rollback.
            journey = Journey(direction: direction, source: context, paragraph: "", prefixUTF16: 0,
                              suffixUTF16: 0, column: preferredColumn ?? (validLayout == nil ? .grapheme(0) : .visual(0)),
                              layout: validLayout, phase: .probe(boundary: context))
            return .adjust(direction == .up ? -1 : 1)
        }
        let characters = Array(parts.text)
        let offsets = utf16Offsets(characters)
        guard let caret = offsets.firstIndex(of: parts.prefix.utf16.count) else { reset(); return .unavailable }
        let rows = makeRows(characters, utf16: offsets, layout: validLayout)
        guard let row = rows.last(where: { $0.start <= caret }) else { return .unavailable }
        let column: Column
        switch (preferredColumn, validLayout) {
        case (.some(.grapheme(let value)), .none): column = .grapheme(value)
        case (.some(.visual(let value)), .some): column = .visual(value)
        default:
            column = row.line.map { .visual(CGFloat(CTLineGetOffsetForStringIndex(
                $0, offsets[caret] - row.lineUTF16Start, nil))) } ?? .grapheme(caret - row.start)
        }
        let boundaryOffset = direction == .up ? -parts.prefix.utf16.count : parts.suffix.utf16.count
        journey = Journey(direction: direction, source: context, paragraph: parts.text,
                          prefixUTF16: parts.prefix.utf16.count, suffixUTF16: parts.suffix.utf16.count,
                          column: column, layout: validLayout,
                          phase: boundaryOffset == 0 ? .probe(boundary: context) : .boundary(source: context))
        return .adjust(boundaryOffset == 0 ? (direction == .up ? -1 : 1) : boundaryOffset)
    }

    /// Continue only after reading a new proxy snapshot. An unchanged snapshot
    /// waits; it never authorizes another separator probe or duplicate move.
    mutating func advance(context: Context) -> Step {
        guard var active = journey else { return .unavailable }
        guard context.documentID == active.source.documentID,
              context.selected?.isEmpty != false,
              context.beforeIsTruncated == active.source.beforeIsTruncated,
              context.afterIsTruncated == active.source.afterIsTruncated else { reset(); return .unavailable }
        switch active.phase {
        case .window(let source, let expected), .target(let source, let expected), .restore(let source, let expected):
            if equivalent(context, expected) { return finish(context: context, column: active.column) }
            if equivalent(context, source) { return .wait }
            reset()
            return .unavailable
        case .boundary(let source):
            if equivalent(context, source) { return .wait }
            let parts = paragraphParts(context)
            guard sameScalars(parts.text, active.paragraph),
                  active.direction == .up ? parts.prefix.isEmpty : parts.suffix.isEmpty else {
                reset(); return .unavailable
            }
            active.phase = .probe(boundary: context)
            journey = active
            return .adjust(active.direction == .up ? -1 : 1)
        case .probe(let boundary):
            if equivalent(context, boundary) { return .wait }
            let parts = paragraphParts(context)
            if parts.text.isEmpty { return finish(context: context, column: active.column) }
            guard active.direction == .up ? parts.suffix.isEmpty : parts.prefix.isEmpty else {
                // A clipped neighboring paragraph cannot prove where
                // this one-unit probe landed. Do not issue a guessed correction.
                reset(); return .unavailable
            }
            let characters = Array(parts.text)
            let offsets = utf16Offsets(characters)
            let rows = makeRows(characters, utf16: offsets, layout: active.layout)
            let rowIndex = active.direction == .up ? rows.count - 1 : 0
            let target = targetIndex(in: rows, rowIndex: rowIndex, column: active.column, utf16: offsets)
            let adjustment = offsets[target] - parts.prefix.utf16.count
            guard adjustment != 0 else { return finish(context: context, column: active.column) }
            guard let expected = relocated(context, by: adjustment) else { reset(); return .unavailable }
            active.phase = .target(source: context, expected: expected)
            journey = active
            return .adjust(adjustment)
        }
    }

    /// Called once when the caller's acknowledgement deadline expires. A
    /// settled snapshot still at the known source paragraph boundary permits a
    /// compensating move back to the original column. No rollback is attempted
    /// after a changed/unknown snapshot or an unacknowledged boundary move.
    /// This is a pragmatic UIKit settling rule, not proof of remote completion:
    /// an arbitrary host may delay context longer than the caller's deadline.
    mutating func timeout(context: Context) -> Step {
        guard var active = journey, context.documentID == active.source.documentID,
              context.selected?.isEmpty != false else { reset(); return .unavailable }
        guard case .probe(let boundary) = active.phase,
              equivalent(context, boundary), sameScalars(paragraphParts(context).text, active.paragraph) else {
            reset(); return .unavailable
        }
        let rollback = active.direction == .up ? active.prefixUTF16 : -active.suffixUTF16
        guard rollback != 0 else { return finish(context: context, column: active.column) }
        guard let expected = relocated(context, by: rollback) else { reset(); return .unavailable }
        active.phase = .restore(source: context, expected: expected)
        journey = active
        return .adjust(rollback)
    }

    /// Returns a UTF-16 delta suitable for adjustTextPosition(byCharacterOffset:).
    /// Apple documents UITextInput offsets in UTF-16 units, while the proxy's
    /// method describes them only as "characters":
    /// https://developer.apple.com/documentation/uikit/uitextinput/offset(from:to:)
    /// Destinations are always extended-grapheme boundaries, never code-unit cuts.
    mutating func verticalOffset(_ direction: Direction, context: Context,
                                 layout: Layout? = nil) -> Int? {
        guard context.selected?.isEmpty != false, let before = context.before,
              direction == .up || context.after != nil else { reset(); return nil }
        if let source = pendingSource, same(context, source) { return nil }
        if let expected = expectedContext, !same(context, expected) { reset() }

        let text = before + (context.after ?? "")
        let characters = Array(text)
        var utf16 = [0]
        for character in characters {
            utf16.append(utf16.last! + String(character).utf16.count)
        }
        // Joining contexts can expose a caret within a combined grapheme (or
        // CRLF). Such a host position has no safe Swift grapheme destination.
        guard let caret = utf16.firstIndex(of: before.utf16.count) else { reset(); return nil }
        let validLayout = layout.flatMap {
            $0.estimatedLineWidth.isFinite && $0.estimatedLineWidth > 0 ? $0 : nil
        }
        let rows = makeRows(characters, utf16: utf16, layout: validLayout)
        guard let current = rows.lastIndex(where: { $0.start <= caret }) else { return nil }
        let destination = direction == .up ? current - 1 : current + 1
        guard rows.indices.contains(destination) else { return nil }
        // Missing prefix makes the column of its first visible row unknown.
        guard !context.beforeIsTruncated || (current > 0 && destination > 0) else { return nil }
        let sourceRow = rows[current]
        let column: Column
        switch (preferredColumn, validLayout) {
        case (.some(.grapheme(let value)), .none): column = .grapheme(value)
        case (.some(.visual(let value)), .some): column = .visual(value)
        default:
            if let line = sourceRow.line {
                column = .visual(CGFloat(CTLineGetOffsetForStringIndex(
                    line, utf16[caret] - sourceRow.lineUTF16Start, nil)))
            } else {
                column = .grapheme(caret - sourceRow.start)
            }
        }
        let target = rows[destination]
        // A soft-wrap boundary has two visual affinities, but the proxy cannot
        // choose one. Keep the target before that shared boundary so the next
        // snapshot still identifies the intended visual row.
        let targetEnd = destination + 1 < rows.count && rows[destination + 1].start == target.end
            ? max(target.start, target.end - 1) : target.end
        let index: Int
        switch column {
        case .grapheme(let column):
            if destination == rows.count - 1, context.afterIsTruncated,
               column > targetEnd - target.start { return nil }
            index = min(targetEnd, target.start + column)
        case .visual(let x):
            guard let line = target.line else { return nil }
            if destination == rows.count - 1, context.afterIsTruncated,
               x > CGFloat(CTLineGetOffsetForStringIndex(line, utf16[targetEnd] - target.lineUTF16Start, nil)) {
                return nil
            }
            index = (target.start...targetEnd).min { lhs, rhs in
                let left = CGFloat(CTLineGetOffsetForStringIndex(line, utf16[lhs] - target.lineUTF16Start, nil))
                let right = CGFloat(CTLineGetOffsetForStringIndex(line, utf16[rhs] - target.lineUTF16Start, nil))
                return abs(left - x) < abs(right - x)
            } ?? target.start
        }
        let offset = utf16[index] - utf16[caret]
        guard offset != 0 else { return nil }
        let split = text.index(text.startIndex, offsetBy: index)
        preferredColumn = column
        pendingSource = context
        expectedContext = Context(documentID: context.documentID, before: String(text[..<split]),
                                  after: text[split...].isEmpty && context.after == nil ? nil : String(text[split...]),
                                  selected: context.selected,
                                  beforeIsTruncated: context.beforeIsTruncated,
                                  afterIsTruncated: context.afterIsTruncated)
        return offset
    }

    private mutating func finish(context: Context, column: Column) -> Step {
        journey = nil
        pendingSource = nil
        expectedContext = context
        preferredColumn = column
        return .completed
    }

    private func usable(_ layout: Layout?) -> Layout? {
        layout.flatMap { $0.estimatedLineWidth.isFinite && $0.estimatedLineWidth > 0 ? $0 : nil }
    }

    private func utf16Offsets(_ characters: [Character]) -> [Int] {
        var offsets = [0]
        for character in characters { offsets.append(offsets.last! + String(character).utf16.count) }
        return offsets
    }

    private func paragraphParts(_ context: Context) -> (prefix: String, suffix: String, text: String) {
        let before = context.before ?? ""
        let after = context.after ?? ""
        let prefix = before.lastIndex(where: { $0.isNewline }).map {
            String(before[before.index(after: $0)...])
        } ?? before
        let suffix = String(after.prefix(while: { !$0.isNewline }))
        return (prefix, suffix, prefix + suffix)
    }

    private func sameScalars(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    private func equivalent(_ lhs: Context, _ rhs: Context) -> Bool {
        lhs.documentID == rhs.documentID && sameScalars(lhs.before ?? "", rhs.before ?? "")
            && sameScalars(lhs.after ?? "", rhs.after ?? "")
            && sameScalars(lhs.selected ?? "", rhs.selected ?? "")
            && lhs.beforeIsTruncated == rhs.beforeIsTruncated && lhs.afterIsTruncated == rhs.afterIsTruncated
    }

    private func relocated(_ context: Context, by offset: Int) -> Context? {
        let before = context.before ?? ""
        let text = before + (context.after ?? "")
        let characters = Array(text)
        let offsets = utf16Offsets(characters)
        guard offsets.contains(before.utf16.count),
              let target = offsets.firstIndex(of: before.utf16.count + offset) else { return nil }
        let split = text.index(text.startIndex, offsetBy: target)
        return Context(documentID: context.documentID, before: String(text[..<split]),
                       after: text[split...].isEmpty && context.after == nil ? nil : String(text[split...]),
                       selected: context.selected, beforeIsTruncated: context.beforeIsTruncated,
                       afterIsTruncated: context.afterIsTruncated)
    }

    private func targetIndex(in rows: [Row], rowIndex: Int, column: Column, utf16: [Int]) -> Int {
        let row = rows[rowIndex]
        let end = rowIndex + 1 < rows.count && rows[rowIndex + 1].start == row.end
            ? max(row.start, row.end - 1) : row.end
        switch column {
        case .grapheme(let column): return min(end, row.start + column)
        case .visual(let x):
            guard let line = row.line else { return row.start }
            return (row.start...end).min {
                let left = CGFloat(CTLineGetOffsetForStringIndex(line, utf16[$0] - row.lineUTF16Start, nil))
                let right = CGFloat(CTLineGetOffsetForStringIndex(line, utf16[$1] - row.lineUTF16Start, nil))
                return abs(left - x) < abs(right - x)
            } ?? row.start
        }
    }

    private func same(_ lhs: Context, _ rhs: Context) -> Bool {
        func equal(_ left: String?, _ right: String?) -> Bool {
            switch (left, right) {
            case (nil, nil): true
            case (.some(let left), .some(let right)): left.unicodeScalars.elementsEqual(right.unicodeScalars)
            default: false
            }
        }
        return lhs.documentID == rhs.documentID && equal(lhs.before, rhs.before)
            && equal(lhs.after, rhs.after) && equal(lhs.selected, rhs.selected)
            && lhs.beforeIsTruncated == rhs.beforeIsTruncated && lhs.afterIsTruncated == rhs.afterIsTruncated
    }

    private func makeRows(_ characters: [Character], utf16: [Int], layout: Layout?) -> [Row] {
        var rows: [Row] = []
        var start = 0
        for end in 0...characters.count where end == characters.count || characters[end].isNewline {
            guard let layout else {
                rows.append(Row(start: start, end: end, line: nil, lineUTF16Start: utf16[start]))
                start = end + 1
                continue
            }
            let paragraph = String(characters[start..<end])
            let attributed = NSAttributedString(string: paragraph, attributes: [.font: layout.font])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let paragraphStart = utf16[start]
            if start == end {
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))
                rows.append(Row(start: start, end: end, line: line, lineUTF16Start: paragraphStart))
            }
            var rowStart = start
            while rowStart < end {
                let localStart = utf16[rowStart] - paragraphStart
                let count = CTTypesetterSuggestLineBreak(typesetter, localStart, Double(layout.estimatedLineWidth))
                let suggested = paragraphStart + localStart + max(1, count)
                // CoreText ranges are UTF-16; snap back to a full grapheme. If
                // one grapheme exceeds the width it occupies a row on its own.
                let rowEnd = (rowStart + 1...end).last(where: { utf16[$0] <= suggested }) ?? rowStart + 1
                let range = CFRange(location: localStart, length: utf16[rowEnd] - utf16[rowStart])
                let line = CTTypesetterCreateLine(typesetter, range)
                rows.append(Row(start: rowStart, end: rowEnd, line: line, lineUTF16Start: paragraphStart))
                rowStart = rowEnd
            }
            start = end + 1
        }
        return rows
    }
}
