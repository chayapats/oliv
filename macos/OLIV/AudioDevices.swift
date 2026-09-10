// Input-device enumeration + selection (the mic picker's model).
//
// WHY THIS EXISTS. OLIV used to record from whatever Core Audio called the
// default input, silently. macOS makes a connected Bluetooth headset the default
// input automatically — and using a Bluetooth MIC is not free. Both costs were
// measured on AirPods Pro, not assumed:
//
//   * Opening the input flips the headset from A2DP (48 kHz stereo) to the HFP
//     call profile — 24 kHz MONO, for OUTPUT too. Music stutters on the way in,
//     plays back as a phone call, and macOS holds the degraded profile for
//     seconds after the mic closes.
//   * The HFP link needs 0.5–3 s to come up, emitting digital zeros meanwhile,
//     so the first second of the first sentence is simply never recorded.
//
// The built-in mic has neither problem (measured: 0.000 s dead lead-in, output
// untouched, first sample 60–76 ms after open). So the input device is a CHOICE
// the user gets to make, defaulting to the built-in mic — not something silently
// inherited from whichever headset happens to be paired.

import CoreAudio
import Foundation

/// One selectable input device.
struct InputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    /// Stable across reconnects. The AudioDeviceID is NOT — it is reassigned when
    /// a device drops and comes back (observed live: AirPods went 106 → 107 → 104
    /// across one debugging session) — so the UID is what we persist.
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
}

/// What the user picked, as persisted: either a sentinel or a device UID.
enum MicSelection {
    /// The built-in mic, whatever its UID is on this machine. The default: the
    /// only choice that never degrades headphone playback and never loses the
    /// first second of an utterance.
    static let builtIn = "oliv.mic.builtin"
    /// Follow whatever macOS calls the default input (the pre-0.1.7 behaviour).
    static let systemDefault = "oliv.mic.system"
}

enum AudioDevices {
    // MARK: Enumeration

