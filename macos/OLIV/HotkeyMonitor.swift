// Global push-to-talk hotkey — a Swift port of app/hotkey.py (W1-T2).
//
// Wave-1 built and debugged this against real macOS failure modes; this file
// ports the *semantics* at behavioral parity, split in two:
//
//   • PushToTalkStateMachine — the pure, OS-free state machine (the `_recording`
//     flag logic of app/hotkey.py's PushToTalkListener: _press_hold /
//     _release_hold / stop() resync). It is driven purely by (event, timestamp)
//     inputs so it unit-tests with NO Input Monitoring / Accessibility grant —
//     see OLIVTests/HotkeyStateMachineTests, which port the pure-hold checks
//     from app/__main__.py's --hotkey-unittest.
//
//   • HotkeyMonitor — a thin CGEventTap wrapper that turns the configured keys'
//     events into the state machine's inputs and fires on_press / on_release.
//     Parameterized by one or more HotkeyKey values (primary + optional
//     secondary): either key holds to record; release fires when both are up.
//     A MODIFIER key arrives as a `flagsChanged` event and is matched by
//     keycode + its device-dependent raw flag (NX_DEVICE*KEYMASK) — presence of
//     the bit IS the press, absence IS the release — exactly as pynput's darwin
//     backend keys on the vk in the Python listener. F19 is NOT a modifier (no
//     device flag): it arrives as `keyDown`/`keyUp`, so the tap listens for those
//     and ignores auto-repeat. Mixed modifier + regular bindings open both
//     event channels on the same tap.
//
// Threading / callback contract (port of hotkey.py's): on_press / on_release
// fire on the TAP THREAD (a dedicated CFRunLoop thread, like pynput's listener
// thread). Do NOT block in them — hand heavy work to a worker (DictationController
// does exactly that). The one exception, mirroring the Python: the *balancing*
// on_release that stop() fires when torn down mid-hold runs synchronously on
// stop()'s caller thread.
//
// Permissions: a global CGEventTap needs macOS Input Monitoring granted. The
// wrapper detects tap-creation failure and surfaces it as a typed StartError
// (the onboarding UI consumes that later) — it never crashes. Preflight with
// HotkeyMonitor.hasInputMonitoringAccess() (Quartz CGPreflightListenEventAccess,
// never prompts), mirroring app.hotkey.check_event_access().

import AppKit
import CoreGraphics
import Foundation

// MARK: - Selectable push-to-talk keys

/// One selectable push-to-talk key. Started (W3-T4) as the five names the Python
/// `_KEY_ATTR_MAP` offered; W4-T2 generalizes it to ANY key the recorder captures
/// while keeping those five as clean, named presets.
///
/// A modifier key is matched on a `flagsChanged` event by its device-dependent
/// raw flag bit (`deviceFlag`, an NX_DEVICE*KEYMASK from IOKit's ev_keymap):
/// the bit is set while the key is physically down, cleared on release. A
/// non-modifier key (letters, F-keys, …) has `deviceFlag == nil` — it is matched
/// on `keyDown`/`keyUp` events by keycode instead. The CGEventTap wrapper's
/// matching logic (below) is already general over (keycode, deviceFlag), so
/// arbitrary keys "just work" once the recorder builds the right pair — the whole
/// W4-T2 generalization lives in this model + `modifierDeviceFlag`, not the tap.
///
/// PERSISTENCE / BACK-COMPAT: `id` is what the settings store round-trips. The
/// five presets keep their original short ids ("right_option", "f19", …) so
/// pre-W4 stored values migrate transparently; a recorded arbitrary key persists
/// as a general encoding `hk:<keyCode>:<mod|key>:<displayName>` (see `resolve`).
struct HotkeyKey: Equatable, Identifiable {
    let id: String            // config name, e.g. "right_option", "f19"
    let displayName: String   // human label for the picker, e.g. "Right Option"
    let keyCode: CGKeyCode    // kVK_* virtual keycode
    /// NX_DEVICE*KEYMASK bit set while this modifier is down, or nil for a
    /// non-modifier key (F19) that has no device flag.
    let deviceFlag: UInt64?

    /// A modifier (matched via flagsChanged) vs a regular key (keyDown/keyUp).
    var isModifier: Bool { deviceFlag != nil }

