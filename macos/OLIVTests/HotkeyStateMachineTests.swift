// Pure push-to-talk state-machine tests — ports of the semantics checked by
// app/__main__.py's --hotkey-unittest (_run_hotkey_unittest). These drive the
// state machine directly with fake (event, timestamp) inputs: NO CGEventTap, NO
// Input Monitoring / Accessibility grant, fully deterministic.
//
// The double-tap-toggle checks (--hotkey-unittest tests 6 & 7) are intentionally
// NOT ported — that optional, off-by-default mode is future work (see the note
// in HotkeyMonitor.swift). We port the pure push-to-talk checks (tests 1–5) plus
// restart-clean, and add coverage for the raw-flag press/release decode the
// CGEventTap wrapper relies on.

import CoreGraphics
import XCTest
@testable import OLIV

final class HotkeyStateMachineTests: XCTestCase {
    // --hotkey-unittest [1]: basic hold — press then release fires each once.
    func testBasicHold() {
        var sm = PushToTalkStateMachine()
        XCTAssertEqual(sm.handle(.keyDown(timestamp: 0)), [.fireOnPress])
        XCTAssertEqual(sm.handle(.keyUp(timestamp: 1)), [.fireOnRelease])
        XCTAssertFalse(sm.isRecording)
    }

    // --hotkey-unittest [2]: debounce — press, press, press, release => one of each.
    func testDebounceRepeatedPresses() {
        var sm = PushToTalkStateMachine()
        XCTAssertEqual(sm.handle(.keyDown(timestamp: 0)), [.fireOnPress])
        XCTAssertEqual(sm.handle(.keyDown(timestamp: 0.1)), [])
        XCTAssertEqual(sm.lastWarning, .debouncedRepeatPress)
        XCTAssertEqual(sm.handle(.keyDown(timestamp: 0.2)), [])
        XCTAssertEqual(sm.handle(.keyUp(timestamp: 0.3)), [.fireOnRelease])
        XCTAssertTrue(sm.isRecording == false)
    }

    // --hotkey-unittest [3]: spurious release with no active press is ignored.
    func testSpuriousReleaseIgnored() {
        var sm = PushToTalkStateMachine()
        XCTAssertEqual(sm.handle(.keyUp(timestamp: 0)), [])
        XCTAssertEqual(sm.lastWarning, .spuriousReleaseIgnored)
        XCTAssertFalse(sm.isRecording)
    }

    // --hotkey-unittest [5]: resync — press with no release, then stop() must
    // fire a balancing release so downstream is never stuck recording.
    func testStopMidHoldFiresBalancingRelease() {
        var sm = PushToTalkStateMachine()
        XCTAssertEqual(sm.handle(.keyDown(timestamp: 0)), [.fireOnPress])
        XCTAssertEqual(sm.handle(.stop), [.fireOnRelease])
        XCTAssertFalse(sm.isRecording)
    }

    // stop() while idle must be a no-op (no phantom release).
    func testStopWhileIdleDoesNothing() {
        var sm = PushToTalkStateMachine()
        XCTAssertEqual(sm.handle(.stop), [])
        XCTAssertFalse(sm.isRecording)
    }

    // --hotkey-unittest [3] equivalent (start/stop/start): after a stop-mid-hold
    // resync, the machine is clean and a fresh press/release works normally.
    func testRestartCleanAfterResync() {
        var sm = PushToTalkStateMachine()
        _ = sm.handle(.keyDown(timestamp: 0))
        _ = sm.handle(.stop) // balancing release
        XCTAssertEqual(sm.handle(.keyDown(timestamp: 1)), [.fireOnPress])
        XCTAssertEqual(sm.handle(.keyUp(timestamp: 2)), [.fireOnRelease])
    }

    // The press timestamp is retained while held and cleared on release — the
    // seam a future double-tap window would read.
    func testPressTimestampTracked() {
        var sm = PushToTalkStateMachine()
        _ = sm.handle(.keyDown(timestamp: 42.5))
        XCTAssertEqual(sm.pressTimestamp, 42.5)
        _ = sm.handle(.keyUp(timestamp: 43.0))
        XCTAssertNil(sm.pressTimestamp)
    }

