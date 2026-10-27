// DictionaryEntry — the personal Dictionary (Wispr Flow parity).
//
// One entry is either vocabulary-only (word, correction == nil: bias STT
// recognition toward this spelling) or a correction pair (correction is what
// the user says / what STT mishears, word is what OLIV should type).
// Persisted as JSON under `oliv.dictionaryEntries` (see OLIVSettings) and
// synced with the OLIV server by `DictionarySync`. Matching happens in Rust
// (`oliv-text-core::user_dictionary`, shared with the server): local engines
// get the entries as the sidecar's `dictionary` array, the OLIV API applies
// its own synced copy.

import Foundation

/// Where a dictionary entry came from. `import` is a keyword — backticked.
enum DictionarySource: String, Codable, CaseIterable, Hashable, Sendable {
    case manual
    case `import`
    case autoLearn
}

struct DictionaryEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Stable across devices: new entries use a UUID string; entries created
    /// on other clients keep whatever id the server stored.
    var id: String
    /// The spelling OLIV should produce. 1…100 chars after trimming (over 60
    /// warns in the UI but still saves — Thai phrases run long).
    var word: String
    /// What the user says (or what STT mishears) that should become `word`.
    /// nil = vocabulary-only (recognition bias, no rewrite).
    var correction: String?
    var enabled: Bool = true
    /// Starred entries are sent FIRST in the STT prompt (Wispr parity) and are
    /// meant for the words that matter most.
    var starred: Bool = false
    var source: DictionarySource = .manual
    var usageCount: Int = 0

    init(id: String = UUID().uuidString, word: String, correction: String? = nil,
         enabled: Bool = true, starred: Bool = false,
         source: DictionarySource = .manual, usageCount: Int = 0) {
        self.id = id
        self.word = word
        self.correction = correction
        self.enabled = enabled
        self.starred = starred
        self.source = source
        self.usageCount = usageCount
    }

    // MARK: Limits (spec §3)

    /// Hard per-field cap. Longer input is rejected, never truncated silently.
    static let maxFieldLength = 100
    /// Soft cap: the UI warns past this but still saves (Thai phrases).
    static let warnFieldLength = 60
    /// CSV import caps.
    static let maxCSVRows = 1000
    static let maxCSVBytes = 3 * 1024 * 1024

    // MARK: Validation helpers (pure, unit-tested)

    static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the string carries at least one letter or digit (Thai
    /// included) — the same rule as Rust's `user_dictionary::clean_field`
    /// (`char::is_alphanumeric() || is_thai`), so nothing saved here is
    /// silently dropped by the matcher. Punctuation-, symbol-, emoji- and
    /// mark-only strings are rejected.
    static func hasWordContent(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || (0x0E00...0x0E7F).contains(scalar.value)
        }
    }

    /// Field length as Rust counts it (Unicode scalars, not grapheme
    /// clusters: a Thai syllable with a vowel and tone mark is 3).
    static func fieldLength(_ s: String) -> Int { s.unicodeScalars.count }

    static func isValidWord(_ word: String) -> Bool {
        let t = trimmed(word)
        return !t.isEmpty && fieldLength(t) <= maxFieldLength && hasWordContent(t)
    }

    /// nil (or blank, normalized to nil by callers) = vocabulary-only = valid.
    static func isValidCorrection(_ correction: String?) -> Bool {
        guard let c = correction else { return true }
        let t = trimmed(c)
        if t.isEmpty { return true }
        return fieldLength(t) <= maxFieldLength && hasWordContent(t)
    }

    var isValid: Bool {
        Self.isValidWord(word) && Self.isValidCorrection(correction)
    }

    /// Past the soft cap — the UI shows a "long, but will save" hint.
    var needsLengthWarning: Bool {
        Self.fieldLength(word) > Self.warnFieldLength
            || Self.fieldLength(correction ?? "") > Self.warnFieldLength
    }

    /// Dedupe key for a word, the same rule as the server
    /// (`user_dictionary::dedupe_key`): anything containing Thai compares
    /// exactly, everything else by full Unicode case folding (Straße and
    /// STRASSE are one word, as in Rust's `casefold`).
    static func dedupeKey(for word: String) -> String {
        let t = trimmed(word)
        let hasThai = t.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
        return hasThai ? t : t.folding(options: .caseInsensitive, locale: nil)
    }

    /// Full identity of an entry: word + correction (one correction per entry).
    /// Vocabulary-only entries key on the word alone.
    func dedupeKey() -> String {
        let w = Self.dedupeKey(for: word)
        guard let c = correction.map(Self.trimmed), !c.isEmpty else { return w + "\u{1F}" }
        return w + "\u{1F}" + Self.dedupeKey(for: c)
    }

    /// Normalized form (trimmed pair, blank correction → nil), or nil when the
    /// pair is invalid.
    static func normalized(word: String, correction: String?) -> (word: String, correction: String?)? {
        let w = trimmed(word)
        var c: String?
        if let raw = correction {
            let t = trimmed(raw)
            if !t.isEmpty { c = t }
        }
        guard isValidWord(w), isValidCorrection(c) else { return nil }
        return (w, c)
    }

    // MARK: Derivation for servers without dictionary sync

    /// Enabled words, starred first, each group in the user's stored order.
    /// Sent as request `vocabulary` only to servers that predate the dictionary.
    static func vocabulary(from entries: [DictionaryEntry]) -> [String] {
        let enabled = entries.filter(\.enabled)
        return enabled.filter(\.starred).map(\.word)
            + enabled.filter { !$0.starred }.map(\.word)
    }

    /// Enabled correction→word pairs; the first entry wins a duplicate spoken
    /// key. Sent as request `replacements` only to servers that predate the
    /// dictionary.
    static func replacements(from entries: [DictionaryEntry]) -> [String: String] {
        var out: [String: String] = [:]
        for e in entries where e.enabled {
            guard let raw = e.correction.map(trimmed), !raw.isEmpty else { continue }
            if out[raw] == nil { out[raw] = e.word }
        }
        return out
    }

    // MARK: Migration (legacy vocabulary + replacements → entries)

    /// Fold the pre-Dictionary stores into entries, preserving order:
    /// vocabulary terms first (word-only), then replacements (spoken→word
    /// becomes correction→word, sorted by spoken phrase for determinism). A
    /// replacement whose word matches an earlier word-only entry upgrades that
    /// entry (taking the replacement's spelling) instead of duplicating it.
    ///
    /// Snippets a dictionary entry cannot hold exactly — output over the
    /// field limit, without a letter or digit ("dash" → "—"), or with
    /// surrounding whitespace/newlines that trimming would change — are
    /// returned in `kept` unchanged; they keep working as the legacy
    /// replacement table (`OLIVSettings.legacySnippets`).
    static func migrate(vocabulary: [String],
                        replacements: [String: String])
        -> (entries: [DictionaryEntry], kept: [String: String]) {
        var kept: [String: String] = [:]
        var entries: [DictionaryEntry] = []
        var fullKeys = Set<String>()
        var wordOnlyIndex: [String: Int] = [:]  // word key → entries index (nil-correction only)
        for term in vocabulary {
            let t = trimmed(term)
            guard isValidWord(t) else { continue }
            let entry = DictionaryEntry(word: t, source: .manual)
            let full = entry.dedupeKey()
            guard fullKeys.insert(full).inserted else { continue }
            wordOnlyIndex[dedupeKey(for: t)] = entries.count
            entries.append(entry)
        }
        for spoken in replacements.keys.sorted() {
            guard let rep = replacements[spoken] else { continue }
            guard trimmed(rep) == rep, let pair = normalized(word: rep, correction: spoken) else {
                // 0.2.0 stored any non-blank spoken phrase + output verbatim.
                if !trimmed(spoken).isEmpty, !trimmed(rep).isEmpty { kept[spoken] = rep }
                continue
            }
            let candidate = DictionaryEntry(word: pair.word, correction: pair.correction,
                                            source: .manual)
            let full = candidate.dedupeKey()
            if fullKeys.contains(full) { continue }
            // Upgrade a word-only entry with the same word instead of doubling.
            if let idx = wordOnlyIndex[dedupeKey(for: pair.word)],
               entries[idx].correction == nil {
                entries[idx].word = pair.word
                entries[idx].correction = pair.correction
                fullKeys.insert(full)
                wordOnlyIndex.removeValue(forKey: dedupeKey(for: pair.word))
                continue
            }
            fullKeys.insert(full)
            entries.append(candidate)
        }
        return (entries, kept)
    }

    // MARK: CSV (word,correction header, ≤1000 rows)

    enum CSVError: Error, Equatable {
        case empty
        case badHeader
        case tooManyRows(limit: Int)
        case tooLarge(limit: Int)
    }

    /// Parse CSV text into entries (source: `.import`). Blank lines are
    /// ignored; invalid or duplicate rows are counted as skipped, not thrown.
    /// Throws on an empty file, a wrong header, >maxCSVRows data rows, or a
    /// file over maxCSVBytes.
    static func parseCSV(_ text: String) throws -> (entries: [DictionaryEntry], skipped: Int) {
        guard text.utf8.count <= maxCSVBytes else { throw CSVError.tooLarge(limit: maxCSVBytes) }
        // Records, not physical lines: a quoted field may span line breaks.
        // A blank record (an empty line) is ignored; an unterminated quote
        // makes the last record unparseable (skipped).
        var records = parseCSVRecords(text).filter { record in
            !(record.fields.count == 1 && trimmed(record.fields[0]).isEmpty && !record.quoted)
        }
        guard !records.isEmpty else { throw CSVError.empty }
        // Header is the first non-blank record.
        let header = records.removeFirst()
        let names = header.valid ? header.fields.map { trimmed($0).lowercased() } : []
        guard names.count >= 2, names[0] == "word", names[1] == "correction" else {
            throw CSVError.badHeader
        }
        guard records.count <= maxCSVRows else { throw CSVError.tooManyRows(limit: maxCSVRows) }
        var entries: [DictionaryEntry] = []
        var seen = Set<String>()
        var skipped = 0
        for record in records {
            let fields = record.valid ? record.fields : []
            guard !fields.isEmpty else { skipped += 1; continue }
            let word = trimmed(fields[0])
            let correction: String? = fields.count > 1 ? trimmed(fields[1]) : nil
            guard let pair = normalized(word: word,
                                        correction: (correction?.isEmpty ?? true) ? nil : correction)
            else { skipped += 1; continue }
            let entry = DictionaryEntry(word: pair.word, correction: pair.correction,
                                        source: .import)
            guard seen.insert(entry.dedupeKey()).inserted else { skipped += 1; continue }
            entries.append(entry)
        }
        return (entries, skipped)
    }

    /// Serialize entries to `word,correction` CSV (nil correction = empty field).
    static func serializeCSV(_ entries: [DictionaryEntry]) -> String {
        var out = "word,correction"
        for e in entries {
            out += "\n" + escapeCSVField(e.word) + "," + escapeCSVField(e.correction ?? "")
        }
        return out + "\n"
    }

    struct CSVRecord {
        var fields: [String]
        /// False when the text ended inside a quoted field.
        var valid: Bool
        /// Some field was quoted (`""` is a record, not a blank line).
        var quoted: Bool
    }

    /// RFC 4180 over the whole text: CRLF, LF or CR end a record unless
    /// inside quotes, where line breaks are part of the field.
    static func parseCSVRecords(_ text: String) -> [CSVRecord] {
        var records: [CSVRecord] = []
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var quoted = false
        var fieldStarted = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        func endRecord() {
            fields.append(current)
            records.append(CSVRecord(fields: fields, valid: true, quoted: quoted))
            fields = []; current = ""; quoted = false; fieldStarted = false
        }
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.unicodeScalars.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    current.unicodeScalars.append(ch)
                }
            } else if ch == "\"", !fieldStarted {
                inQuotes = true
                quoted = true
                fieldStarted = true
            } else if ch == "," {
                fields.append(current)
                current = ""
                fieldStarted = false
            } else if ch == "\r" || ch == "\n" {
                if ch == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endRecord()
            } else {
                current.unicodeScalars.append(ch)
                fieldStarted = true
            }
            i += 1
        }
        if inQuotes {
            fields.append(current)
            records.append(CSVRecord(fields: fields, valid: false, quoted: true))
        } else if fieldStarted || !fields.isEmpty || !current.isEmpty {
            endRecord()
        }
        return records
    }

    /// One RFC-4180 line: quotes double internal quotes; fields containing a
    /// comma, quote, or line break are wrapped in quotes.
    static func parseCSVLine(_ line: String) -> [String]? {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        i = line.index(after: next)
                    } else {
                        inQuotes = false
                        i = line.index(after: i)
                    }
                } else {
                    current.append(ch)
                    i = line.index(after: i)
                }
            } else if ch == "\"", current.isEmpty {
                inQuotes = true
                i = line.index(after: i)
            } else if ch == "," {
                fields.append(current)
                current = ""
                i = line.index(after: i)
            } else {
                current.append(ch)
                i = line.index(after: i)
            }
        }
        if inQuotes { return nil }
        fields.append(current)
        return fields
    }

    static func escapeCSVField(_ field: String) -> String {
        // By scalar: "\r\n" is ONE Character, so `contains("\n")` misses it.
        if field.unicodeScalars.contains(where: { [",", "\"", "\n", "\r"].contains($0) }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