    // keycodes: kVK_RightOption 0x3D, kVK_Option(left) 0x3A, kVK_RightCommand
    // 0x36, kVK_RightControl 0x3E, kVK_F19 0x50. device flags: right-alt 0x40,
    // left-alt 0x20, right-cmd 0x10, right-ctrl 0x2000 (NX_DEVICE*KEYMASK).
    static let rightOption  = HotkeyKey(id: "right_option",  displayName: "Right Option",  keyCode: 0x3D, deviceFlag: 0x40)
    static let leftOption   = HotkeyKey(id: "left_option",   displayName: "Left Option",   keyCode: 0x3A, deviceFlag: 0x20)
    static let rightCommand = HotkeyKey(id: "right_command", displayName: "Right Command", keyCode: 0x36, deviceFlag: 0x10)
    static let rightControl = HotkeyKey(id: "right_control", displayName: "Right Control", keyCode: 0x3E, deviceFlag: 0x2000)
    static let f19          = HotkeyKey(id: "f19",           displayName: "F19",           keyCode: 0x50, deviceFlag: nil)

    /// The five keys offered in Settings, in menu order (default first).
    static let all: [HotkeyKey] = [rightOption, leftOption, rightCommand, rightControl, f19]

    /// The default, matching the Python config's `hotkey = "right_option"`.
    static let `default` = rightOption

    /// Prefix for a general (recorded arbitrary key) encoding.
    static let generalPrefix = "hk:"

    /// Resolve a stored config id → key, falling back to the Right Option
    /// default for an unknown/legacy id — never a hard error, mirroring the
    /// Python config's "unknown value falls back to the default" philosophy.
    ///
    /// Three cases, in order: (1) a general encoding `hk:…` from the W4-T2
    /// recorder (decoded case-sensitively — display names carry case); (2) one of
    /// the five legacy preset ids (case-insensitive, pre-W4 back-compat);
    /// (3) anything else → the default.
    static func resolve(_ id: String?) -> HotkeyKey {
        let raw = (id ?? "").trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix(generalPrefix) {
            return decodeGeneral(raw) ?? `default`
        }
        let key = raw.lowercased()
        return all.first { $0.id == key } ?? `default`
    }

    // MARK: - Arbitrary-key generalization (W4-T2)

    /// The NX_DEVICE*KEYMASK / secondary-fn bit set in a `flagsChanged` event's
    /// raw flags while `keyCode`'s modifier is physically down — the full table
    /// of the nine capturable modifier keycodes. nil = not a device modifier
    /// (so the key rides the keyDown/keyUp path). The four preset modifiers'
    /// masks agree with this table by construction (see the presets above).
    static func modifierDeviceFlag(for keyCode: CGKeyCode) -> UInt64? {
        switch keyCode {
        case 0x3A: return 0x20       // Left Option  (NX_DEVICELALTKEYMASK)
        case 0x3D: return 0x40       // Right Option (NX_DEVICERALTKEYMASK)
        case 0x37: return 0x08       // Left Command (NX_DEVICELCMDKEYMASK)
        case 0x36: return 0x10       // Right Command(NX_DEVICERCMDKEYMASK)
        case 0x3B: return 0x01       // Left Control (NX_DEVICELCTLKEYMASK)
        case 0x3E: return 0x2000     // Right Control(NX_DEVICERCTLKEYMASK)
        case 0x38: return 0x02       // Left Shift   (NX_DEVICELSHIFTKEYMASK)
        case 0x3C: return 0x04       // Right Shift  (NX_DEVICERSHIFTKEYMASK)
        case 0x3F: return 0x800000   // Fn           (kCGEventFlagMaskSecondaryFn)
        default:   return nil
        }
    }

    /// A preset whose keycode matches (so a captured Right Option / F19 / … keeps
    /// its clean id + label rather than a general encoding).
    static func preset(forKeyCode keyCode: CGKeyCode) -> HotkeyKey? {
        all.first { $0.keyCode == keyCode }
    }

    /// Build a REGULAR (keyDown/keyUp) key from a captured keycode — letters,
    /// F-keys, etc. Canonicalizes to a preset when one matches (e.g. F19).
    static func regularKey(keyCode: CGKeyCode, characters: String?) -> HotkeyKey {
        if let preset = preset(forKeyCode: keyCode), !preset.isModifier { return preset }
        let name = label(forKeyCode: keyCode, characters: characters)
        return HotkeyKey(id: generalID(keyCode: keyCode, isModifier: false, displayName: name),
                         displayName: name, keyCode: keyCode, deviceFlag: nil)
    }

    /// Build a MODIFIER (flagsChanged) key from a captured keycode. Canonicalizes
    /// to a preset when one matches; an unknown keycode falls back to a regular
    /// key (defensive — the recorder only offers the nine device modifiers).
    static func modifierKey(keyCode: CGKeyCode) -> HotkeyKey {
        if let preset = preset(forKeyCode: keyCode), preset.isModifier { return preset }
        guard let flag = modifierDeviceFlag(for: keyCode) else {
            return regularKey(keyCode: keyCode, characters: nil)
        }
        let name = label(forKeyCode: keyCode, characters: nil)
        return HotkeyKey(id: generalID(keyCode: keyCode, isModifier: true, displayName: name),
                         displayName: name, keyCode: keyCode, deviceFlag: flag)
    }

