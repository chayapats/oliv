// Permission status + prompts for the three grants OLIV's pipeline needs
// (W3-T4 onboarding). Ported grant-for-grant from the Wave-1/2 preflights:
//
//   Microphone       AVCaptureDevice.authorizationStatus/requestAccess(.audio)
//                    — the mic tap (AudioCapture) can't record without it.
//   Input Monitoring CGPreflightListenEventAccess/CGRequestListenEventAccess
//                    — the push-to-talk CGEventTap (HotkeyMonitor) receives no
//                    events without it (app.hotkey.check_event_access()).
//   Accessibility    CGPreflightPostEventAccess/CGRequestPostEventAccess
//                    — synthesizing Cmd+V to paste (TextInjector) needs it
//                    (app.inject's post gate).
//
// The preflight calls NEVER prompt; the request calls prompt once and register
// the app in the relevant System Settings list. None of this can crash the app:
// a missing grant just gates that stage, and onboarding explains what's left.

import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// Tri-state for a permission. Input Monitoring / Accessibility only expose
/// granted-or-not via preflight, so they never surface `.notDetermined` on the
/// read side; Microphone does.
enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined

    var isGranted: Bool { self == .granted }
}

/// Which permission a row/deep-link refers to.
enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case inputMonitoring
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    var why: String {
        switch self {
        case .microphone: return "Record your voice while you hold the push-to-talk key."
        case .inputMonitoring: return "Detect the push-to-talk key press globally."
        case .accessibility: return "Paste the transcript at your cursor (synthesize Cmd+V)."
        }
    }

    /// Deep link to the exact Privacy pane in System Settings.
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// Live permission state for the onboarding window. Polled ~1s while the window
/// is open (the view drives `refresh()` off a timer) so a grant made in System
/// Settings reflects back without a relaunch.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var microphone: PermissionStatus = .notDetermined
    @Published private(set) var inputMonitoring: PermissionStatus = .denied
    @Published private(set) var accessibility: PermissionStatus = .denied

    init() { refresh() }

    /// All three granted — the pipeline can run end-to-end.
    var allGranted: Bool {
        microphone.isGranted && inputMonitoring.isGranted && accessibility.isGranted
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone: return microphone
        case .inputMonitoring: return inputMonitoring
        case .accessibility: return accessibility
        }
    }

    /// Re-read all three (never prompts). Cheap; safe to call on a timer.
    func refresh() {
        microphone = Self.microphoneStatus()
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied
        accessibility = CGPreflightPostEventAccess() ? .granted : .denied
    }

    /// Prompt for `kind`. Microphone shows the system dialog; the two event-tap
    /// grants ask macOS to prompt + register the app in the Settings list. After
    /// the async mic callback we refresh so the row updates.
    func request(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            refresh()
        case .accessibility:
            _ = CGRequestPostEventAccess()
            refresh()
        }
    }

    /// Open the exact Privacy pane so the user can flip the toggle.
    func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    private static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied   // .denied / .restricted
        }
    }
}
