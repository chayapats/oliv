// Hotkey keycode mapping-table tests (W3-T4). The Settings picker offers five
// named keys ported from the Python `_KEY_ATTR_MAP`; each must map to the right
// (keycode, device-flag) pair the CGEventTap wrapper keys on, and the stored-id
// resolution must fall back to the Right Option default like the Python config.
// Pure + hermetic: no CGEventTap, no permissions.

import CoreGraphics
import XCTest
@testable import OLIV

final class HotkeyKeyMapTests: XCTestCase {

    // The exact table: config id → (keycode, device flag). Nil flag == F19, the
    // one non-modifier (matched via keyDown/keyUp, not flagsChanged).
    func testKeyMapTable() {
        let expected: [(id: String, keyCode: CGKeyCode, deviceFlag: UInt64?)] = [
            ("right_option",  0x3D, 0x40),
            ("left_option",   0x3A, 0x20),
            ("right_command", 0x36, 0x10),
            ("right_control", 0x3E, 0x2000),
            ("f19",           0x50, nil),
        ]
        XCTAssertEqual(HotkeyKey.all.count, expected.count)
        for row in expected {
            let key = HotkeyKey.resolve(row.id)
            XCTAssertEqual(key.id, row.id)
            XCTAssertEqual(key.keyCode, row.keyCode, "keycode for \(row.id)")
            XCTAssertEqual(key.deviceFlag, row.deviceFlag, "device flag for \(row.id)")
        }
    }

    // F19 is the only non-modifier; the four modifiers report isModifier == true.
    func testIsModifierClassification() {
        XCTAssertFalse(HotkeyKey.f19.isModifier)
        for key in [HotkeyKey.rightOption, .leftOption, .rightCommand, .rightControl] {
            XCTAssertTrue(key.isModifier, "\(key.id) should be a modifier")
        }
    }

    // Resolve is a total function: known id (any case) → that key; unknown /
    // nil / blank → the Right Option default (never a hard error).
    func testResolveFallsBackToDefault() {
        XCTAssertEqual(HotkeyKey.resolve("f19"), .f19)
        XCTAssertEqual(HotkeyKey.resolve("RIGHT_OPTION"), .rightOption)
        XCTAssertEqual(HotkeyKey.resolve("  left_option "), .leftOption)
        XCTAssertEqual(HotkeyKey.resolve("bogus"), .rightOption)
        XCTAssertEqual(HotkeyKey.resolve(nil), .rightOption)
        XCTAssertEqual(HotkeyKey.resolve(""), .rightOption)
    }

    // Ids are unique (a picker/tag invariant) and the default is Right Option.
    func testIdsUniqueAndDefault() {
        XCTAssertEqual(Set(HotkeyKey.all.map(\.id)).count, HotkeyKey.all.count)
        XCTAssertEqual(HotkeyKey.default, .rightOption)
    }

    // The raw-flag decode is per-key: each modifier's device bit reads as "down";
    // a foreign bit (another modifier's, or none) reads as "up".
    func testIsModifierDownPerKey() {
        for key in [HotkeyKey.rightOption, .leftOption, .rightCommand, .rightControl] {
            let flag = key.deviceFlag!
            XCTAssertTrue(HotkeyMonitor.isModifierDown(
                flags: CGEventFlags(rawValue: flag), deviceFlag: flag), "\(key.id) down")
            XCTAssertFalse(HotkeyMonitor.isModifierDown(
                flags: CGEventFlags(rawValue: 0), deviceFlag: flag), "\(key.id) up")
        }
        // Right Option's bit must not read as Right Command down, and vice versa.
        XCTAssertFalse(HotkeyMonitor.isModifierDown(
            flags: CGEventFlags(rawValue: HotkeyKey.rightOption.deviceFlag!),
            deviceFlag: HotkeyKey.rightCommand.deviceFlag!))
    }

    // Back-compat constants still name Right Option (existing wrapper/tests).
    func testBackCompatConstants() {
        XCTAssertEqual(HotkeyMonitor.rightOptionKeyCode, 0x3D)
        XCTAssertEqual(HotkeyMonitor.rightOptionRawFlag, 0x40)
    }
}
