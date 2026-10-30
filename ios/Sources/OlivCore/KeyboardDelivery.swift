import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A short-lived assertion made by the visible keyboard after examining its
/// current document. Only a digest is stored; surrounding typed text never is.
public struct KeyboardFocusLease: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let revision: UInt64
    public let contextHash: String
    public let updatedAt: Date
    public let expiresAt: Date

    public init(id: UUID = UUID(), documentID: UUID, revision: UInt64 = 0, contextHash: String,
                updatedAt: Date, expiresAt: Date) {
        self.id = id
        self.documentID = documentID
        self.revision = revision
        self.contextHash = contextHash
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }

    fileprivate func identifiesSameFocus(as other: KeyboardFocusLease) -> Bool {
        id == other.id && documentID == other.documentID && revision == other.revision && contextHash == other.contextHash
    }
}

public struct KeyboardDelivery: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let text: String
    public let target: KeyboardFocusLease
    public let createdAt: Date
    public let expiresAt: Date
}

public enum KeyboardDeliveryError: Error, LocalizedError, Equatable, Sendable {
    case invalidFocus, invalidText, corruptState, stateTooLarge, receiptLimit, storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidFocus: "The keyboard focus is no longer valid."
        case .invalidText: "This result cannot be delivered through the keyboard."
        case .corruptState: "The keyboard handoff could not be read safely."
        case .stateTooLarge: "The keyboard handoff exceeded its storage limit."
        case .receiptLimit: "Too many keyboard handoffs are pending. Try again shortly."
        case .storageUnavailable: "The shared keyboard storage is unavailable."
        }
    }
}

/// One file transaction, protected by a cross-process flock, provides focus
/// validation and consume-at-most-once semantics across the app and extension.
///
/// Focus should be published only after a visible keyboard explicitly verifies
/// its actual document/context (for example in response to a Darwin refresh
/// notification). This store creates no timers, observers, microphone, or network.
/// A fresh explicit publication may revive an expired but unchanged identity.
/// Expiry immediately prevents delivery; expired bytes are removed on the next
/// successful transaction, rather than by a background deletion timer.
public final class KeyboardDeliveryStore: @unchecked Sendable {
    public static let focusLifetime: TimeInterval = 6
    public static let deliveryLifetime: TimeInterval = 60
    public static let maximumTextBytes = 32 * 1_024
    public static let maximumStateBytes = 128 * 1_024
    /// Receipts contain only session IDs and dates, never consumed text. A new
    /// UUID is required for every recording; recent replay attempts fail closed.
    public static let receiptLifetime: TimeInterval = 300
    private static let maximumReceipts = 256
    private let directory: URL
    private let stateURL: URL
    private let lockURL: URL

    private struct Receipt: Codable, Equatable {
        let sessionID: UUID
        let expiresAt: Date
    }

    private struct State: Codable, Equatable {
        var version = 1
        var focus: KeyboardFocusLease?
        var delivery: KeyboardDelivery?
        var receipts: [Receipt] = []
    }