    /// Does holding `keyCode` type text into the focused field? True for
    /// letters/digits/punctuation/space (dictation would insert them while held);
    /// false for modifiers and function/navigation keys. Pure — drives the
    /// inline recorder warning ("This key types text …"). Testable, no OS.
    static func typesText(keyCode: CGKeyCode) -> Bool {
        if modifierDeviceFlag(for: keyCode) != nil { return false }   // a modifier
        if functionAndNavKeyCodes.contains(keyCode) { return false }  // F-keys / nav
        return true
    }

    /// Function + navigation keycodes that are safe to hold (never emit text):
    /// F1–F20, Escape, the arrows, and the Home/End/Page/ForwardDelete cluster.
    static let functionAndNavKeyCodes: Set<CGKeyCode> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,   // F1–F10
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,   // F11–F20
        0x35,                                                          // Escape
        0x7B, 0x7C, 0x7D, 0x7E,                                        // ← → ↓ ↑
        0x73, 0x77, 0x74, 0x79, 0x75, 0x72,                            // Home/End/PgUp/PgDn/FwdDel/Help
    ]

    // MARK: General encoding (keycode + kind + display name)

    private static func generalID(keyCode: CGKeyCode, isModifier: Bool, displayName: String) -> String {
        "\(generalPrefix)\(keyCode):\(isModifier ? "mod" : "key"):\(displayName)"
    }

    /// Decode `hk:<keyCode>:<mod|key>:<displayName>` back into a key. Prefer a
    /// canonical label from the keycode (Left/Right Control, F-keys, …) over
    /// the name embedded in the id — keycode is the source of truth for what
    /// the tap matches; a stale/truncated stored name must not mislabel it.
    private static func decodeGeneral(_ raw: String) -> HotkeyKey? {
        let body = raw.dropFirst(generalPrefix.count)
        let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = UInt16(parts[0]) else { return nil }
        let keyCode = CGKeyCode(code)
        let storedName = String(parts[2])
        guard !storedName.isEmpty else { return nil }
        let isModifier = (parts[1] == "mod")
        let flag: UInt64? = isModifier ? modifierDeviceFlag(for: keyCode) : nil
        // A "mod" encoding whose keycode isn't a known device modifier is corrupt.
        if isModifier && flag == nil { return nil }
        let name = modifierName(keyCode) ?? specialKeyName(keyCode) ?? storedName
        return HotkeyKey(id: raw, displayName: name, keyCode: keyCode, deviceFlag: flag)
    }

    // MARK: Human labels

    /// A human label for a captured keycode: the modifier/special-key name when
    /// known, else the typed character (uppercased), else a hex fallback.
    static func label(forKeyCode keyCode: CGKeyCode, characters: String?) -> String {
        if let name = modifierName(keyCode) { return name }
        if let name = specialKeyName(keyCode) { return name }
        if let chars = characters, let scalar = chars.unicodeScalars.first,
           scalar.value >= 0x20, scalar.value != 0x7F {
            return chars.uppercased()
        }
        return String(format: "Key 0x%02X", Int(keyCode))
    }

    private static func modifierName(_ keyCode: CGKeyCode) -> String? {
        switch keyCode {
        case 0x3A: return "Left Option"
        case 0x3D: return "Right Option"
        case 0x37: return "Left Command"
        case 0x36: return "Right Command"
        case 0x3B: return "Left Control"
        case 0x3E: return "Right Control"
        case 0x38: return "Left Shift"
        case 0x3C: return "Right Shift"
        case 0x3F: return "Fn"
        default:   return nil
        }
    }

    private static func specialKeyName(_ keyCode: CGKeyCode) -> String? {
        switch keyCode {
        // ANSI letters (layout-independent keycodes) — so a persisted chord
        // like Control+Shift+Z reloads as "Z", not "Key 0x06".
        case 0x00: return "A"; case 0x0B: return "B"; case 0x08: return "C"
        case 0x02: return "D"; case 0x0E: return "E"; case 0x03: return "F"
        case 0x05: return "G"; case 0x04: return "H"; case 0x22: return "I"
        case 0x26: return "J"; case 0x28: return "K"; case 0x25: return "L"
        case 0x2E: return "M"; case 0x2D: return "N"; case 0x1F: return "O"
        case 0x23: return "P"; case 0x0C: return "Q"; case 0x0F: return "R"
        case 0x01: return "S"; case 0x11: return "T"; case 0x20: return "U"
        case 0x09: return "V"; case 0x0D: return "W"; case 0x07: return "X"
        case 0x10: return "Y"; case 0x06: return "Z"
        case 0x7A: return "F1";  case 0x78: return "F2";  case 0x63: return "F3"
        case 0x76: return "F4";  case 0x60: return "F5";  case 0x61: return "F6"
        case 0x62: return "F7";  case 0x64: return "F8";  case 0x65: return "F9"
        case 0x6D: return "F10"; case 0x67: return "F11"; case 0x6F: return "F12"
        case 0x69: return "F13"; case 0x6B: return "F14"; case 0x71: return "F15"
        case 0x6A: return "F16"; case 0x40: return "F17"; case 0x4F: return "F18"
        case 0x50: return "F19"; case 0x5A: return "F20"
        case 0x35: return "Escape";  case 0x31: return "Space"
        case 0x24: return "Return";  case 0x30: return "Tab"
        case 0x33: return "Delete";  case 0x75: return "Forward Delete"
        case 0x7B: return "Left Arrow";  case 0x7C: return "Right Arrow"
        case 0x7D: return "Down Arrow";  case 0x7E: return "Up Arrow"
        case 0x73: return "Home";  case 0x77: return "End"
        case 0x74: return "Page Up";  case 0x79: return "Page Down"
        default:   return nil
        }
    }
}

