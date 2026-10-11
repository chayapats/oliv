import AppKit
import Combine
import CoreAudio
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var launchEnabled = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        SettingsPane {
            SettingsCard(title: "Make yourself at home", icon: "sun.max", subtitle: "Keep OLIV close, with as much feedback as you need.") {
                SettingsToggle(title: "Launch at login", detail: "Start OLIV in the menu bar when you sign in to your Mac.",
                               isOn: Binding(get: { launchEnabled }, set: setLaunch))
                if let launchError {
                    SettingsNotice(text: launchError, icon: "exclamationmark.triangle", warning: true)
                } else if LaunchAtLogin.status != .enabled && LaunchAtLogin.status != .notRegistered {
                    SettingsNotice(text: LaunchAtLogin.statusDescription(), warning: true)
                }
                Divider()
                SettingsToggle(title: "Show recording indicator", detail: "See a floating waveform while you dictate, plus recording and processing status.",
                               isOn: $settings.showRecordingIndicator)
            }
            SettingsCard(title: "Recent transcripts", icon: "clock.arrow.circlepath", subtitle: "A little history, only for this session.") {
                SettingsToggle(title: "Keep recent transcripts", detail: "Find your last 10 dictations in the menu bar. Click a transcript to copy it, then paste with ⌘V.",
                               isOn: $settings.historyEnabled)
                SettingsNotice(text: "History stays in memory. Turning this off clears it immediately; quitting OLIV clears it too.", icon: "lock.shield")
            }
        }
        .onAppear { launchEnabled = LaunchAtLogin.isEnabled }
    }

    private func setLaunch(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchError = nil
        } catch {
            launchError = "Could not \(enabled ? "enable" : "disable") launch at login. Move OLIV to /Applications and try again. \(error.localizedDescription)"
        }
        launchEnabled = LaunchAtLogin.isEnabled
    }
}

struct ShortcutsSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var recordingSlot: HotkeySlot?

    var body: some View {
        SettingsPane {
            SettingsNotice(text: "Hold your shortcut to speak. Release any key in the shortcut to finish and insert your text.", icon: "waveform")
            SettingsCard(title: "Push to talk", icon: "keyboard", subtitle: "Use a single modifier or a combination of keys.") {
                HotkeyRecorderField(slot: .primary, activeSlot: $recordingSlot)
                Divider()
                HotkeyRecorderField(slot: .secondary, activeSlot: $recordingSlot)
                Text("A second shortcut is optional. Either one can start a recording.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if settings.activeChords.contains(where: \.typesText) {
                    SettingsNotice(text: "This shortcut also types characters in the active app. A modifier or function key is recommended.",
                                   icon: "exclamationmark.triangle", warning: true)
                }
            }
            SettingsCard(title: "Undo last dictation", icon: "arrow.uturn.backward", subtitle: "A quick way to take back a bad paste.") {
                HotkeyRecorderField(slot: .undo, activeSlot: $recordingSlot)
                Text("Press once after a dictation to send ⌘Z. Available once per successful paste. The default is Control + Shift + Z.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let undo = settings.undoHotkeyChord, settings.activeChords.contains(undo) {
                    SettingsNotice(text: "This matches a push-to-talk shortcut. Choose a different shortcut for undo.",
                                   icon: "exclamationmark.triangle", warning: true)
                }
            }
            Text("To record a shortcut, click Record, hold any modifiers, then press a key. You can also press and release a single modifier. Escape cancels.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }
}

struct AudioSettingsView: View {
    @EnvironmentObject private var settings: OLIVSettings

    var body: some View {
        SettingsPane {
            SettingsCard(title: "Microphone", icon: "mic", subtitle: "Choose the input OLIV uses to record your voice.") {
                MicrophonePicker()
            }
            SettingsCard(title: "Clearer voice, fewer distractions", icon: "speaker.wave.2", subtitle: "Keep music and video out of your transcript.") {
                SettingsToggle(title: "Cancel speaker echo", detail: "Filter out audio your Mac is playing. Used when the selected mic is also the system input; skipped with Bluetooth audio.",
                               isOn: $settings.echoCancellation)
                Divider()
                SettingsToggle(title: "Lower other audio while dictating", detail: "Lower playback while you speak and restore it on release. If you adjust the volume yourself, OLIV keeps your change.",
                               isOn: $settings.duckOtherAudio)
                DisclosureGroup("How audio handling works") {
                    Text("If echo cancellation is unavailable, OLIV remembers that audio route and uses the regular mic to start faster. Turn echo cancellation off and on to retry. With echo cancellation enabled, macOS controls audio lowering and may still lower playback when the second switch is off.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                }
                .font(.system(size: 12))
            }
        }
    }
}

private struct MicrophonePicker: View {
    @EnvironmentObject private var settings: OLIVSettings
    @State private var devices: [InputDevice] = []
    @State private var systemDefaultID: AudioDeviceID = 0
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Input device", selection: $settings.micDevice) {
                Text("Built-in microphone").tag(MicSelection.builtIn)
                Text("System default — \(devices.first(where: { $0.id == systemDefaultID })?.name ?? "none")")
                    .tag(MicSelection.systemDefault)
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { device in
                        Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name).tag(device.uid)
                    }
                }
                if settings.micDevice != MicSelection.builtIn && settings.micDevice != MicSelection.systemDefault,
                   !devices.contains(where: { $0.uid == settings.micDevice }) {
                    Text("Selected microphone (disconnected)").tag(settings.micDevice)
                }
            }
            .pickerStyle(.menu)
            .onAppear(perform: refresh).onReceive(tick) { _ in refresh() }
            if AudioDevices.resolvesToBluetooth(selection: settings.micDevice, devices: devices, systemDefaultID: systemDefaultID) {
                SettingsNotice(text: "A Bluetooth mic switches headphone playback to mono call quality and may take a second to wake. Wait for the waveform before speaking.",
                               icon: "exclamationmark.triangle", warning: true)
            } else {
                SettingsNotice(text: "The built-in mic leaves Bluetooth playback at full quality. You can still use AirPods to listen.", icon: "headphones")
            }
        }
    }
    private func refresh() {
        devices = AudioDevices.inputDevices()
        systemDefaultID = AudioDevices.systemDefaultInputID()
    }
}