    public init(directory: URL) throws {
        self.directory = directory
        stateURL = directory.appendingPathComponent("keyboard-delivery.json")
        lockURL = directory.appendingPathComponent("keyboard-delivery.lock")
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    /// Publish only from an explicitly verified visible keyboard callback.
    /// Use a new ID when visibility, document, selection, or context changes.
    @discardableResult
    public func publishFocus(id: UUID, documentID: UUID, revision: UInt64, contextHash: String,
                             now: Date = Date()) throws -> KeyboardFocusLease {
        let lease = KeyboardFocusLease(id: id, documentID: documentID, revision: revision,
            contextHash: contextHash.lowercased(), updatedAt: now, expiresAt: now.addingTimeInterval(Self.focusLifetime))
        guard Self.validLease(lease), Self.validDate(now) else { throw KeyboardDeliveryError.invalidFocus }
        return try transaction(now: now) { state in
            if let current = state.focus, current.id == id, revision < current.revision {
                throw KeyboardDeliveryError.invalidFocus
            }
            if let current = state.focus, !current.identifiesSameFocus(as: lease) { state.delivery = nil }
            state.focus = lease
            return lease
        }
    }

    /// Optional same-focus refresh. It cannot replace a newer view or revive an
    /// expired lease; explicit UI verification should use publishFocus instead.
    public func refreshFocus(_ lease: KeyboardFocusLease, now: Date = Date()) throws -> KeyboardFocusLease? {
        try transaction(now: now) { state in
            guard let current = state.focus, current.identifiesSameFocus(as: lease), Self.fresh(current, at: now) else { return nil }
            let refreshed = KeyboardFocusLease(id: current.id, documentID: current.documentID,
                revision: current.revision, contextHash: current.contextHash,
                updatedAt: now, expiresAt: now.addingTimeInterval(Self.focusLifetime))
            state.focus = refreshed
            return refreshed
        }
    }

    public func activeFocus(now: Date = Date()) throws -> KeyboardFocusLease? {
        try transaction(now: now) { state in
            guard let focus = state.focus, Self.fresh(focus, at: now) else { return nil }
            return focus
        }
    }

    /// A stale disappearing keyboard must never erase another keyboard's focus.
    public func invalidateFocus(id: UUID, now: Date = Date()) throws {
        try transaction(now: now) { state in
            guard state.focus?.id == id else { return }
            state.focus = nil
            state.delivery = nil
        }
    }

    /// The target is the snapshot captured at the start of explicit dictation.
    /// Its original expiry may have passed, but the current verified lease must
    /// still be fresh and identify the exact same document/revision/context.
    /// Returns false for stale targets or already published/cancelled sessions.
    @discardableResult
    public func publish(text: String, for target: KeyboardFocusLease, sessionID: UUID,
                        now: Date = Date()) throws -> Bool {
        guard Self.validText(text) else { throw KeyboardDeliveryError.invalidText }
        guard Self.validLease(target), target.updatedAt <= now else { throw KeyboardDeliveryError.invalidFocus }
        return try transaction(now: now) { state in
            guard let current = state.focus, Self.fresh(current, at: now),
                  current.identifiesSameFocus(as: target),
                  !state.receipts.contains(where: { $0.sessionID == sessionID }) else { return false }
            try Self.addReceipt(sessionID, now: now, to: &state)
            // Only the most recent explicit session can remain pending. Its
            // predecessor's receipt prevents a late repeated publication.
            state.delivery = KeyboardDelivery(sessionID: sessionID, text: text, target: target,
                createdAt: now, expiresAt: now.addingTimeInterval(Self.deliveryLifetime))
            return true
        }
    }

    /// Remove the pending text durably under the same lock as focus validation.
    /// A crash after this returns can lose an insertion but cannot duplicate it.
    public func consume(for target: KeyboardFocusLease, now: Date = Date()) throws -> KeyboardDelivery? {
        guard Self.validLease(target), target.updatedAt <= now else { throw KeyboardDeliveryError.invalidFocus }
        return try transaction(now: now) { state in
            guard let current = state.focus, Self.fresh(current, at: now),
                  current.identifiesSameFocus(as: target), let delivery = state.delivery,
                  delivery.target.identifiesSameFocus(as: target),
                  delivery.createdAt <= now, delivery.expiresAt > now else { return nil }
            state.delivery = nil
            return delivery
        }
    }

    /// Works before publication as well as after it. Cancelling one recording
    /// never clears another recording's delivery or the keyboard's current focus.
    public func cancel(sessionID: UUID, now: Date = Date()) throws {
        try transaction(now: now) { state in
            if !state.receipts.contains(where: { $0.sessionID == sessionID }) {
                try Self.addReceipt(sessionID, now: now, to: &state)
            }
            if state.delivery?.sessionID == sessionID { state.delivery = nil }
        }
    }

    private func transaction<T>(now: Date, _ body: (inout State) throws -> T) throws -> T {
        guard Self.validDate(now) else { throw KeyboardDeliveryError.invalidFocus }
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw KeyboardDeliveryError.storageUnavailable }
        defer { close(descriptor) }
        // A different process may be suspended while holding the lock. Never
        // block the keyboard's UI thread waiting for that process to resume.
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno != EINTR { throw KeyboardDeliveryError.storageUnavailable }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        var state = try readState()
        let original = state
        state.receipts.removeAll { $0.expiresAt <= now }
        if let delivery = state.delivery, delivery.expiresAt <= now || delivery.createdAt > now {
            state.delivery = nil
        }
        if let focus = state.focus, !Self.fresh(focus, at: now) {
            state.focus = nil
            state.delivery = nil
        }
        let result = try body(&state)
        // Commit before returning a consumed payload. Never return text if the
        // atomic write or disk synchronization fails.
        // Handshake reads can repeat briefly while awaiting the visible
        // keyboard. Unchanged reads must not rewrite or synchronize the file.
        if state != original { try writeState(state) }
        return result
    }

    private func readState() throws -> State {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State() }
        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumStateBytes else {
            throw KeyboardDeliveryError.stateTooLarge
        }
        let data = try Data(contentsOf: stateURL)
        guard data.count <= Self.maximumStateBytes else { throw KeyboardDeliveryError.stateTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state: State
        do { state = try decoder.decode(State.self, from: data) }
        catch { throw KeyboardDeliveryError.corruptState }
        guard state.version == 1, state.receipts.count <= Self.maximumReceipts,
              Set(state.receipts.map(\.sessionID)).count == state.receipts.count,
              state.receipts.allSatisfy({ Self.validDate($0.expiresAt) }),
              state.focus.map(Self.validLease) ?? true else { throw KeyboardDeliveryError.corruptState }
        if let delivery = state.delivery {
            guard Self.validText(delivery.text), Self.validLease(delivery.target),
                  Self.validDate(delivery.createdAt), Self.validDate(delivery.expiresAt),
                  delivery.expiresAt > delivery.createdAt,
                  delivery.expiresAt.timeIntervalSince(delivery.createdAt) <= Self.deliveryLifetime,
                  delivery.target.updatedAt <= delivery.createdAt,
                  state.receipts.contains(where: { $0.sessionID == delivery.sessionID }) else {
                throw KeyboardDeliveryError.corruptState
            }
        }
        return state
    }

    private func writeState(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumStateBytes else { throw KeyboardDeliveryError.stateTooLarge }
        #if os(iOS)
        try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: stateURL, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let file = try FileHandle(forWritingTo: stateURL)
        defer { try? file.close() }
        try file.synchronize()
    }

    private static func addReceipt(_ sessionID: UUID, now: Date, to state: inout State) throws {
        guard state.receipts.count < maximumReceipts else { throw KeyboardDeliveryError.receiptLimit }
        state.receipts.append(Receipt(sessionID: sessionID, expiresAt: now.addingTimeInterval(receiptLifetime)))
    }

    private static func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }

    private static func validLease(_ lease: KeyboardFocusLease) -> Bool {
        validDate(lease.updatedAt) && validDate(lease.expiresAt)
            && lease.expiresAt > lease.updatedAt
            && lease.expiresAt.timeIntervalSince(lease.updatedAt) <= focusLifetime
            && lease.contextHash.utf8.count == 64
            && lease.contextHash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func fresh(_ lease: KeyboardFocusLease, at now: Date) -> Bool {
        lease.updatedAt <= now && lease.expiresAt > now
    }

    private static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximumTextBytes
    }
}