// MARK: - Push-to-talk chord (one or more keys held together)

/// A push-to-talk binding: a single key (Right Option) OR a chord
/// (Control + Option + F17). All keys in the chord must be down to start
/// recording; releasing any one stops. Distinct from primary/secondary, which
/// are alternate bindings (OR) — within one chord the keys are AND.
///
/// Persistence: a single-key chord round-trips as the underlying HotkeyKey.id
/// (`right_option`, `hk:…`) so pre-chord stores keep working. Multi-key chords
/// use `chord:<code><m|k>+…` (e.g. `chord:59m+58m+64k`).
struct HotkeyChord: Equatable, Identifiable {
    /// Non-empty, unique-by-keycode parts (modifiers first in capture order,
    /// then the main key when present).
    let keys: [HotkeyKey]

    init(keys: [HotkeyKey]) {
        var seen = Set<CGKeyCode>()
        var unique: [HotkeyKey] = []
        for k in keys where seen.insert(k.keyCode).inserted {
            unique.append(k)
        }
        precondition(!unique.isEmpty, "HotkeyChord requires at least one key")
        self.keys = unique
    }

    /// Single-key convenience.
    init(key: HotkeyKey) { self.init(keys: [key]) }

    static let `default` = HotkeyChord(key: .default)

    /// Default undo-last-dictation binding: Control + Shift + Z. The undo tap
    /// swallows the Z key event when the modifiers are held so the host app
    /// does not also see Ctrl+Shift+Z as Redo while we synthesize ⌘Z.
    static let defaultUndo = HotkeyChord(keys: [
        HotkeyKey.modifierKey(keyCode: 0x3B),                      // Left Control
        HotkeyKey.modifierKey(keyCode: 0x38),                      // Left Shift
        HotkeyKey.regularKey(keyCode: 0x06, characters: "z"),      // Z
    ])

    /// Previous ship default (F18). Settings migrates this id → `defaultUndo`.
    static let legacyDefaultUndoF18 = HotkeyChord(
        key: HotkeyKey.regularKey(keyCode: 0x4F, characters: nil))

    var id: String {
        if keys.count == 1 { return keys[0].id }
        return "chord:" + keys.map { "\($0.keyCode)\($0.isModifier ? "m" : "k")" }
            .joined(separator: "+")
    }

    var displayName: String {
        keys.map(\.displayName).joined(separator: " + ")
    }

    /// True when any part would type text into the focused field while held.
    var typesText: Bool {
        keys.contains { HotkeyKey.typesText(keyCode: $0.keyCode) }
    }

    static let chordPrefix = "chord:"

    /// Resolve a stored id → chord. Single-key ids (legacy presets / `hk:…`)
    /// become one-key chords; `chord:…` decodes multi-key; unknown → default.
    static func resolve(_ id: String?) -> HotkeyChord {
        let raw = (id ?? "").trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix(chordPrefix) {
            return decodeChord(raw) ?? .default
        }
        return HotkeyChord(key: HotkeyKey.resolve(raw))
    }

