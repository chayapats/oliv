import Foundation

/// One personal Dictionary entry, shared with the OLIV server and the user's
/// other devices (server/docs/DICTIONARY.md). `correction == nil` is a
/// vocabulary word (recognition bias); otherwise what is heard becomes `word`.
public struct DictionaryEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case manual, `import`, autoLearn }

    /// Stable across devices: UUID strings here; other clients' ids are kept.
    public var id: String
    public var word: String
    public var correction: String?
    public var enabled: Bool
    public var starred: Bool
    public var source: Source

    public init(id: String = UUID().uuidString, word: String, correction: String? = nil,
                enabled: Bool = true, starred: Bool = false, source: Source = .manual) {
        self.id = id
        self.word = word
        self.correction = correction
        self.enabled = enabled
        self.starred = starred
        self.source = source
    }

    /// The server's field limit (`user_dictionary::MAX_FIELD_CHARS`).
    public static let maxFieldLength = 100

    /// The trimmed field when the server would accept it: 1…100 Unicode scalars
    /// (Rust `chars`) with at least one letter, digit or Thai character. One
    /// field it refuses would fail the whole request, every time.
    public static func clean(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.unicodeScalars.count <= maxFieldLength,
              t.unicodeScalars.contains(where: {
                  $0.properties.isAlphabetic || $0.properties.numericType != nil
                      || (0x0E00...0x0E7F).contains($0.value)
              }) else { return nil }
        return t
    }

    /// Same rule as the server: anything containing Thai compares exactly,
    /// everything else case-insensitively.
    public static func dedupeKey(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.unicodeScalars.contains(where: { (0x0E00...0x0E7F).contains($0.value) }) ? t : t.lowercased()
    }

    /// Word + correction identity (one entry per pair).
    public var identity: String {
        Self.dedupeKey(word) + "\u{1F}" + (correction.map(Self.dedupeKey) ?? "")
    }
}

/// One change to send to the server.
public enum DictionaryOp: Codable, Equatable, Sendable {
    case upsert(DictionaryEntry)
    case delete(id: String)

    public var entryID: String {
        switch self {
        case .upsert(let entry): entry.id
        case .delete(let id): id
        }
    }

    /// The operations that turn `old` into `new`, compared by id.
    public static func diff(from old: [DictionaryEntry], to new: [DictionaryEntry]) -> [DictionaryOp] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        return new.compactMap { before[$0.id] == $0 ? nil : .upsert($0) }
            + old.filter { !after.contains($0.id) }.map { .delete(id: $0.id) }
    }

    /// Keep only the last operation per entry, in the order of last change.
    public static func compact(_ ops: [DictionaryOp]) -> [DictionaryOp] {
        var seen = Set<String>()
        return ops.reversed().filter { seen.insert($0.entryID).inserted }.reversed()
    }

    public static func apply(_ ops: [DictionaryOp], to entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var out = entries
        for op in ops {
            switch op {
            case .upsert(let entry):
                if let i = out.firstIndex(where: { $0.id == entry.id }) { out[i] = entry } else { out.append(entry) }
            case .delete(let id):
                out.removeAll { $0.id == id }
            }
        }
        return out
    }
}

/// The server's copy of the dictionary.
public struct DictionarySnapshot: Decodable, Equatable, Sendable {
    public struct Rejection: Decodable, Equatable, Sendable {
        public let id: String
        /// `duplicate` or `limit`.
        public let reason: String
        public init(id: String, reason: String) { self.id = id; self.reason = reason }
    }

    public let revision: Int
    public let maxEntries: Int?
    public let entries: [DictionaryEntry]
    public let rejected: [Rejection]

    public init(revision: Int, maxEntries: Int? = nil, entries: [DictionaryEntry], rejected: [Rejection] = []) {
        self.revision = revision
        self.maxEntries = maxEntries
        self.entries = entries
        self.rejected = rejected
    }

