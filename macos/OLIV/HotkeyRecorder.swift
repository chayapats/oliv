// Hotkey "record shortcut" capture (W4-T2 Feature B). The Settings › General
// field that turns "Press a key…" into the next physical key OR chord the user
// builds, so the push-to-talk binding is not limited to the five presets.
//
// It mirrors the two channels HotkeyMonitor listens on, but on a LOCAL monitor
// (this app's key window only — the Settings window), never a global tap:
//
//   • flagsChanged → accumulate MODIFIERS (Option/Command/Control/Shift/Fn).
//     They are NOT captured on the down edge alone — that was the Ctrl-only bug:
//     Ctrl+Option+F17 was stored as just Control because Control fired first.
//   • keyDown      → a non-modifier (F17, letter, …) commits the chord as
//     currently-held modifiers + this key.
//   • modifier release with nothing else pressed → commit a modifier-only
//     binding (Right Option alone still works).
//   • Escape cancels.
//
// The DECISION lives in `HotkeyCaptureSession` (pure, hermetic). HotkeyRecorder
// is thin NSEvent plumbing around it.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Pure capture session (chord-aware)

/// Accumulates a push-to-talk binding while the user holds modifiers and/or
/// presses a main key. Pure over its inputs — HotkeyRecorderTests drives it
/// with no NSEvent / key window / run loop.
struct HotkeyCaptureSession: Equatable {
    enum Outcome: Equatable {
        case ignore
        case cancelled
        case captured(HotkeyChord)
    }

    /// Modifier keycodes held, in press order (so display reads naturally).
    private(set) var heldModifierCodes: [CGKeyCode] = []

    mutating func handle(event: HotkeyRecorder.CaptureEvent,
                         keyCode: CGKeyCode,
                         modifierIsDown: Bool,
                         characters: String?) -> Outcome {
        switch event {
        case .keyDown:
            if keyCode == HotkeyRecorder.escapeKeyCode { return .cancelled }
            // Modifier keys arrive as flagsChanged, not keyDown — ignore if one
            // somehow shows up here so we don't commit a half-built chord.
            if HotkeyKey.modifierDeviceFlag(for: keyCode) != nil { return .ignore }
            let mods = heldModifierCodes.map { HotkeyKey.modifierKey(keyCode: $0) }
            let main = HotkeyKey.regularKey(keyCode: keyCode, characters: characters)
            return .captured(HotkeyChord(keys: mods + [main]))

        case .flagsChanged:
            guard HotkeyKey.modifierDeviceFlag(for: keyCode) != nil else { return .ignore }
            if modifierIsDown {
                if !heldModifierCodes.contains(keyCode) {
                    heldModifierCodes.append(keyCode)
                }
                return .ignore   // wait for more modifiers or a main key
            }
            // Modifier released: if that clears the whole held set, commit the
            // modifiers that were down (single Right Option, or Ctrl+Alt alone).
            guard heldModifierCodes.contains(keyCode) else { return .ignore }
            let snapshot = heldModifierCodes
            heldModifierCodes.removeAll { $0 == keyCode }
            if heldModifierCodes.isEmpty {
                let keys = snapshot.map { HotkeyKey.modifierKey(keyCode: $0) }
                return .captured(HotkeyChord(keys: keys))
            }
            return .ignore
        }
    }
}

// MARK: - NSEvent plumbing

@MainActor
final class HotkeyRecorder: ObservableObject {
    /// What one captured event resolves to. Kept for older single-event tests;
    /// live capture uses `HotkeyCaptureSession` (chord-aware).
    enum CaptureOutcome: Equatable {
        case captured(HotkeyKey)
        case cancelled
        case ignore
    }

    enum CaptureEvent { case keyDown; case flagsChanged }

    nonisolated static let escapeKeyCode: CGKeyCode = 0x35

    @Published private(set) var isCapturing = false

    private var monitor: Any?
    private var session = HotkeyCaptureSession()
    private let onCapture: (HotkeyChord) -> Void
    private let onCancel: () -> Void

    init(onCapture: @escaping (HotkeyChord) -> Void, onCancel: @escaping () -> Void = {}) {
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    /// Back-compat: callers that still want a single HotkeyKey.
    convenience init(onCaptureKey: @escaping (HotkeyKey) -> Void,
                     onCancel: @escaping () -> Void = {}) {
        self.init(onCapture: { onCaptureKey($0.keys[0]) }, onCancel: onCancel)
    }

    deinit { if let monitor = monitor { NSEvent.removeMonitor(monitor) } }

    // MARK: Legacy single-event seam (modifier-down still captures immediately)

    /// Resolve one captured event. Pure over its arguments — the seam the DoD
    /// asks to unit-test (capture / cancel), with no OS events. `nonisolated` so
    /// it runs off the main actor (the hermetic tests call it synchronously).
    ///
    /// NOTE: this is the LEGACY single-event API (modifier-down captures
    /// immediately). Live Settings capture uses `HotkeyCaptureSession` so chords
    /// like Control+Option+F17 are not truncated to Control alone.
    nonisolated static func interpretCapture(event: CaptureEvent,
                                             keyCode: CGKeyCode,
                                             modifierIsDown: Bool,
                                             characters: String?) -> CaptureOutcome {
        switch event {
        case .keyDown:
            if keyCode == escapeKeyCode { return .cancelled }
            return .captured(HotkeyKey.regularKey(keyCode: keyCode, characters: characters))
        case .flagsChanged:
            guard HotkeyKey.modifierDeviceFlag(for: keyCode) != nil, modifierIsDown else {
                return .ignore
            }
            return .captured(HotkeyKey.modifierKey(keyCode: keyCode))
        }
    }

    /// Resolve a live NSEvent through the chord session.
    static func chordOutcome(session: inout HotkeyCaptureSession,
                             for event: NSEvent) -> HotkeyCaptureSession.Outcome {
        let keyCode = CGKeyCode(event.keyCode)
        switch event.type {
        case .keyDown:
            return session.handle(event: .keyDown, keyCode: keyCode,
                                  modifierIsDown: false,
                                  characters: event.charactersIgnoringModifiers)
        case .flagsChanged:
            let flags = event.cgEvent?.flags ?? CGEventFlags(rawValue: 0)
            let down = HotkeyKey.modifierDeviceFlag(for: keyCode)
                .map { HotkeyMonitor.isModifierDown(flags: flags, deviceFlag: $0) } ?? false
            return session.handle(event: .flagsChanged, keyCode: keyCode,
                                  modifierIsDown: down, characters: nil)
        default:
            return .ignore
        }
    }

    // MARK: Lifecycle

    /// Begin capturing. Idempotent. The local monitor SWALLOWS committed keys
    /// (returns nil) so pressing a letter while recording never leaks into the
    /// Settings UI; intermediate modifier edges pass through.
    func start() {
        guard monitor == nil else { return }
        isCapturing = true
        session = HotkeyCaptureSession()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            switch HotkeyRecorder.chordOutcome(session: &self.session, for: event) {
            case .captured(let chord):
                self.finish()
                self.onCapture(chord)
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

    func stop() { finish() }

    private func finish() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isCapturing = false
        session = HotkeyCaptureSession()
    }
}
