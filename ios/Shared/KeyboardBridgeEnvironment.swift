import Foundation
import CoreFoundation

/// Only short-lived focus identifiers and a requested dictation cross this boundary.
/// Credentials, audio, history, and ordinary typed text stay outside the App Group.
enum KeyboardBridgeEnvironment {
    static let groupIdentifier = "group.com.chayapat.oliv.ios"
    static let focusRefreshNotification = "com.chayapat.oliv.keyboard.focus-refresh"
    static let deliveryNotification = "com.chayapat.oliv.keyboard.delivery"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent("KeyboardDelivery", isDirectory: true)
    }

    static func requestFocusRefresh() { post(focusRefreshNotification) }
    static func notifyDelivery() { post(deliveryNotification) }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Payload-free wake-up signals; files remain the source of truth. No polling timer.
final class OlivDarwinObservation: @unchecked Sendable {
    private let name: String
    private let callback: @Sendable () -> Void

    init(name: String, callback: @escaping @Sendable () -> Void) {
        self.name = name
        self.callback = callback
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<OlivDarwinObservation>.fromOpaque(observer).takeUnretainedValue().callback()
            }, name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(name as CFString), nil)
    }
}
