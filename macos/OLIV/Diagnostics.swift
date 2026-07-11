// "Copy Diagnostics" report builder (0.1.5). A support conversation starts
// with "what version / which engine / which grants" — this puts the whole
// answer on the clipboard in one click instead of a screenshot volley.
//
// Pure over injected values so it tests hermetically. Privacy stance: the
// cloud-fallback state is a BOOLEAN parameter — the API key is not accepted
// here, so no code path can print it. No transcript text is included either;
// only the last-dictation timing/char counts.

import Foundation

enum Diagnostics {
    static func report(
        appVersion: String, build: String, macOSVersion: String,
        engineID: String, hotkeyID: String,
        cleanupEnabled: Bool, removeFillers: Bool, formatCommands: Bool,
        cloudFallbackEnabled: Bool,
        microphone: PermissionStatus, inputMonitoring: PermissionStatus,
        accessibility: PermissionStatus,
        models: [RepoInfo], storagePath: String,
        lastDictation: LastDictationStats?
    ) -> String {
        var lines: [String] = [
            "OLIV Diagnostics",
            "App: OLIV \(appVersion) (build \(build))",
            "macOS: \(macOSVersion)",
            "Engine: \(engineID)",
            "Hotkey: \(hotkeyID)",
            "Cleanup: \(onOff(cleanupEnabled))",
            "Remove fillers: \(onOff(removeFillers))",
            "Format commands: \(onOff(formatCommands))",
            "Cloud fallback: \(onOff(cloudFallbackEnabled))",
            "Permissions:",
            "- Microphone: \(label(microphone))",
            "- Input Monitoring: \(label(inputMonitoring))",
            "- Accessibility: \(label(accessibility))",
            "Models (storage: \(storagePath)):",
        ]
        lines += models.map { "- \($0.displayName) [\($0.repo)]: \($0.sizeText)" }
        lines.append("Last dictation: \(lastDictation?.summary ?? "none")")
        return lines.joined(separator: "\n")
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static func label(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "not determined"
        }
    }
}
