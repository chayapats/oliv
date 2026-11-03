// Recent-transcripts history for the menu's "Recent…" submenu (0.1.5).
//
// Privacy by construction: a pure IN-MEMORY value type — nothing here touches
// disk, so quitting the app clears the history and nothing can leak into
// defaults/backups. Retention is deliberately tiny (10 entries): this is a
// "grab back what I just dictated" convenience, not a transcript archive.
// Each entry also carries what "Report a Wrong Result…" needs (raw transcript,
// engine, cleanup decision, timing) — still memory-only, gone on quit. Audio is
// never kept.

import Foundation

struct TranscriptLog {
    /// How one pasted result came about. Codes and timings from the provider,
    /// never its free-text error messages (they can echo private text).
    struct Details: Equatable {
        /// Speech-to-text output before cleanup and formatting.
        var raw: String
        /// The engine that actually answered (Groq's local fallback included).
        var engineID: String?
        /// Cleanup as resolved for this utterance: false for cleanup-off and
        /// verbatim apps.
        var cleanup: Bool
        var llmRan = false
        /// The cleanup gate's fixed code, e.g. "clean-thai" or "dict-hit".
        var gateReason = ""
        /// The guardrail's fixed code, e.g. "ok" or "tooLong->dict".
        var guardrailFlag = ""
        /// The language model failed and the transcript was kept.
        var cleanupFailed = false
        var sttSeconds: Double = 0
        var cleanupSeconds: Double = 0
        var audioSeconds: Double = 0
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let text: String
        let date: Date
        /// nil on the test-seam transcriber path, which has no pipeline result.
        let details: Details?

        init(id: UUID = UUID(), text: String, date: Date = Date(), details: Details? = nil) {
            self.id = id
            self.text = text
            self.date = date
            self.details = details
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
    mutating func add(_ text: String, details: Details? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(Entry(text: text, details: details), at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
    }
}