    enum CodingKeys: String, CodingKey { case revision, entries, rejected, maxEntries = "max_entries" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int.self, forKey: .revision)
        guard revision >= 0 else { throw OlivError.invalidResponse }
        maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries)
        entries = try c.decode([WireEntry].self, forKey: .entries).map(\.entry)
        rejected = try c.decodeIfPresent([Rejection].self, forKey: .rejected) ?? []
    }

    /// The server's entry shape; unknown sources fall back to manual.
    private struct WireEntry: Decodable {
        let id: String
        let word: String
        let correction: String?
        let enabled: Bool?
        let starred: Bool?
        let source: String?
        var entry: DictionaryEntry {
            DictionaryEntry(id: id, word: word, correction: correction, enabled: enabled ?? true,
                            starred: starred ?? false,
                            source: source.flatMap(DictionaryEntry.Source.init) ?? .manual)
        }
    }
}

/// The local Dictionary plus what syncing it needs, persisted as one document.
/// Pure: the app performs the network exchange between `outgoing()` and
/// `acknowledge(_:)` (see server/docs/DICTIONARY.md, "client sync").
public struct DictionaryBook: Codable, Equatable, Sendable {
    public private(set) var entries: [DictionaryEntry] = []
    /// Last server revision seen.
    public private(set) var revision = 0
    /// Local changes the server has not confirmed yet.
    public private(set) var pending: [DictionaryOp] = []
    /// This device's entries were merged into the server once.
    public private(set) var uploadedLocal = false
    /// nil until the server answered once; false for servers without sync.
    public private(set) var serverSupportsDictionary: Bool?
    /// Old settings a Dictionary entry can't hold (rules that delete a phrase
    /// or write only symbols, over-long lines). Stay on this iPhone and go
    /// with every request, as they always did.
    public private(set) var olderVocabulary: [String] = []
    public private(set) var olderRules: [ReplacementRule] = []
    /// The first `inFlight` pending ops are in the request being sent; they
    /// are never compacted until it answers. Not persisted.
    private var inFlight = 0

    enum CodingKeys: String, CodingKey {
        case entries, revision, pending, uploadedLocal, serverSupportsDictionary, olderVocabulary, olderRules
    }

    /// The server's `MAX_ENTRIES` and `MAX_OPS`.
    public static let maxEntries = 1_000
    public static let maxOpsPerRequest = 1_000

    public init(entries: [DictionaryEntry] = [], olderVocabulary: [String] = [],
                olderRules: [ReplacementRule] = []) {
        self.entries = entries
        self.olderVocabulary = olderVocabulary
        self.olderRules = olderRules
    }

    /// The server applies its own copy, so dictation can leave the request's
    /// vocabulary/replacements out.
    public var serverAppliesDictionary: Bool { serverSupportsDictionary == true }

    /// Replace the list with an edited version and queue the difference.
    public mutating func edit(_ newEntries: [DictionaryEntry]) {
        let ops = DictionaryOp.diff(from: entries, to: newEntries)
        entries = newEntries
        guard !ops.isEmpty else { return }
        pending = Array(pending.prefix(inFlight)) + DictionaryOp.compact(pending.dropFirst(inFlight) + ops)
    }

    /// The operations for the next request (nil = just fetch), at most what
    /// the server takes at once. The first sync also uploads this device's
    /// entries; they queue like any edit, so they survive a failed attempt.
    public mutating func outgoing() -> [DictionaryOp]? {
        if !uploadedLocal {
            pending = entries.map(DictionaryOp.upsert) + pending
            uploadedLocal = true
        }
        pending = DictionaryOp.compact(pending)
        inFlight = min(pending.count, Self.maxOpsPerRequest)
        return inFlight == 0 ? nil : Array(pending.prefix(inFlight))
    }

    /// The server answered `outgoing()`. Edits made meanwhile stay queued and
    /// are replayed on top of the server copy.
    public mutating func acknowledge(_ snapshot: DictionarySnapshot) {
        pending.removeFirst(min(inFlight, pending.count))
        inFlight = 0
        revision = snapshot.revision
        serverSupportsDictionary = true
        entries = DictionaryOp.apply(pending, to: snapshot.entries)
    }

    /// The exchange failed; everything stays queued for the next attempt.
    public mutating func exchangeFailed() { inFlight = 0 }

