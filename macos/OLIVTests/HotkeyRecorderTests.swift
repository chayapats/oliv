// Arbitrary-key hotkey recorder tests (W4-T2 Feature B). Two pure seams, both
// hermetic — NO NSEvent, NO key window, NO Input Monitoring grant:
//
//   • the keycode → (kind, device-flag mask) mapping table the CGEventTap wrapper
//     keys on, for all nine capturable modifier keycodes plus a letter and an
//     F-key (the regular keyDown/keyUp path);
//   • HotkeyRecorder.interpretCapture — capture / cancel / ignore — and the
//     general-encoding persistence that migrates the old five-id format.

import CoreGraphics
import XCTest
@testable import OLIV

final class HotkeyRecorderTests: XCTestCase {

    // All nine modifier keycodes map to their NX_DEVICE*/secondary-fn mask, and
    // building a modifier key from each yields the (keycode, mask) the wrapper
    // matches on via flagsChanged.
    func testModifierKeycodeMaskTable() {
        let table: [(keyCode: CGKeyCode, mask: UInt64)] = [
            (0x3A, 0x20),      // Left Option
            (0x3D, 0x40),      // Right Option
            (0x37, 0x08),      // Left Command
            (0x36, 0x10),      // Right Command
            (0x3B, 0x01),      // Left Control
            (0x3E, 0x2000),    // Right Control
            (0x38, 0x02),      // Left Shift
            (0x3C, 0x04),      // Right Shift
            (0x3F, 0x800000),  // Fn (secondary-fn mask)
        ]
        for row in table {
            XCTAssertEqual(HotkeyKey.modifierDeviceFlag(for: row.keyCode), row.mask,
                           "mask for keycode 0x\(String(row.keyCode, radix: 16))")
            let key = HotkeyKey.modifierKey(keyCode: row.keyCode)
            XCTAssertTrue(key.isModifier)
            XCTAssertEqual(key.keyCode, row.keyCode)
            XCTAssertEqual(key.deviceFlag, row.mask)
        }
        // A non-modifier keycode has no device mask.
        XCTAssertNil(HotkeyKey.modifierDeviceFlag(for: 0x2D))   // letter N
        XCTAssertNil(HotkeyKey.modifierDeviceFlag(for: 0x60))   // F5
    }

    // A letter is a REGULAR key: no device flag, keyDown/keyUp path, types text.
    func testLetterMapsToRegularKeyAndTypesText() {
        let key = HotkeyKey.regularKey(keyCode: 0x2D, characters: "n")   // kVK_ANSI_N
        XCTAssertFalse(key.isModifier)
        XCTAssertNil(key.deviceFlag)
        XCTAssertEqual(key.keyCode, 0x2D)
        XCTAssertEqual(key.displayName, "N")
        XCTAssertTrue(HotkeyKey.typesText(keyCode: 0x2D))
    }

    // An F-key is a REGULAR key but does NOT type text (no inline warning);
    // modifiers don't type text either.
    func testFunctionAndModifierKeysDoNotTypeText() {
        let f5 = HotkeyKey.regularKey(keyCode: 0x60, characters: nil)
        XCTAssertFalse(f5.isModifier)
        XCTAssertNil(f5.deviceFlag)
        XCTAssertEqual(f5.displayName, "F5")
        XCTAssertFalse(HotkeyKey.typesText(keyCode: 0x60))   // F5
        XCTAssertFalse(HotkeyKey.typesText(keyCode: 0x50))   // F19
        XCTAssertFalse(HotkeyKey.typesText(keyCode: 0x35))   // Escape
        XCTAssertFalse(HotkeyKey.typesText(keyCode: 0x3D))   // Right Option (modifier)
    }

    // Capturing one of the five presets canonicalizes to the preset (clean id +
    // label), not a general encoding.
    func testCaptureCanonicalizesToPreset() {
        XCTAssertEqual(HotkeyKey.modifierKey(keyCode: 0x3D), .rightOption)
        XCTAssertEqual(HotkeyKey.modifierKey(keyCode: 0x3A), .leftOption)
        XCTAssertEqual(HotkeyKey.regularKey(keyCode: 0x50, characters: nil), .f19)
    }