    // --hotkey-unittest [4] analogue: the wrapper distinguishes press vs release
    // (and right vs left Option) from the raw device flag. NX_DEVICERALTKEYMASK
    // (0x40) set => Right Option down; absent => up. Left Option's bit (0x20)
    // must NOT read as our key being down.
    func testRawFlagDecodesRightOptionDown() {
        let flag = HotkeyMonitor.rightOptionRawFlag
        XCTAssertTrue(HotkeyMonitor.isModifierDown(flags: CGEventFlags(rawValue: 0x40), deviceFlag: flag))
        XCTAssertTrue(HotkeyMonitor.isModifierDown(
            flags: CGEventFlags(rawValue: 0x40 | UInt64(CGEventFlags.maskAlternate.rawValue)),
            deviceFlag: flag))
    }

    func testRawFlagDecodesReleaseAndLeftOption() {
        let flag = HotkeyMonitor.rightOptionRawFlag
        XCTAssertFalse(HotkeyMonitor.isModifierDown(flags: CGEventFlags(rawValue: 0), deviceFlag: flag))
        // Left Option device bit only — must not count as Right Option down.
        XCTAssertFalse(HotkeyMonitor.isModifierDown(flags: CGEventFlags(rawValue: 0x20), deviceFlag: flag))
    }

    func testRightOptionKeyCodeIsExpected() {
        XCTAssertEqual(HotkeyMonitor.rightOptionKeyCode, 0x3D)
    }

    // Multi-key OR hold: first key down → pressed; last key up → released;
    // overlapping primary+secondary keeps the session open (no double fire).
    func testMultiKeyHoldFirstDownLastUp() {
        var t = MultiKeyHoldTracker()
        XCTAssertEqual(t.set(0x3D, down: true), .pressed)
        XCTAssertEqual(t.set(0x50, down: true), .none)       // second key while held
        XCTAssertEqual(t.set(0x3D, down: false), .none)      // primary up, secondary still down
        XCTAssertEqual(t.set(0x50, down: false), .released)  // last up
        XCTAssertTrue(t.held.isEmpty)
    }

    func testMultiKeyHoldEitherKeyAlone() {
        var t = MultiKeyHoldTracker()
        XCTAssertEqual(t.set(0x50, down: true), .pressed)
        XCTAssertEqual(t.set(0x50, down: false), .released)

        XCTAssertEqual(t.set(0x3D, down: true), .pressed)
        XCTAssertEqual(t.set(0x3D, down: false), .released)
    }

    func testMultiKeyHoldResetClears() {
        var t = MultiKeyHoldTracker()
        _ = t.set(0x3D, down: true)
        _ = t.set(0x50, down: true)
        t.reset()
        XCTAssertTrue(t.held.isEmpty)
        XCTAssertEqual(t.set(0x3D, down: true), .pressed)  // fresh after reset
    }

    // Chord AND: Control alone must NOT activate Control+Option+F17.
    func testChordRequiresEveryPart() {
        let ctrl = HotkeyKey.modifierKey(keyCode: 0x3B)   // Left Control
        let opt  = HotkeyKey.modifierKey(keyCode: 0x3A)   // Left Option
        let f17  = HotkeyKey.regularKey(keyCode: 0x40, characters: nil)  // F17
        var t = MultiChordHoldTracker(chords: [HotkeyChord(keys: [ctrl, opt, f17])])

        XCTAssertEqual(t.set(ctrl.keyCode, down: true), .none)   // ctrl alone
        XCTAssertEqual(t.set(opt.keyCode, down: true), .none)    // ctrl+opt still incomplete
        XCTAssertEqual(t.set(f17.keyCode, down: true), .pressed) // full chord
        XCTAssertEqual(t.set(ctrl.keyCode, down: false), .released) // any key up ends it
        XCTAssertFalse(t.isActive)
    }

    func testChordDisplayAndPersistenceRoundTrip() {
        let ctrl = HotkeyKey.modifierKey(keyCode: 0x3B)
        let opt  = HotkeyKey.modifierKey(keyCode: 0x3A)
        let f17  = HotkeyKey.regularKey(keyCode: 0x40, characters: nil)
        let chord = HotkeyChord(keys: [ctrl, opt, f17])
        XCTAssertEqual(chord.displayName, "Left Control + Left Option + F17")
        XCTAssertTrue(chord.id.hasPrefix("chord:"))
        let resolved = HotkeyChord.resolve(chord.id)
        XCTAssertEqual(resolved.keys.map(\.keyCode), chord.keys.map(\.keyCode))
        XCTAssertEqual(resolved.displayName, chord.displayName)
        // Legacy single-key ids still resolve.
        XCTAssertEqual(HotkeyChord.resolve("right_option"), HotkeyChord(key: .rightOption))
    }
}