enum HotkeySlot: Equatable {
    case primary, secondary, undo

    /// Short Form labels — "Primary/Secondary push-to-talk" overflowed the
    /// fixed label column (520-wide Settings window) and crushed the key name.
    var label: String {
        switch self {
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        case .undo: return "Undo last"
        }
    }
}

/// The "record shortcut" capture control (W4-T2 Feature B): click Set →
/// "Press a key…" → the next physical key becomes that slot's push-to-talk key
/// (any modifier or regular key; Escape cancels). A quick menu beside it keeps
/// the five named presets one click away. Secondary may be cleared (None).
///
/// The key NAME sits outside the button on purpose — putting "Right Control"
/// inside a bordered button in a Form column truncated it to look like
/// "Control" while the binding still worked (keycode was fine).
struct HotkeyRecorderField: View {
    let slot: HotkeySlot
    @Binding var activeSlot: HotkeySlot?
    @EnvironmentObject private var settings: OLIVSettings
    @State private var recorder: HotkeyRecorder?
    @State private var isCapturing = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(slot.label).font(.system(size: 13, weight: .medium))
                if slot == .secondary {
                    Text("Optional").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 85, alignment: .leading)
            Text(isCapturing ? "Press a shortcut…" : displayName)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isCapturing ? SettingsStyle.accent : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsStyle.border))
                .help(displayName)
            Button(isCapturing ? "Cancel" : "Record") { toggleCapture() }
                .help(captureHelp)
            Menu {
                if slot == .secondary || slot == .undo {
                    Button("None") { cancelCapture(); clearOptionalSlot() }
                    Divider()
                }
                ForEach(HotkeyKey.all) { key in
                    Button(key.displayName) { cancelCapture(); chooseKey(key) }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).frame(width: 22)
            .help("Choose a preset shortcut")
            .accessibilityLabel("Presets for \(slot.label)")
        }
        .id(slot.label)
        .onChange(of: activeSlot) { if activeSlot != slot { cancelCapture() } }
        .onDisappear { cancelCapture() }
    }

    private var displayName: String {
        switch slot {
        case .primary: return settings.hotkeyChord.displayName
        case .secondary: return settings.hotkeySecondaryChord?.displayName ?? "None"
        case .undo: return settings.undoHotkeyChord?.displayName ?? "None"
        }
    }

    private var captureHelp: String {
        if isCapturing {
            return "Hold modifiers, then press the main key (e.g. Control+Option+F17). Or press/release a single modifier. Esc cancels."
        }
        switch slot {
        case .primary:
            return "Click Record, then press the shortcut you want to hold to dictate."
        case .secondary:
            return "Optional second shortcut — hold either binding to dictate."
        case .undo:
            return "Click Record, then press the shortcut that undoes the last paste."
        }
    }

    private func toggleCapture() {
        if isCapturing { cancelCapture(); return }
        activeSlot = slot
        let rec = HotkeyRecorder(
            onCapture: { chord in choose(chord); finish() },
            onCancel: { finish() })
        recorder = rec
        isCapturing = true
        rec.start()
    }

    private func cancelCapture() { recorder?.stop(); finish() }

    private func finish() {
        recorder = nil
        isCapturing = false
        if activeSlot == slot { activeSlot = nil }
    }

    private func choose(_ chord: HotkeyChord) {
        switch slot {
        case .primary: settings.hotkeyID = chord.id
        case .secondary: settings.hotkeySecondaryID = chord.id
        case .undo: settings.undoHotkeyID = chord.id
        }
    }

    private func chooseKey(_ key: HotkeyKey) {
        choose(HotkeyChord(key: key))
    }

    private func clearOptionalSlot() {
        switch slot {
        case .secondary: settings.hotkeySecondaryID = ""
        case .undo: settings.undoHotkeyID = ""
        case .primary: break
        }
    }
}
