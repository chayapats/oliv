// DictionarySync — keeps the personal Dictionary in step with the OLIV server
// (oliv-server docs/DICTIONARY.md), so every device shares one dictionary.
//
// Local edits are never sent as "the whole list": OLIVSettings reports each
// change as (old, new) and this turns it into per-entry operations, queued and
// persisted until the server takes them. Each successful exchange returns the
// server's snapshot, which replaces the local list (operations still waiting
// are replayed on top, so nothing the user just did flickers away). Offline,
// the queue simply waits; on a server without the dictionary (404) the
// dictionary stays local and dictation falls back to sending derived
// vocabulary/replacements.

import CryptoKit
import Foundation

/// One change to send to the server.
enum DictionaryOp: Codable, Equatable, Sendable {
    case upsert(DictionaryEntry)
    case delete(id: String)

    var entryID: String {
        switch self {
        case .upsert(let entry): return entry.id
        case .delete(let id): return id
        }
    }

    /// `POST /v1/dictionary` wire form. Device-local fields (usageCount) stay home.
    var wire: [String: Any] {
        switch self {
        case .delete(let id):
            return ["op": "delete", "id": id]
        case .upsert(let e):
            var entry: [String: Any] = ["id": e.id, "word": e.word, "enabled": e.enabled,
                                        "starred": e.starred, "source": e.source.rawValue]
            entry["correction"] = e.correction ?? NSNull()
            return ["op": "upsert", "entry": entry]
        }
    }

