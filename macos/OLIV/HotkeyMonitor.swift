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
//   • HotkeyMonitor — a thin CGEventTap wrapper that turns the configured key's
//     events into the state machine's inputs and fires on_press / on_release.
//     It is parameterized by a HotkeyKey (W3-T4 Settings picker): the five keys
//     the Python `_KEY_ATTR_MAP` exposes to the UI (right_option default,
//     left_option, right_command, right_control, f19). A MODIFIER key arrives as
//     a `flagsChanged` event and is matched by keycode + its device-dependent
//     raw flag (NX_DEVICE*KEYMASK) — presence of the bit IS the press, absence
//     IS the release — exactly as pynput's darwin backend keys on the vk in the
//     Python listener. F19 is NOT a modifier (no device flag): it arrives as
//     `keyDown`/`keyUp`, so the tap listens for those and ignores auto-repeat.
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

    /// Decode `hk:<keyCode>:<mod|key>:<displayName>` back into a key (the display
    /// name may itself contain ':'). Any malformed field → nil (resolve → default).
    private static func decodeGeneral(_ raw: String) -> HotkeyKey? {
        let body = raw.dropFirst(generalPrefix.count)
        let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = UInt16(parts[0]) else { return nil }
        let keyCode = CGKeyCode(code)
        let name = String(parts[2])
        guard !name.isEmpty else { return nil }
        let isModifier = (parts[1] == "mod")
        let flag: UInt64? = isModifier ? modifierDeviceFlag(for: keyCode) : nil
        // A "mod" encoding whose keycode isn't a known device modifier is corrupt.
        if isModifier && flag == nil { return nil }
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

    /// The key this monitor listens for (keycode + optional device flag).
    let key: HotkeyKey
    private let onPress: () -> Void
    private let onRelease: () -> Void

    // State machine + its lock. The tap callback (tap thread) and stop()
    // (caller thread) both touch it, so every access is serialized here; the
    // resulting callbacks are always fired OUTSIDE the lock.
    private let stateLock = NSLock()
    private var state = PushToTalkStateMachine()

    // CGEventTap plumbing (guarded by stateLock for start/stop coordination).
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    init(
        key: HotkeyKey = .default,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.key = key
        self.onPress = onPress
        self.onRelease = onRelease
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
        stateLock.unlock()

        // A modifier key rides on flagsChanged; a regular key (F19) rides on
        // keyDown/keyUp. Tap only what this key needs.
        let mask: CGEventMask
        if key.isModifier {
            mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        } else {
            mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                 | CGEventMask(1 << CGEventType.keyUp.rawValue)
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // .listenOnly: we observe the key, we must NOT swallow it (push-to-talk
        // shouldn't eat the modifier from the rest of the system).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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
        guard let deviceFlag = key.deviceFlag else { return } // regular key: wrong channel
        guard keyCode == Int64(key.keyCode) else { return }   // not our key (e.g. Shift)
        let isDown = HotkeyMonitor.isModifierDown(flags: flags, deviceFlag: deviceFlag)
        feed(isDown: isDown)
    }

    /// Called on the tap thread for keyDown/keyUp events (a REGULAR key, F19).
    /// OS auto-repeat resends keyDown while held; the state machine debounces a
    /// repeat press to nothing, but we drop it here too so it never even reaches
    /// the machine (parity with the flagsChanged path, which sees one edge).
    fileprivate func handleKeyEvent(keyCode: Int64, isDown: Bool, isRepeat: Bool) {
        guard !key.isModifier else { return }                 // modifier: wrong channel
        guard keyCode == Int64(key.keyCode) else { return }   // not our key
        if isDown && isRepeat { return }
        feed(isDown: isDown)
    }

    /// Shared tail: turn a physical down/up into the state machine's input and
    /// fire the resulting callbacks outside the lock.
    private func feed(isDown: Bool) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let actions = state.handle(isDown ? .keyDown(timestamp: timestamp) : .keyUp(timestamp: timestamp))
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
    switch type {
    case .flagsChanged:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        monitor.handleFlagsChanged(keyCode: keyCode, flags: event.flags)
    case .keyDown:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        monitor.handleKeyEvent(keyCode: keyCode, isDown: true, isRepeat: isRepeat)
    case .keyUp:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        monitor.handleKeyEvent(keyCode: keyCode, isDown: false, isRepeat: false)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        monitor.reenableTap()
    default:
        break
    }
    // .listenOnly tap: pass the event through untouched.
    return Unmanaged.passUnretained(event)
}
