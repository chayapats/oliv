// Recent-transcripts history for the menu's "Recent…" submenu (0.1.5).
//
// Privacy by construction: a pure IN-MEMORY value type — nothing here touches
// disk, so quitting the app clears the history and nothing can leak into
// defaults/backups. Retention is deliberately tiny (10 entries): this is a
// "grab back what I just dictated" convenience, not a transcript archive.

import Foundation

struct TranscriptLog {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let text: String
        let date: Date

        init(id: UUID = UUID(), text: String, date: Date = Date()) {
            self.id = id
            self.text = text
            self.date = date
        }

        /// Single-line menu label: newlines collapsed (format commands can put
        /// real breaks in a transcript), then hard-capped at 40 characters with
        /// an ellipsis. The full text still copies via the entry itself.
        var preview: String {
            let oneLine = text.split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard oneLine.count > 40 else { return oneLine }
            return oneLine.prefix(40) + "…"
        }
    }

    /// Newest first; the retention ceiling below trims the oldest.
    private(set) var entries: [Entry] = []

    static let cap = 10

    /// Prepend one dictated transcript. Empty/whitespace-only text is skipped
    /// (a no-speech utterance is not history), but stored text keeps its
    /// original form — copy must return exactly what pasted.
    mutating func add(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(Entry(text: text), at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
    }
}