    /// The server predates dictionary sync: keep the list local. A later
    /// upgrade starts again with a full upload.
    public mutating func serverUnsupported() {
        inFlight = 0
        pending = []
        uploadedLocal = false
        serverSupportsDictionary = false
    }

    /// The connection now leads to another server or profile, which knows
    /// nothing of this device: start over with a full upload.
    public mutating func connectionChanged() {
        inFlight = 0
        pending = []
        revision = 0
        uploadedLocal = false
        serverSupportsDictionary = nil
    }

    public mutating func removeOlderVocabulary(_ line: String) { olderVocabulary.removeAll { $0 == line } }

    public mutating func removeOlderRule(spoken: String) { olderRules.removeAll { $0.spoken == spoken } }

    /// `vocabulary` for a request: the older lines, plus the Dictionary when
    /// the server can't apply it. Kept within the request limits, which the
    /// Dictionary is larger than, so a long list can never block dictation.
    public var requestVocabulary: [String] {
        var seen = Set<String>()
        let words = olderVocabulary + (serverAppliesDictionary ? [] : derivedVocabulary)
        return Array(words.filter { $0.utf8.count <= OlivOptions.maximumEntryBytes && seen.insert($0).inserted }
            .prefix(OlivOptions.maximumEntries))
    }

    /// `replacements` for a request, likewise.
    public var requestReplacements: [ReplacementRule] {
        var seen = Set<String>()
        let limit = OlivOptions.maximumEntryBytes
        let rules = olderRules + (serverAppliesDictionary ? [] : derivedReplacements)
        return Array(rules.filter {
            $0.spoken.utf8.count <= limit && $0.written.utf8.count <= limit && seen.insert($0.spoken).inserted
        }.prefix(OlivOptions.maximumEntries))
    }

    /// Request vocabulary for servers without sync: enabled words, starred first.
    public var derivedVocabulary: [String] {
        let enabled = entries.filter(\.enabled)
        return enabled.filter(\.starred).map(\.word) + enabled.filter { !$0.starred }.map(\.word)
    }

    /// Request replacements for servers without sync: enabled corrections in
    /// list order, the first entry owning a spoken phrase.
    public var derivedReplacements: [ReplacementRule] {
        var seen = Set<String>()
        return entries.compactMap { e in
            guard e.enabled, let heard = e.correction, seen.insert(heard).inserted else { return nil }
            return ReplacementRule(spoken: heard, written: e.word)
        }
    }

    /// Fold the pre-Dictionary settings (newline-separated vocabulary and
    /// ordered replacement rules) into entries, deduplicated. Anything an
    /// entry can't hold stays as it was, so an upgrade loses nothing.
    public static func migrate(vocabularyText: String, replacements: [ReplacementRule]) -> DictionaryBook {
        var entries: [DictionaryEntry] = []
        var olderVocabulary: [String] = []
        var olderRules: [ReplacementRule] = []
        var identities = Set<String>()
        func add(_ entry: DictionaryEntry) {
            if identities.insert(entry.identity).inserted { entries.append(entry) }
        }
        for line in vocabularyText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let word = DictionaryEntry.clean(trimmed) { add(DictionaryEntry(word: word)) }
            else if !trimmed.isEmpty, !olderVocabulary.contains(trimmed) { olderVocabulary.append(trimmed) }
        }
        for rule in replacements {
            if let word = DictionaryEntry.clean(rule.written), let heard = DictionaryEntry.clean(rule.spoken) {
                add(DictionaryEntry(word: word, correction: heard))
            } else { olderRules.append(rule) }
        }
        return DictionaryBook(entries: entries, olderVocabulary: olderVocabulary, olderRules: olderRules)
    }
}

/// `dictionary.json` beside the settings, file-protected like the other stores.
public final class DictionaryBookStore: @unchecked Sendable {
    private let url: URL

    public init(directory: URL) throws {
        try StoreIO.prepare(directory)
        url = directory.appendingPathComponent("dictionary.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func load() throws -> DictionaryBook {
        guard exists else { return DictionaryBook() }
        return try StoreIO.read(from: url)
    }

    public func save(_ book: DictionaryBook) throws {
        try StoreIO.write(book, to: url)
    }
}