    /// The operations that turn `old` into `new`, compared by entry id.
    static func diff(from old: [DictionaryEntry], to new: [DictionaryEntry]) -> [DictionaryOp] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        var ops: [DictionaryOp] = new.compactMap { entry in
            guard let previous = before[entry.id] else { return .upsert(entry) }
            return previous.syncsSame(as: entry) ? nil : .upsert(entry)
        }
        ops += old.filter { !after.contains($0.id) }.map { .delete(id: $0.id) }
        return ops
    }

    /// Apply to a local list (replaying not-yet-acknowledged changes).
    static func apply(_ ops: [DictionaryOp], to entries: [DictionaryEntry]) -> [DictionaryEntry] {
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

private extension DictionaryEntry {
    /// Equal in every field the server stores (usageCount is device-local).
    func syncsSame(as other: DictionaryEntry) -> Bool {
        word == other.word && correction == other.correction && enabled == other.enabled
            && starred == other.starred && source == other.source
    }
}

/// The server's copy of the dictionary.
struct DictionarySnapshot: Equatable, Sendable {
    struct Rejection: Equatable, Sendable {
        let id: String
        /// `duplicate` or `limit`.
        let reason: String
    }

    let revision: Int
    let maxEntries: Int?
    let entries: [DictionaryEntry]
    let rejected: [Rejection]

    init(revision: Int, maxEntries: Int? = nil, entries: [DictionaryEntry], rejected: [Rejection] = []) {
        self.revision = revision
        self.maxEntries = maxEntries
        self.entries = entries
        self.rejected = rejected
    }

    /// Parse a `{revision, max_entries, entries, rejected}` reply.
    init(_ object: [String: Any]) throws {
        guard let revision = object["revision"] as? Int, revision >= 0,
              let rawEntries = object["entries"] as? [[String: Any]] else { throw OLIVAPIError.invalidReply }
        let entries = try rawEntries.map { raw -> DictionaryEntry in
            guard let id = raw["id"] as? String, let word = raw["word"] as? String else {
                throw OLIVAPIError.invalidReply
            }
            return DictionaryEntry(id: id, word: word, correction: raw["correction"] as? String,
                                   enabled: raw["enabled"] as? Bool ?? true,
                                   starred: raw["starred"] as? Bool ?? false,
                                   source: (raw["source"] as? String).flatMap(DictionarySource.init) ?? .manual)
        }
        let rejected = (object["rejected"] as? [[String: Any]] ?? []).compactMap { raw -> Rejection? in
            guard let id = raw["id"] as? String, let reason = raw["reason"] as? String else { return nil }
            return Rejection(id: id, reason: reason)
        }
        self.init(revision: revision, maxEntries: object["max_entries"] as? Int,
                  entries: entries, rejected: rejected)
    }
}

/// The server side of sync (OLIVAPIClient; a fake in tests).
protocol DictionaryRemote {
    func dictionary(ops: [DictionaryOp]?) async throws -> DictionarySnapshot
}

extension OLIVAPIClient: DictionaryRemote {}

@MainActor
final class DictionarySync: ObservableObject {
    enum Status: Equatable {
        /// No OLIV API key: the dictionary lives on this Mac only.
        case localOnly
        case syncing
        case synced(Date)
        /// Changes are waiting for the server (offline or busy); retried.
        case waiting
        /// The server predates dictionary sync.
        case unsupported
        /// Needs the user (e.g. the key was rejected).
        case failed(String)
    }

    /// What survives relaunch.
    struct State: Codable, Equatable {
        var revision = 0
        var pending: [DictionaryOp] = []
        /// Local entries were uploaded once (the first sync merges them in).
        var uploadedLocal = false
        /// nil until the server answered once.
        var serverSupportsDictionary: Bool?
        /// Which server + key this state belongs to (a hash, never the key).
        /// Another account starts over with a full upload, so its snapshot
        /// cannot replace this Mac's entries without merging them first.
        var account: String?
        /// Entries the server refused (account full, or a conflict that did
        /// not resolve): kept on this Mac, shown in Settings, and offered
        /// again at the next launch or API change. Never silently dropped.
        var held: [DictionaryEntry] = []

        /// A fresh start (another account, or a server that lost sync
        /// support): the next exchange uploads every local entry, and only
        /// deletions still need sending, since an upload cannot express them.
        func restarted(account: String?, serverSupportsDictionary: Bool? = nil) -> State {
            State(pending: pending.filter { if case .delete = $0 { return true } else { return false } },
                  serverSupportsDictionary: serverSupportsDictionary, account: account)
        }
    }

    /// Stable, non-reversible identity of a server + key.
    static func accountID(_ configuration: OLIVAPIConfiguration) -> String {
        let material = configuration.baseURL.absoluteString + "\n" + configuration.apiKey
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let stateKey = "oliv.dictionarySync"
    /// Coalesce bursts of edits (typing, bulk delete) into one request.
    static let editDelay: TimeInterval = 1
    static let retryDelays: [TimeInterval] = [30, 60, 120, 300]

    @Published private(set) var status: Status = .localOnly
    /// Words the server refused: entries held on this Mac, then duplicates
    /// of an entry it already had (merged) on the last sync.
    @Published private(set) var rejectedWords: [String] = []
    private var mergedDuplicates: [String] = [] {
        didSet { updateRejectedWords() }
    }
    private(set) var state: State {
        didSet {
            persist()
            if state.held != oldValue.held { updateRejectedWords() }
        }
    }

    private let defaults: UserDefaults
    private let makeRemote: (OLIVAPIConfiguration) -> DictionaryRemote
    /// Off in tests, which drive `syncNow()` themselves.
    private let autoSync: Bool
    private weak var settings: OLIVSettings?
    private var scheduled: Task<Void, Never>?
    private var running = false
    private var runAgain = false
    private var failures = 0
    /// The first `inFlight` pending operations are in the request being sent;
    /// they are left untouched until it answers.
    private var inFlight = 0
    /// Refused-as-duplicate entries already retried once in this run.
    private var retriedDuplicates = Set<String>()

    init(defaults: UserDefaults = .standard, autoSync: Bool = true,
         makeRemote: @escaping (OLIVAPIConfiguration) -> DictionaryRemote = { OLIVAPIClient(configuration: $0) }) {
        self.defaults = defaults
        self.autoSync = autoSync
        self.makeRemote = makeRemote
        if let data = defaults.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
        updateRejectedWords()
    }

    private func updateRejectedWords() {
        rejectedWords = state.held.map(\.word) + mergedDuplicates
    }

    /// The OLIV API applies its own copy, so requests can leave
    /// vocabulary/replacements out — only while the server is known to hold
    /// exactly this Mac's dictionary: sync supported, this account's state,
    /// the local entries uploaded, and nothing queued, in flight or held.
    var serverAppliesDictionary: Bool {
        guard let configuration = settings?.olivAPIConfiguration else { return false }
        return state.serverSupportsDictionary == true
            && state.account == Self.accountID(configuration)
            && state.uploadedLocal && state.pending.isEmpty && state.held.isEmpty
    }

    /// Start following `settings`: local edits are queued, then synced.
    func attach(to settings: OLIVSettings) {
        self.settings = settings
        settings.onDictionaryEdit = { [weak self] old, new in self?.recordEdit(from: old, to: new) }
        configurationChanged()
    }

    /// The API URL/key changed (or the app started): sync now.
    func configurationChanged() {
        failures = 0
        // Offer held entries again (once per launch / API change, not in a loop).
        if !state.held.isEmpty {
            state.pending = Self.compact(state.pending + state.held.map { .upsert($0) })
            state.held = []
        }
        schedule(after: 0)
    }

    /// Fetch the server copy now (e.g. the Dictionary page opened), so edits
    /// made on other devices show up without waiting for a dictation.
    func refresh() {
        schedule(after: 0)
    }

    /// A dictation reply carried the server's revision; refresh if another
    /// device changed the dictionary.
    func noteServerRevision(_ revision: Int?) {
        guard let revision, revision != state.revision else { return }
        schedule(after: 0)
    }

    func recordEdit(from old: [DictionaryEntry], to new: [DictionaryEntry]) {
        let ops = DictionaryOp.diff(from: old, to: new)
        guard !ops.isEmpty else { return }
        var next = state
        // A held entry the user edited goes back in the queue; deleted, it is gone.
        let touched = Set(ops.map(\.entryID))
        next.held.removeAll { touched.contains($0.id) }
        let sending = next.pending.prefix(inFlight)
        next.pending = Array(sending) + Self.compact(next.pending.dropFirst(inFlight) + ops)
        state = next
        schedule(after: Self.editDelay)
    }

    /// Merge back-to-back operations on the same entry (the last wins), and
    /// nothing else: the server applies operations in order under a
    /// uniqueness rule, so reordering across entries could turn a valid
    /// rename-then-reuse ("A: Foo→Bar", "B: Foo") into a rejected duplicate.
    static func compact(_ ops: [DictionaryOp]) -> [DictionaryOp] {
        var out: [DictionaryOp] = []
        for op in ops {
            if let last = out.last, last.entryID == op.entryID {
                out[out.count - 1] = op
            } else {
                out.append(op)
            }
        }
        return out
    }

    private func schedule(after delay: TimeInterval) {
        guard autoSync else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// One exchange with the server; reruns while edits keep arriving.
    func syncNow() async {
        guard let settings, settings.olivAPIConfiguration != nil else {
            status = .localOnly
            return
        }
        if running {
            runAgain = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            runAgain = false
            // Re-read each pass: the URL/key may have changed mid-request.
            guard let configuration = settings.olivAPIConfiguration else {
                status = .localOnly
                return
            }
            let account = Self.accountID(configuration)
            if state.account == nil {
                // First sync, or state saved before accounts were recorded.
                state.account = account
            } else if state.account != account {
                state = state.restarted(account: account)
                mergedDuplicates = []
            }
            await exchange(with: makeRemote(configuration), account: account, settings: settings)
        } while runAgain && status != .unsupported
    }

    private func exchange(with remote: DictionaryRemote, account: String, settings: OLIVSettings) async {
        // The first sync merges this Mac's existing entries into the server's.
        let upload = state.uploadedLocal ? [] : settings.dictionaryEntries.map { DictionaryOp.upsert($0) }
        state.pending = Self.compact(state.pending)
        inFlight = state.pending.count
        defer { inFlight = 0 }
        let ops = Self.compact(upload + state.pending)
        status = .syncing
        let result: Result<DictionarySnapshot, Error>
        do {
            result = .success(try await remote.dictionary(ops: ops.isEmpty ? nil : ops))
        } catch {
            result = .failure(error)
        }
        // The URL/key changed while waiting: this answer belongs to another
        // account. Leave everything queued and run again for the current one.
        guard settings.olivAPIConfiguration.map(Self.accountID) == account else {
            runAgain = true
            return
        }
        switch result {
        case .success(let snapshot):
            apply(snapshot, sent: ops, settings: settings)
        case .failure(OLIVAPIError.unsupported):
            // Nothing to send to a server that cannot keep it; a later upgrade
            // starts again with a full upload (deletions kept).
            state = state.restarted(account: account, serverSupportsDictionary: false)
            mergedDuplicates = []
            status = .unsupported
        case .failure(OLIVAPIError.http(let code)) where code == 401 || code == 403:
            status = .failed(OLIVAPIError.http(code).errorDescription ?? "The API key was rejected.")
        case .failure:
            status = .waiting
            let delay = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
            failures += 1
            schedule(after: delay)
        }
    }

    private func apply(_ snapshot: DictionarySnapshot, sent ops: [DictionaryOp], settings: OLIVSettings) {
        var next = state
        // Edits made while the request was in flight stay queued.
        next.pending.removeFirst(inFlight)
        next.revision = snapshot.revision
        next.uploadedLocal = true
        next.serverSupportsDictionary = true
        failures = 0
        // A refused upsert is only settled when the server already holds the
        // same word + correction (a duplicate from another device: merged).
        // Anything else stays on this Mac: a duplicate whose conflict this
        // batch released is retried once; the rest (account full) is held.
        let refused = Set(snapshot.rejected.map(\.id))
        let reasons = Dictionary(snapshot.rejected.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let serverKeys = Set(snapshot.entries.map { $0.dedupeKey() })
        var merged: [String] = []
        var refusedEntries: [String: DictionaryEntry] = [:]
        for case .upsert(let entry) in ops where refused.contains(entry.id) {
            refusedEntries[entry.id] = entry
        }
        for entry in refusedEntries.values.sorted(by: { $0.word < $1.word }) {
            if serverKeys.contains(entry.dedupeKey()) {
                merged.append(entry.word)
            } else if reasons[entry.id] == "duplicate", !retriedDuplicates.contains(entry.id) {
                retriedDuplicates.insert(entry.id)
                next.pending.append(.upsert(entry))
            } else {
                retriedDuplicates.remove(entry.id)
                next.held.removeAll { $0.id == entry.id }
                next.held.append(entry)
            }
        }
        if next.pending.isEmpty { retriedDuplicates = [] }
        state = next
        mergedDuplicates = merged
        let held = state.held.filter { h in !snapshot.entries.contains { $0.id == h.id } }
        settings.replaceDictionaryFromServer(DictionaryOp.apply(state.pending, to: snapshot.entries) + held)
        status = state.pending.isEmpty ? .synced(Date()) : .waiting
        if !state.pending.isEmpty { runAgain = true }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(state), forKey: Self.stateKey)
    }
}
