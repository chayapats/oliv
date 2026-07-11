// Hotkey "record shortcut" capture (W4-T2 Feature B). The Settings › General
// field that turns "Press a key…" into the next physical key the user hits, so
// the push-to-talk key is no longer limited to the five presets.
//
// It mirrors the two channels HotkeyMonitor listens on, but on a LOCAL monitor
// (this app's key window only — the Settings window), never a global tap:
//
//   • flagsChanged → a MODIFIER (Option/Command/Control/Shift left+right, Fn).
//     We capture on the DOWN edge only, keyed on the same device-flag bit the
//     wrapper matches (via HotkeyMonitor.isModifierDown), so the recorder and the
//     live tap agree on exactly which physical key was chosen.
//   • keyDown      → any OTHER key (letters, F-keys, …), the keyDown/keyUp path
//     F19 already used. Escape cancels the capture.
//
// The DECISION is a pure function (`interpretCapture`) over (event kind, keycode,
// modifier-down, characters): captured / cancelled / ignore. That is the
// hermetic test seam — HotkeyRecorderTests drives it with no NSEvent, no key
// window, no run loop. The class here is only the thin NSEvent plumbing around
// it, exactly as HotkeyMonitor is thin plumbing around PushToTalkStateMachine.

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class HotkeyRecorder: ObservableObject {
    /// What one captured event resolves to. Equatable so the pure seam asserts
    /// cleanly in tests (HotkeyKey is Equatable).
    enum CaptureOutcome: Equatable {
        case captured(HotkeyKey)   // a usable push-to-talk key was pressed
        case cancelled             // Escape — abandon the capture
        case ignore                // a release edge / non-modifier flagsChanged — keep listening
    }

    /// The two event kinds the recorder distinguishes (the pure seam's input).
    enum CaptureEvent { case keyDown; case flagsChanged }

    /// Escape (kVK_Escape) — cancels the capture.
    nonisolated static let escapeKeyCode: CGKeyCode = 0x35

    @Published private(set) var isCapturing = false

    private var monitor: Any?
    private let onCapture: (HotkeyKey) -> Void
    private let onCancel: () -> Void

    init(onCapture: @escaping (HotkeyKey) -> Void, onCancel: @escaping () -> Void = {}) {
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    deinit { if let monitor = monitor { NSEvent.removeMonitor(monitor) } }

    // MARK: Pure decision (hermetic seam)

    /// Resolve one captured event. Pure over its arguments — the seam the DoD
    /// asks to unit-test (capture / cancel), with no OS events. `nonisolated` so
    /// it runs off the main actor (the hermetic tests call it synchronously).
    nonisolated static func interpretCapture(event: CaptureEvent,
                                             keyCode: CGKeyCode,
                                             modifierIsDown: Bool,
                                             characters: String?) -> CaptureOutcome {
        switch event {
        case .keyDown:
            if keyCode == escapeKeyCode { return .cancelled }
            return .captured(HotkeyKey.regularKey(keyCode: keyCode, characters: characters))
        case .flagsChanged:
            // Only a known device modifier, and only on its DOWN edge, is a pick;
            // the release edge (and any non-modifier flagsChanged) is ignored so
            // the recorder keeps listening.
            guard HotkeyKey.modifierDeviceFlag(for: keyCode) != nil, modifierIsDown else {
                return .ignore
            }
            return .captured(HotkeyKey.modifierKey(keyCode: keyCode))
        }
    }

    /// Resolve a live NSEvent through the pure seam (reads the device-flag bit
    /// off the underlying CGEvent so left/right modifiers stay distinct).
    nonisolated static func outcome(for event: NSEvent) -> CaptureOutcome {
        let keyCode = CGKeyCode(event.keyCode)
        switch event.type {
        case .keyDown:
            return interpretCapture(event: .keyDown, keyCode: keyCode,
                                    modifierIsDown: false,
                                    characters: event.charactersIgnoringModifiers)
        case .flagsChanged:
            let flags = event.cgEvent?.flags ?? CGEventFlags(rawValue: 0)
            let down = HotkeyKey.modifierDeviceFlag(for: keyCode)
                .map { HotkeyMonitor.isModifierDown(flags: flags, deviceFlag: $0) } ?? false
            return interpretCapture(event: .flagsChanged, keyCode: keyCode,
                                    modifierIsDown: down, characters: nil)
        default:
            return .ignore
        }
    }

    // MARK: Lifecycle

    /// Begin capturing. Idempotent. The local monitor SWALLOWS the captured key
    /// (returns nil) so pressing a letter while recording never leaks into the
    /// Settings UI; release edges pass through untouched.
    func start() {
        guard monitor == nil else { return }
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            switch HotkeyRecorder.outcome(for: event) {
            case .captured(let key):
                self.finish()
                self.onCapture(key)
                return nil
            case .cancelled:
                self.finish()
                self.onCancel()
                return nil
            case .ignore:
                return event
            }
        }
    }

    /// Stop capturing without firing a callback (e.g. the field lost focus).
    func stop() { finish() }

    private func finish() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isCapturing = false
    }
}