    static func inputDevices() -> [InputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            let transport = transportType(id)
            return InputDevice(
                id: id,
                uid: deviceUID(id),
                name: deviceName(id),
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE
            )
        }
    }

    static func systemDefaultInputID() -> AudioDeviceID {
        defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// The device playing everything else right now — what the echo canceller
    /// has to model and what OutputDucker turns down. 0 = none.
    static func systemDefaultOutputID() -> AudioDeviceID {
        defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    /// True when this device is a Bluetooth one. Both audio paths care: opening a
    /// Bluetooth MIC costs the headset's A2DP profile, and so can handing a
    /// Bluetooth OUTPUT to the voice-processing unit — see AudioCapture's
    /// `shouldUseVoiceProcessing`.
    ///
    /// FAILS CLOSED. An unreadable transport answers "yes, treat it as Bluetooth"
    /// — the callers use this to decide whether it is safe to hand a device to
    /// the duplex voice unit, and the cost of guessing wrong in that direction is
    /// only "no echo cancellation this time", while guessing wrong the other way
    /// drops someone's headphones into call quality mid-song.
    /// A COMPOSITE device hides its endpoints. An Aggregate or Multi-Output
    /// device reports its OWN transport ('grup'), not the transports of the
    /// devices it plays through — so a Multi-Output with AirPods inside answered
    /// "not Bluetooth" and handed those AirPods to the duplex voice unit, which
    /// is precisely the A2DP regression this file exists to prevent. The active
    /// sub-device list is what has to be asked, recursively: aggregates can
    /// contain aggregates.
    static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        isBluetooth(deviceID, in: DeviceGraph(
            transport: { transportType($0) },
            subDevices: { activeSubDevices($0) }))
    }

    /// The two Core Audio questions `isBluetooth` asks, as a seam. The real
    /// answers come from the HAL; a test supplies a device graph, which is the
    /// only way the shapes that matter (a Multi-Output holding AirPods, a nested
    /// aggregate, an unreadable one, a cycle) can be exercised without owning the
    /// hardware to build them.
    struct DeviceGraph {
        var transport: (AudioDeviceID) -> UInt32?
        var subDevices: (AudioDeviceID) -> [AudioDeviceID]
    }

    /// Pure over the graph. FAILS CLOSED at every uncertainty — an unreadable
    /// transport, a composite whose contents we cannot enumerate, a cycle — all
    /// answer "treat it as Bluetooth". The asymmetry is the whole point: guessing
    /// wrong this way costs echo cancellation for one utterance, and guessing
    /// wrong the other way drops someone's headphones into call quality mid-song.
    static func isBluetooth(
        _ deviceID: AudioDeviceID, in graph: DeviceGraph, visited: Set<AudioDeviceID> = []
    ) -> Bool {
        if visited.contains(deviceID) { return true }        // a graph that loops is not a safe one
        guard let transport = graph.transport(deviceID) else { return true }
        if transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        // Unknown is a SUCCESSFUL read that says "this device declines to say what
        // it is" — the same answer as a failed read, arriving through a different
        // door. Treating a non-nil result as an identification is how a predicate
        // that documents itself as failing closed quietly fails OPEN.
        if transport == kAudioDeviceTransportTypeUnknown { return true }
        guard transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate else { return false }
        let children = graph.subDevices(deviceID)
        guard !children.isEmpty else { return true }         // a container we cannot see into
        var seen = visited
        seen.insert(deviceID)
        return children.contains { isBluetooth($0, in: graph, visited: seen) }
    }

    /// The endpoints a composite device is actually playing through right now.
    /// Empty when the device is not a composite, or when the list cannot be read
    /// — the caller treats both as "cannot see inside".
    static func activeSubDevices(_ deviceID: AudioDeviceID) -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size)
        else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    /// Look a device up by the UID we persisted (IDs are reassigned across
    /// reconnects — see InputDevice.uid). nil = it isn't attached any more.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return allDeviceIDs().first { deviceUID($0) == uid }
    }

    // MARK: Selection (pure — unit-tested without a mic)

    /// Resolve a persisted selection against the devices that actually exist.
    /// nil means "there is no input device at all".
    ///
    /// Every fallback lands on a device that WORKS rather than on nothing: a
    /// selected mic that has been unplugged must not quietly turn dictation into
    /// a no-op, which is the exact family of bug this area exists to prevent.
    static func resolve(
        selection: String,
        devices: [InputDevice],
        systemDefaultID: AudioDeviceID
    ) -> AudioDeviceID? {
        switch selection {
        case MicSelection.systemDefault:
            if systemDefaultID != 0 { return systemDefaultID }
            return devices.first?.id
        case MicSelection.builtIn:
            return devices.first(where: { $0.isBuiltIn })?.id
                ?? (systemDefaultID != 0 ? systemDefaultID : devices.first?.id)
        default:
            if let picked = devices.first(where: { $0.uid == selection }) {
                return picked.id
            }
            // The chosen device is gone (headset unpaired, dock unplugged). Prefer
            // the built-in mic over the system default: the system default is very
            // likely the Bluetooth headset macOS just promoted, and the built-in
            // one is always there.
            return devices.first(where: { $0.isBuiltIn })?.id
                ?? (systemDefaultID != 0 ? systemDefaultID : devices.first?.id)
        }
    }

    /// True when the selection resolves to a Bluetooth mic — the case Settings
    /// warns about (headphone audio drops to call quality; first second is lost).
    static func resolvesToBluetooth(
        selection: String,
        devices: [InputDevice],
        systemDefaultID: AudioDeviceID
    ) -> Bool {
        guard let id = resolve(
            selection: selection, devices: devices, systemDefaultID: systemDefaultID)
        else { return false }
        return devices.first(where: { $0.id == id })?.isBluetooth ?? false
    }

    // MARK: Core Audio property plumbing

    static func deviceName(_ deviceID: AudioDeviceID) -> String {
        stringProperty(deviceID, kAudioObjectPropertyName) ?? "unknown device (id \(deviceID))"
    }

    static func deviceUID(_ deviceID: AudioDeviceID) -> String {
        stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? ""
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// nil when Core Audio would not say — the callers decide what an unknown
    /// transport means for them (see isBluetooth, which fails closed).
    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    /// How many output channels a device has — what OutputDucker walks when the
    /// device has no master volume control.
    static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        channelCount(deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        channelCount(deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    private static func channelCount(
        _ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }
}