    /// Like resolve, but blank/nil → nil (for the optional secondary slot).
    static func resolveOptional(_ id: String?) -> HotkeyChord? {
        let raw = (id ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return resolve(raw)
    }

    private static func decodeChord(_ raw: String) -> HotkeyChord? {
        let body = String(raw.dropFirst(chordPrefix.count))
        let parts = body.split(separator: "+", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var keys: [HotkeyKey] = []
        for part in parts {
            guard let kind = part.last, kind == "m" || kind == "k" else { return nil }
            guard let code = UInt16(part.dropLast()) else { return nil }
            let keyCode = CGKeyCode(code)
            if kind == "m" {
                guard HotkeyKey.modifierDeviceFlag(for: keyCode) != nil else { return nil }
                keys.append(HotkeyKey.modifierKey(keyCode: keyCode))
            } else {
                keys.append(HotkeyKey.regularKey(keyCode: keyCode, characters: nil))
            }
        }
        guard !keys.isEmpty else { return nil }
        return HotkeyChord(keys: keys)
    }
}

// MARK: - Chord hold aggregator (AND within chord, OR across bindings)

/// Tracks primary/secondary chords. A chord activates only when EVERY part is
/// down (so Control alone does not fire Control+Option+F17). Across bindings,
/// any fully-held chord keeps recording open (primary OR secondary).
struct MultiChordHoldTracker: Equatable {
    enum Edge: Equatable {
        case none
        case pressed
        case released
    }

    private struct ChordState: Equatable {
        let required: Set<CGKeyCode>
        var held: Set<CGKeyCode> = []
        var isComplete: Bool { !required.isEmpty && required.isSubset(of: held) }
    }

    private var chords: [ChordState]
    private(set) var isActive = false

    init(chords: [HotkeyChord]) {
        self.chords = chords.map { ChordState(required: Set($0.keys.map(\.keyCode))) }
    }

    mutating func set(_ keyCode: CGKeyCode, down: Bool) -> Edge {
        let wasActive = isActive
        for i in chords.indices {
            guard chords[i].required.contains(keyCode) else { continue }
            if down { chords[i].held.insert(keyCode) }
            else { chords[i].held.remove(keyCode) }
        }
        isActive = chords.contains { $0.isComplete }
        if !wasActive && isActive { return .pressed }
        if wasActive && !isActive { return .released }
        return .none
    }

    /// True when every OTHER key in some chord that contains `keyCode` is
    /// already held — used to swallow e.g. Z only while Ctrl+Shift are down.
    func hasAllOthersHeld(for keyCode: CGKeyCode) -> Bool {
        for chord in chords {
            guard chord.required.contains(keyCode) else { continue }
            let others = chord.required.subtracting([keyCode])
            if others.isSubset(of: chord.held) { return true }
        }
        return false
    }

    mutating func reset() {
        for i in chords.indices { chords[i].held.removeAll() }
        isActive = false
    }
}

// MARK: - Multi-key hold aggregator (legacy OR of single keys — tests)

/// Tracks which of N configured push-to-talk keys are physically down and
/// collapses them to a single press/release edge: first key down → pressed,
/// last key up → released. Prefer `MultiChordHoldTracker` for real bindings.
struct MultiKeyHoldTracker: Equatable {
    typealias Edge = MultiChordHoldTracker.Edge

    private(set) var held: Set<CGKeyCode> = []

    mutating func set(_ keyCode: CGKeyCode, down: Bool) -> Edge {
        let wasEmpty = held.isEmpty
        if down {
            held.insert(keyCode)
            return wasEmpty ? .pressed : .none
        }
        held.remove(keyCode)
        return (!wasEmpty && held.isEmpty) ? .released : .none
    }

    mutating func reset() { held.removeAll() }
}

// MARK: - Pure, OS-free state machine

/// Push-to-talk state machine. Direct port of the `_recording`-flag logic in
/// app/hotkey.py's PushToTalkListener (_press_hold / _release_hold / the stop()
/// resync). Deterministic and permission-free: feed it `(event, timestamp)`
/// inputs, get back the callbacks to fire.
///
/// NOTE (future work): app/hotkey.py also has an opt-in double-tap-to-toggle
/// mode (`toggle_double_tap`, off by default in the prototype). It is
/// deliberately NOT ported here — pure push-to-talk (hold to record) only. The
/// `timestamp` seam below is where a future double-tap window would hook in.
struct PushToTalkStateMachine {
    enum Event: Equatable {
        /// The hotkey went down at `timestamp` (seconds, monotonic).
        case keyDown(timestamp: TimeInterval)
        /// The hotkey came up at `timestamp`.
        case keyUp(timestamp: TimeInterval)
        /// Monitoring stopped / torn down (port of PushToTalkListener.stop()).
        /// Fires a balancing release if a hold was active so downstream is
        /// never left stuck "recording forever".
        case stop
    }

    enum Action: Equatable {
        case fireOnPress
        case fireOnRelease
    }

    /// Why the last `handle(_:)` produced no action — for logging parity with
    /// the Python `logger.warning(...)` lines. Cleared at the start of each call.
    enum Warning: Equatable {
        /// A press while already recording (OS auto-repeat or a missed
        /// release) — debounced to a single on_press.
        case debouncedRepeatPress
        /// A release with no active press — ignored (resync).
        case spuriousReleaseIgnored
    }

    private(set) var isRecording = false
    private(set) var pressTimestamp: TimeInterval?
    private(set) var lastWarning: Warning?

    /// Feed one input; returns the callbacks the caller must fire (outside any
    /// lock, mirroring app/hotkey.py's `_safe_call`).
    mutating func handle(_ event: Event) -> [Action] {
        lastWarning = nil
        switch event {
        case let .keyDown(timestamp):
            // Port of _press_hold: debounce on the flag, not a timer — a press
            // while already recording is an OS auto-repeat / missed release.
            if isRecording {
                lastWarning = .debouncedRepeatPress
                return []
            }
            isRecording = true
            pressTimestamp = timestamp
            return [.fireOnPress]

        case .keyUp:
            // Port of _release_hold: a release with no active press is spurious.
            if !isRecording {
                lastWarning = .spuriousReleaseIgnored
                return []
            }
            isRecording = false
            pressTimestamp = nil
            return [.fireOnRelease]

        case .stop:
            // Port of PushToTalkListener.stop()'s resync: if a hold is active,
            // fire the balancing on_release so no stuck-recording state remains.
            if isRecording {
                isRecording = false
                pressTimestamp = nil
                return [.fireOnRelease]
            }
            return []
        }
    }
}

// MARK: - CGEventTap wrapper

/// Installs a global CGEventTap on `flagsChanged`, drives a
/// `PushToTalkStateMachine`, and fires press/release callbacks. Reusable across
/// start()/stop() cycles (each start() builds a fresh tap + run-loop thread,
/// like pynput Listeners are one-shot).
final class HotkeyMonitor {
    /// Tap creation / lifecycle failures, surfaced typed (never a crash) so the
    /// onboarding UI can react. Mirrors app.hotkey's permission gate.
    enum StartError: Error, CustomStringConvertible {
        /// Already started; call stop() first (port of the Python RuntimeError).
        case alreadyRunning
        /// CGEvent.tapCreate returned nil — Input Monitoring is not granted (or
        /// unavailable in this environment). The tap is the app's only source of
        /// key events; the caller should route the user to grant access.
        case tapCreationFailed

        var description: String {
            switch self {
            case .alreadyRunning:
                return "HotkeyMonitor already started — call stop() before starting again"
            case .tapCreationFailed:
                return "CGEvent tap could not be created — grant Input Monitoring "
                    + "(System Settings › Privacy & Security › Input Monitoring), then relaunch"
            }
        }
    }

    /// Right Option: keycode 0x3D (kVK_RightOption). Left Option is 0x3A — we
    /// filter by keycode so the two never cross, exactly as pynput maps vk 0x3D
    /// → Key.alt_r in app/hotkey.py. Kept as the default; the picker overrides
    /// it via `HotkeyKey` (W3-T4).
    static let rightOptionKeyCode: CGKeyCode = HotkeyKey.rightOption.keyCode

    /// NX_DEVICERALTKEYMASK — the device-dependent raw flag bit set while Right
    /// Option is physically down. A `flagsChanged` event carries no up/down bit
    /// of its own; presence of this bit in the raw event flags IS the press,
    /// absence IS the release. (Left Option uses 0x20; we already keyed on the
    /// keycode, so this also double-confirms right-vs-left.)
    static let rightOptionRawFlag: UInt64 = HotkeyKey.rightOption.deviceFlag!

    /// The chords this monitor listens for. Within a chord every key must be
    /// down (AND); across chords, any complete chord activates (OR) — see
    /// `MultiChordHoldTracker`.
    let chords: [HotkeyChord]
    /// Flattened unique keys across all chords (event routing).
    private let keys: [HotkeyKey]
    /// Convenience for the single-key / single-chord case (tests).
    var key: HotkeyKey { keys[0] }
    private let onPress: () -> Void
    private let onRelease: () -> Void
    /// When true, matching non-modifier keyDown/keyUp events are removed from
    /// the stream (active tap) once the chord's other keys are held — so
    /// Ctrl+Shift+Z does not also reach the host as Redo. Push-to-talk keeps
    /// the default false (listenOnly; never swallow).
    private let swallowsMatchedKeyEvents: Bool

    // State machine + its lock. The tap callback (tap thread) and stop()
    // (caller thread) both touch it, so every access is serialized here; the
    // resulting callbacks are always fired OUTSIDE the lock.
    private let stateLock = NSLock()
    private var state = PushToTalkStateMachine()
    private var holdTracker: MultiChordHoldTracker

    // CGEventTap plumbing (guarded by stateLock for start/stop coordination).
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    convenience init(
        key: HotkeyKey = .default,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.init(chords: [HotkeyChord(key: key)], onPress: onPress, onRelease: onRelease)
    }

    convenience init(
        keys: [HotkeyKey],
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        // Legacy: a list of single keys means OR bindings (primary/secondary).
        self.init(chords: keys.map { HotkeyChord(key: $0) },
                  onPress: onPress, onRelease: onRelease)
    }

    init(
        chords: [HotkeyChord],
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        swallowsMatchedKeyEvents: Bool = false
    ) {
        var seenChord = Set<String>()
        var uniqueChords: [HotkeyChord] = []
        for c in chords where seenChord.insert(c.id).inserted {
            uniqueChords.append(c)
        }
        precondition(!uniqueChords.isEmpty, "HotkeyMonitor requires at least one chord")
        self.chords = uniqueChords

        var seenKey = Set<CGKeyCode>()
        var flat: [HotkeyKey] = []
        for k in uniqueChords.flatMap(\.keys) where seenKey.insert(k.keyCode).inserted {
            flat.append(k)
        }
        self.keys = flat
        self.holdTracker = MultiChordHoldTracker(chords: uniqueChords)
        self.onPress = onPress
        self.onRelease = onRelease
        self.swallowsMatchedKeyEvents = swallowsMatchedKeyEvents
    }

    // MARK: Permission preflight (mirrors app.hotkey.check_event_access)

    /// Input Monitoring granted? Quartz CGPreflightListenEventAccess — never
    /// prompts. False if the tap would receive no events.
    static func hasInputMonitoringAccess() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Best-effort: ask macOS to prompt for Input Monitoring and register this
    /// process in the Settings list. No-op if already granted.
    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return eventTap != nil
    }

    // MARK: Lifecycle

    /// Install the tap and begin listening on a dedicated run-loop thread.
    /// Throws `StartError.tapCreationFailed` when Input Monitoring is missing
    /// (the onboarding gate), `.alreadyRunning` if a tap is live.
    func start() throws {
        stateLock.lock()
        if eventTap != nil {
            stateLock.unlock()
            throw StartError.alreadyRunning
        }
        state = PushToTalkStateMachine() // fresh state per start(), like _reset_state()
        holdTracker.reset()
        stateLock.unlock()

        // A modifier rides on flagsChanged; a regular key (F19) on keyDown/keyUp.
        // Mixed primary+secondary (e.g. Option + F19) needs both channels.
        var mask: CGEventMask = 0
        if keys.contains(where: { $0.isModifier }) {
            mask |= CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        }
        if keys.contains(where: { !$0.isModifier }) {
            mask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
                 | CGEventMask(1 << CGEventType.keyUp.rawValue)
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // Push-to-talk: .listenOnly — observe without eating modifiers.
        // Undo (swallowsMatchedKeyEvents): active tap so we can drop the letter
        // key (Ctrl+Shift+Z must not also reach the host as Redo).
        // `.default` is unavailable as a Swift member (keyword); rawValue 0 is
        // kCGEventTapOptionDefault — an active filter that may swallow events.
        let options: CGEventTapOptions = swallowsMatchedKeyEvents
            ? CGEventTapOptions(rawValue: 0)! : .listenOnly
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: selfPtr
        ) else {
            throw StartError.tapCreationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        stateLock.lock()
        eventTap = tap
        runLoopSource = source
        stateLock.unlock()

        // Run the tap on its own CFRunLoop thread (like pynput's listener
        // thread), so callbacks fire off the main thread and never stall the UI.
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.stateLock.lock()
            self?.tapRunLoop = runLoop
            self?.stateLock.unlock()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            // Returns once the mach port is invalidated / run loop stopped by stop().
        }
        thread.name = "com.oliv.hotkey-tap"
        stateLock.lock()
        tapThread = thread
        stateLock.unlock()
        thread.start()
    }

    /// Stop the tap, tear down the thread, and resync. If a hold was active,
    /// fires the balancing on_release (on THIS thread) so downstream is never
    /// left stuck recording — the mid-monitoring-stop resync of hotkey.py.stop().
    func stop() {
        stateLock.lock()
        let tap = eventTap
        let source = runLoopSource
        let runLoop = tapRunLoop
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        let actions = state.handle(.stop)
        holdTracker.reset()
        stateLock.unlock()

        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Invalidating the mach port drops the run-loop source, which lets
            // CFRunLoopRun() on the tap thread return even if we never captured
            // its CFRunLoop ref (avoids a start()/stop() race leaking the thread).
            CFMachPortInvalidate(tap)
        }
        if let runLoop = runLoop {
            if let source = source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFRunLoopStop(runLoop)
        }

        fire(actions) // balancing on_release, outside the lock (mirrors _safe_call)
    }

