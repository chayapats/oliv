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
    /// Words the server refused on the last sync, for the Settings notice.
    @Published private(set) var rejectedWords: [String] = []
    private(set) var state: State {
        didSet { persist() }
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
    }

    /// The OLIV API applies its own copy, so requests can leave
    /// vocabulary/replacements out. False until the server has confirmed it.
    var serverAppliesDictionary: Bool {
        settings?.olivAPIConfiguration != nil && state.serverSupportsDictionary == true
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
        let sending = state.pending.prefix(inFlight)
        state.pending = Array(sending) + Self.compact(state.pending.dropFirst(inFlight) + ops)
        schedule(after: Self.editDelay)
    }

    /// Keep only the last operation per entry, in the order of last change.
    static func compact(_ ops: [DictionaryOp]) -> [DictionaryOp] {
        var seen = Set<String>()
        return ops.reversed().filter { seen.insert($0.entryID).inserted }.reversed()
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
                // Everything pending is already in the local list, which the
                // fresh state uploads in full.
                state = State(account: account)
                rejectedWords = []
            }
            await exchange(with: makeRemote(configuration), settings: settings)
        } while runAgain && status != .unsupported
    }

    private func exchange(with remote: DictionaryRemote, settings: OLIVSettings) async {
        // The first sync merges this Mac's existing entries into the server's.
        let upload = state.uploadedLocal ? [] : settings.dictionaryEntries.map { DictionaryOp.upsert($0) }
        state.pending = Self.compact(state.pending)
        inFlight = state.pending.count
        defer { inFlight = 0 }
        let ops = Self.compact(upload + state.pending)
        status = .syncing
        do {
            let snapshot = try await remote.dictionary(ops: ops.isEmpty ? nil : ops)
            // Edits made while the request was in flight stay queued.
            state.pending.removeFirst(inFlight)
            state.revision = snapshot.revision
            state.uploadedLocal = true
            state.serverSupportsDictionary = true
            failures = 0
            let refused = Set(snapshot.rejected.map(\.id))
            rejectedWords = ops.compactMap { op in
                guard case .upsert(let e) = op, refused.contains(e.id) else { return nil }
                return e.word
            }
            settings.replaceDictionaryFromServer(DictionaryOp.apply(state.pending, to: snapshot.entries))
            status = state.pending.isEmpty ? .synced(Date()) : .waiting
            if !state.pending.isEmpty { runAgain = true }
        } catch OLIVAPIError.unsupported {
            // Nothing to send to a server that cannot keep it; a later upgrade
            // starts again with a full upload.
            state = State(serverSupportsDictionary: false, account: state.account)
            status = .unsupported
        } catch OLIVAPIError.http(let code) where code == 401 || code == 403 {
            status = .failed(OLIVAPIError.http(code).errorDescription ?? "The API key was rejected.")
        } catch {
            status = .waiting
            let delay = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
            failures += 1
            schedule(after: delay)
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(state), forKey: Self.stateKey)
    }
}
