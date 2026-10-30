import Foundation
import OlivCore

struct KeyboardCaptureTarget: Sendable {
    let recordingID: UUID
    let focus: KeyboardFocusLease
}

/// Optional for ordinary AppModel initializers so test/demo fixtures never touch App Groups.
@MainActor
protocol KeyboardDelivering: AnyObject {
    func snapshotFocus() async -> KeyboardFocusLease?
    /// Asks whether OLIV's keyboard is on screen with Full Access, without
    /// leaving a capture diagnostic. Setup uses this; capture never does.
    func isConnected() async -> Bool
    func publish(text: String, target: KeyboardFocusLease, recordingID: UUID) async -> Bool
    func cancel(recordingID: UUID)
}

/// There is no idle poll, microphone, network request, or transcript history in this bridge.
/// A visible keyboard must answer a fresh request both before capture and before delivery.
@MainActor
final class KeyboardDeliveryCoordinator: KeyboardDelivering {
    private let store: KeyboardDeliveryStore
    private let requestFocusRefresh: () -> Void
    private let notifyDelivery: () -> Void
    private let now: () -> Date
    private let refreshTimeout: Duration

    init(store: KeyboardDeliveryStore,
         refreshTimeout: Duration = .milliseconds(250),
         now: @escaping () -> Date = Date.init,
         requestFocusRefresh: @escaping () -> Void,
         notifyDelivery: @escaping () -> Void) {
        self.store = store
        self.refreshTimeout = refreshTimeout
        self.now = now
        self.requestFocusRefresh = requestFocusRefresh
        self.notifyDelivery = notifyDelivery
    }

    static func makeDefault() -> KeyboardDeliveryCoordinator? {
        guard let directory = KeyboardBridgeEnvironment.directory else {
            CaptureDiagnostics.record(event: .bridgeUnavailable)
            return nil
        }
        do {
            let store = try KeyboardDeliveryStore(directory: directory)
            return KeyboardDeliveryCoordinator(store: store,
                requestFocusRefresh: { KeyboardBridgeEnvironment.requestFocusRefresh() },
                notifyDelivery: { KeyboardBridgeEnvironment.notifyDelivery() })
        } catch {
            CaptureDiagnostics.record(event: .bridgeUnavailable, error: error)
            return nil
        }
    }

    func isConnected() async -> Bool { await refreshedFocus() != nil }

    func snapshotFocus() async -> KeyboardFocusLease? {
        let focus = await refreshedFocus()
        CaptureDiagnostics.record(event: focus == nil ? .focusUnavailable : .focusAvailable)
        return focus
    }

    func publish(text: String, target: KeyboardFocusLease, recordingID: UUID) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let current = await refreshedFocus(), !Task.isCancelled,
              Self.sameInput(current, target) else {
            CaptureDiagnostics.record(event: .deliveryRejected)
            return false
        }
        for attempt in 0..<2 {
            do {
                // Store publication and its signal are synchronous: cancellation cannot interleave
                // between this final check and the atomic write. consume rechecks the focus again.
                guard !Task.isCancelled,
                      try store.publish(text: text, for: target, sessionID: recordingID, now: now()) else {
                    CaptureDiagnostics.record(event: .deliveryRejected)
                    return false
                }
                notifyDelivery()
                CaptureDiagnostics.record(event: .deliveryPublished)
                return true
            } catch KeyboardDeliveryError.storageUnavailable where attempt == 0 {
                // A simultaneous keyboard refresh can briefly own the nonblocking file lock.
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch {
                    CaptureDiagnostics.record(event: .deliveryRejected)
                    return false
                }
            } catch {
                // A bridge failure never destroys the completed transcript in the main app.
                CaptureDiagnostics.record(event: .deliveryRejected, error: error)
                return false
            }
        }
        return false
    }

    func cancel(recordingID: UUID) {
        do { try store.cancel(sessionID: recordingID, now: now()) }
        catch { CaptureDiagnostics.record(event: .bridgeUnavailable, error: error) }
    }

    private func refreshedFocus() async -> KeyboardFocusLease? {
        guard !Task.isCancelled else { return nil }
        let requestedAt = now()
        let deadline = ContinuousClock.now.advanced(by: refreshTimeout)
        requestFocusRefresh()
        repeat {
            guard !Task.isCancelled else { return nil }
            do {
                if let focus = try store.activeFocus(now: now()), focus.updatedAt >= requestedAt {
                    return focus
                }
            } catch KeyboardDeliveryError.storageUnavailable {
                // Retry only inside this explicit, bounded handshake; never poll while idle.
            } catch {
                CaptureDiagnostics.record(event: .bridgeUnavailable, error: error)
                return nil
            }
            guard ContinuousClock.now < deadline else { return nil }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return nil }
        } while ContinuousClock.now <= deadline
        return nil
    }

    private static func sameInput(_ lhs: KeyboardFocusLease, _ rhs: KeyboardFocusLease) -> Bool {
        lhs.id == rhs.id && lhs.documentID == rhs.documentID && lhs.revision == rhs.revision
            && lhs.contextHash == rhs.contextHash
    }
}
