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

    /// The trimmed field when the server would accept it: 1…100 characters
    /// with at least one letter or digit.
    public static func clean(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxFieldLength,
              t.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
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
    /// The first `inFlight` pending ops are in the request being sent; they
    /// are never compacted until it answers. Not persisted.
    private var inFlight = 0

    enum CodingKeys: String, CodingKey { case entries, revision, pending, uploadedLocal, serverSupportsDictionary }

    public init(entries: [DictionaryEntry] = []) { self.entries = entries }

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

    /// The operations for the next request (nil = just fetch). The first sync
    /// also uploads this device's entries.
    public mutating func outgoing() -> [DictionaryOp]? {
        pending = DictionaryOp.compact(pending)
        inFlight = pending.count
        let upload = uploadedLocal ? [] : entries.map(DictionaryOp.upsert)
        let ops = DictionaryOp.compact(upload + pending)
        return ops.isEmpty ? nil : ops
    }

    /// The server answered `outgoing()`. Edits made meanwhile stay queued and
    /// are replayed on top of the server copy.
    public mutating func acknowledge(_ snapshot: DictionarySnapshot) {
        pending.removeFirst(min(inFlight, pending.count))
        inFlight = 0
        revision = snapshot.revision
        uploadedLocal = true
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
    /// ordered replacement rules) into entries, deduplicated.
    public static func migrate(vocabularyText: String, replacements: [ReplacementRule]) -> [DictionaryEntry] {
        var entries: [DictionaryEntry] = []
        var identities = Set<String>()
        func add(_ entry: DictionaryEntry) {
            if identities.insert(entry.identity).inserted { entries.append(entry) }
        }
        for line in vocabularyText.components(separatedBy: .newlines) {
            if let word = DictionaryEntry.clean(line) { add(DictionaryEntry(word: word)) }
        }
        for rule in replacements {
            guard let word = DictionaryEntry.clean(rule.written), let heard = DictionaryEntry.clean(rule.spoken) else { continue }
            add(DictionaryEntry(word: word, correction: heard))
        }
        return entries
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
