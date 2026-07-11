// Launch-at-login toggle (W3-T4) via SMAppService (macOS 13+). The source of
// truth is the OS, not a preference: `isEnabled` reads the live registration
// status and `setEnabled` register/unregisters, so the Settings toggle always
// reflects reality even if the user changes it in System Settings › General ›
// Login Items.
//
// LIMITATION (documented, not fought — per the task): SMAppService.mainApp only
// fully registers an app that lives in a launchable location — typically
// /Applications. A dev build run from DerivedData, or a .app on a mounted DMG,
// may report `.requiresApproval` or silently not launch at login until the app
// is moved to /Applications. We surface the real status rather than pretending;
// once the shipped app is in /Applications this "just works".

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// Is the app currently registered to launch at login?
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The raw status, for surfacing the /Applications limitation in the UI
    /// (e.g. `.requiresApproval` → "Approve in Login Items").
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Register or unregister. Throws the SMAppService error so the caller can
    /// surface it (and revert the toggle) rather than lying about success.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            // unregister() throws if it was never registered; treat that as a
            // successful "already off".
            do { try SMAppService.mainApp.unregister() }
            catch { if SMAppService.mainApp.status != .notRegistered { throw error } }
        }
    }

    /// Human-readable one-liner for the current status (drives the Settings hint).
    static func statusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "On"
        case .notRegistered: return "Off"
        case .requiresApproval: return "Needs approval in System Settings › Login Items"
        case .notFound: return "Unavailable (run the app from /Applications)"
        @unknown default: return "Unknown"
        }
    }
}
