// Mic-picker selection logic — pure, no Core Audio, no microphone.
//
// The rules encode a hard-won lesson: a selection that cannot be honoured must
// fall back to a mic that WORKS. Dictation quietly recording nothing — because
// the chosen device is gone, or because macOS handed us a Bluetooth headset whose
// link never came up — is the exact failure this whole area exists to prevent.

import XCTest
@testable import OLIV

final class AudioDevicesTests: XCTestCase {
    private let builtIn = InputDevice(
        id: 78, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
        isBuiltIn: true, isBluetooth: false)
    private let airpods = InputDevice(
        id: 104, uid: "68-3E-C0-CF-E9-01:input", name: "AirPods Pro",
        isBuiltIn: false, isBluetooth: true)
    private let usb = InputDevice(
        id: 55, uid: "USB-Podmic", name: "Podmic",
        isBuiltIn: false, isBluetooth: false)

    private var all: [InputDevice] { [builtIn, airpods, usb] }

    // The shipped default: built-in, regardless of what macOS calls the default
    // input. That IS the point — a paired headset must not quietly become the
    // dictation mic and cost the user their first second and their music.
    func testBuiltInSelectionIgnoresSystemDefault() {
        XCTAssertEqual(
            AudioDevices.resolve(selection: MicSelection.builtIn, devices: all,
                                 systemDefaultID: airpods.id),
            builtIn.id,
            "built-in must win even when macOS has defaulted to AirPods")
    }

    func testSystemDefaultSelectionFollowsMacOS() {
        XCTAssertEqual(
            AudioDevices.resolve(selection: MicSelection.systemDefault, devices: all,
                                 systemDefaultID: airpods.id),
            airpods.id)
    }

    func testExplicitDeviceSelectionIsHonoured() {
        XCTAssertEqual(
            AudioDevices.resolve(selection: usb.uid, devices: all, systemDefaultID: airpods.id),
            usb.id)
    }

    // A UID is stable across reconnects; the AudioDeviceID is NOT — the AirPods in
    // this repo's debugging session went 106 → 107 → 104 in an afternoon. Persisting
    // the id would silently point at whatever inherited the number.
    func testSelectionResolvesByUIDNotByStaleID() {
        let reconnected = InputDevice(
            id: 999, uid: airpods.uid, name: airpods.name, isBuiltIn: false, isBluetooth: true)
        XCTAssertEqual(
            AudioDevices.resolve(selection: airpods.uid, devices: [builtIn, reconnected],
                                 systemDefaultID: builtIn.id),
            999,
            "must follow the UID to the device's NEW id")
    }

    // The selected mic was unplugged. Falling back to the system default would often
    // mean falling back to the Bluetooth headset macOS just promoted; the built-in
    // mic is the one that is always there and always works.
    func testMissingSelectedDeviceFallsBackToBuiltIn() {
        XCTAssertEqual(
            AudioDevices.resolve(selection: "USB-Podmic", devices: [builtIn, airpods],
                                 systemDefaultID: airpods.id),
            builtIn.id,
            "a vanished mic must not turn dictation into a no-op")
    }

    // Odd hardware: no built-in mic at all → the system default is all we have.
    func testMissingSelectedDeviceWithNoBuiltInFallsBackToSystemDefault() {
        XCTAssertEqual(
            AudioDevices.resolve(selection: "gone", devices: [airpods],
                                 systemDefaultID: airpods.id),
            airpods.id)
    }

    // Core Audio reports no default (0) but a device exists — take the device
    // rather than refusing to record.
    func testNoSystemDefaultStillPicksAnExistingDevice() {
        XCTAssertEqual(
            AudioDevices.resolve(selection: MicSelection.systemDefault, devices: [usb],
                                 systemDefaultID: 0),
            usb.id)
    }

    // Genuinely no input hardware → nil, and start() turns that into a visible
    // "couldn't open the microphone", never a silent no-op.
    func testNoDevicesResolvesToNil() {
        XCTAssertNil(AudioDevices.resolve(selection: MicSelection.builtIn, devices: [],
                                          systemDefaultID: 0))
        XCTAssertNil(AudioDevices.resolve(selection: MicSelection.systemDefault, devices: [],
                                          systemDefaultID: 0))
    }

    // Drives the Settings warning ("headphone audio drops to call quality").
    func testResolvesToBluetoothDetectsTheDegradingCase() {
        XCTAssertTrue(AudioDevices.resolvesToBluetooth(
            selection: airpods.uid, devices: all, systemDefaultID: builtIn.id))
        XCTAssertFalse(AudioDevices.resolvesToBluetooth(
            selection: MicSelection.builtIn, devices: all, systemDefaultID: airpods.id))
        XCTAssertFalse(AudioDevices.resolvesToBluetooth(
            selection: usb.uid, devices: all, systemDefaultID: airpods.id))
    }

    // "System default" is a live pointer — it must report Bluetooth when macOS has
    // promoted the headset, which is precisely when the user needs telling.
    func testSystemDefaultResolvingToBluetoothIsFlagged() {
        XCTAssertTrue(AudioDevices.resolvesToBluetooth(
            selection: MicSelection.systemDefault, devices: all, systemDefaultID: airpods.id))
    }
}