    deinit { stop() }

    // MARK: Tap-thread entry points

    /// Called on the tap thread for each flagsChanged event (MODIFIER keys).
    fileprivate func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        guard let match = keys.first(where: { $0.isModifier && Int64($0.keyCode) == keyCode }),
              let deviceFlag = match.deviceFlag else { return }
        let isDown = HotkeyMonitor.isModifierDown(flags: flags, deviceFlag: deviceFlag)
        applyHold(keyCode: match.keyCode, isDown: isDown)
    }

    /// Called on the tap thread for keyDown/keyUp events (a REGULAR key, F19).
    /// OS auto-repeat resends keyDown while held; the state machine debounces a
    /// repeat press to nothing, but we drop it here too so it never even reaches
    /// the machine (parity with the flagsChanged path, which sees one edge).
    fileprivate func handleKeyEvent(keyCode: Int64, isDown: Bool, isRepeat: Bool) {
        guard let match = keys.first(where: { !$0.isModifier && Int64($0.keyCode) == keyCode }) else {
            return
        }
        if isDown && isRepeat { return }
        applyHold(keyCode: match.keyCode, isDown: isDown)
    }

    /// Shared tail: fold a per-key physical edge into the multi-key hold
    /// tracker, then feed the resulting press/release into the state machine.
    private func applyHold(keyCode: CGKeyCode, isDown: Bool) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let edge = holdTracker.set(keyCode, down: isDown)
        let actions: [PushToTalkStateMachine.Action]
        switch edge {
        case .pressed:
            actions = state.handle(.keyDown(timestamp: timestamp))
        case .released:
            actions = state.handle(.keyUp(timestamp: timestamp))
        case .none:
            actions = []
        }
        stateLock.unlock()
        fire(actions)
    }

    /// macOS can disable a tap it thinks is too slow (or on user input); the
    /// documented recovery is to simply re-enable it. Called on the tap thread.
    fileprivate func reenableTap() {
        stateLock.lock()
        let tap = eventTap
        stateLock.unlock()
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: Helpers

    /// Is the target modifier physically down, per the raw event flags? Pure and
    /// testable (see HotkeyKeyMapTests): the key's NX_DEVICE*KEYMASK bit is set
    /// while it is held, cleared on release. Parameterized over `deviceFlag`
    /// (W3-T4) so it works for any of the offered modifiers, not just Right
    /// Option; keying on the exact device bit keeps left vs right distinct.
    static func isModifierDown(flags: CGEventFlags, deviceFlag: UInt64) -> Bool {
        (flags.rawValue & deviceFlag) != 0
    }

    private func fire(_ actions: [PushToTalkStateMachine.Action]) {
        for action in actions {
            switch action {
            case .fireOnPress: onPress()
            case .fireOnRelease: onRelease()
            }
        }
    }

    /// Swallow this regular key when the chord's other keys are held (undo path).
    fileprivate func shouldSwallowRegularKey(_ keyCode: Int64) -> Bool {
        guard swallowsMatchedKeyEvents else { return false }
        guard keys.contains(where: { !$0.isModifier && Int64($0.keyCode) == keyCode }) else {
            return false
        }
        stateLock.lock()
        let swallow = holdTracker.hasAllOthersHeld(for: CGKeyCode(keyCode))
        stateLock.unlock()
        return swallow
    }
}

// C-callable tap callback (no captured context, so it converts to the C
// function pointer CGEventTapCallBack expects). Recovers `self` from userInfo.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    var swallow = false
    switch type {
    case .flagsChanged:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        monitor.handleFlagsChanged(keyCode: keyCode, flags: event.flags)
    case .keyDown:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Decide swallow before mutating hold state on keyUp paths; for keyDown
        // modifiers must already be held, so check before inserting Z is correct.
        swallow = monitor.shouldSwallowRegularKey(keyCode)
        monitor.handleKeyEvent(keyCode: keyCode, isDown: true, isRepeat: isRepeat)
    case .keyUp:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Still swallow the matching keyUp while modifiers remain held.
        swallow = monitor.shouldSwallowRegularKey(keyCode)
        monitor.handleKeyEvent(keyCode: keyCode, isDown: false, isRepeat: false)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        monitor.reenableTap()
    default:
        break
    }
    if swallow { return nil }
    return Unmanaged.passUnretained(event)
}