    // A general (arbitrary-key) encoding round-trips through resolve: keycode,
    // kind (device flag), and display name all survive the store.
    func testGeneralEncodingRoundTrips() {
        let letter = HotkeyKey.regularKey(keyCode: 0x2D, characters: "n")
        XCTAssertTrue(letter.id.hasPrefix("hk:"))
        XCTAssertEqual(HotkeyKey.resolve(letter.id), letter)

        let leftShift = HotkeyKey.modifierKey(keyCode: 0x38)
        XCTAssertTrue(leftShift.id.hasPrefix("hk:"))
        XCTAssertEqual(leftShift.deviceFlag, 0x02)
        XCTAssertEqual(HotkeyKey.resolve(leftShift.id), leftShift)

        let fn = HotkeyKey.modifierKey(keyCode: 0x3F)
        XCTAssertEqual(HotkeyKey.resolve(fn.id), fn)
        XCTAssertEqual(fn.deviceFlag, 0x800000)
    }

    // Old five-id format still migrates transparently; malformed ids fall back.
    func testOldStoredIdsMigrateAndBadIdsFallBack() {
        XCTAssertEqual(HotkeyKey.resolve("right_option"), .rightOption)
        XCTAssertEqual(HotkeyKey.resolve("f19"), .f19)
        XCTAssertEqual(HotkeyKey.resolve("left_option"), .leftOption)
        XCTAssertEqual(HotkeyKey.resolve("garbage"), .default)
        XCTAssertEqual(HotkeyKey.resolve("hk:bogus"), .default)          // malformed general
        XCTAssertEqual(HotkeyKey.resolve("hk:55:mod:"), .default)        // empty name
        XCTAssertEqual(HotkeyKey.resolve("hk:2D:mod:X"), .default)       // "mod" but not a modifier keycode
    }

    // interpret (keyDown): a letter captures a regular key; Escape cancels.
    func testInterpretKeyDown() {
        let outcome = HotkeyRecorder.interpretCapture(
            event: .keyDown, keyCode: 0x2D, modifierIsDown: false, characters: "n")
        guard case .captured(let key) = outcome else {
            return XCTFail("letter keyDown should capture")
        }
        XCTAssertEqual(key.keyCode, 0x2D)
        XCTAssertNil(key.deviceFlag)

        XCTAssertEqual(
            HotkeyRecorder.interpretCapture(event: .keyDown, keyCode: HotkeyRecorder.escapeKeyCode,
                                            modifierIsDown: false, characters: nil),
            .cancelled)
    }

    // interpret (flagsChanged): captures only on the DOWN edge; the release edge
    // and a non-modifier keycode are ignored so the recorder keeps listening.
    func testInterpretFlagsChangedEdges() {
        let down = HotkeyRecorder.interpretCapture(
            event: .flagsChanged, keyCode: 0x37, modifierIsDown: true, characters: nil)
        XCTAssertEqual(down, .captured(HotkeyKey.modifierKey(keyCode: 0x37)))   // Left Command

        XCTAssertEqual(
            HotkeyRecorder.interpretCapture(event: .flagsChanged, keyCode: 0x37,
                                            modifierIsDown: false, characters: nil),
            .ignore)   // release edge

        XCTAssertEqual(
            HotkeyRecorder.interpretCapture(event: .flagsChanged, keyCode: 0x2D,
                                            modifierIsDown: true, characters: nil),
            .ignore)   // not a device modifier
    }

    // A captured arbitrary modifier drives the SAME wrapper matching path — its
    // device bit reads as down/up exactly like the preset modifiers.
    func testCapturedModifierMatchesViaDeviceMask() {
        let fn = HotkeyKey.modifierKey(keyCode: 0x3F)
        XCTAssertTrue(HotkeyMonitor.isModifierDown(
            flags: CGEventFlags(rawValue: fn.deviceFlag!), deviceFlag: fn.deviceFlag!))
        XCTAssertFalse(HotkeyMonitor.isModifierDown(
            flags: CGEventFlags(rawValue: 0), deviceFlag: fn.deviceFlag!))
        // Left Shift's bit must not read as Right Shift down.
        let leftShift = HotkeyKey.modifierKey(keyCode: 0x38)
        let rightShift = HotkeyKey.modifierKey(keyCode: 0x3C)
        XCTAssertFalse(HotkeyMonitor.isModifierDown(
            flags: CGEventFlags(rawValue: leftShift.deviceFlag!), deviceFlag: rightShift.deviceFlag!))
    }
}
