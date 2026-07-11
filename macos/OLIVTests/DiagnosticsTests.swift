// Diagnostics.report — the pure builder behind the menu's "Copy Diagnostics"
// (0.1.5). Everything is injected as plain values, so the report is fully
// deterministic here; AppDelegate's assembly + pasteboard glue stays untested
// per repo convention. The builder takes the cloud-fallback state as a BOOLEAN
// only — the API key is not a parameter, so it can never leak into a report.

import XCTest
@testable import OLIV

final class DiagnosticsTests: XCTestCase {
    /// Fixed inputs → the exact report, pinning layout + every field. Absent
    /// repos keep sizeText locale-independent ("Not downloaded").
    func testReportFullLayout() {
        let report = Diagnostics.report(
            appVersion: "0.1.5", build: "10", macOSVersion: "Version 15.5 (Build 24F74)",
            engineID: "typhoon-turbo-mlx", hotkeyID: "right_option",
            cleanupEnabled: true, removeFillers: true, formatCommands: false,
            cloudFallbackEnabled: false,
            microphone: .granted, inputMonitoring: .denied, accessibility: .notDetermined,
            models: [
                RepoInfo(repo: "chayapats/typhoon-whisper-turbo-mlx", present: false, bytes: 0),
                RepoInfo(repo: "mlx-community/gemma-4-e2b-it-4bit", present: false, bytes: 0),
            ],
            storagePath: "/Users/x/Library/Application Support/OLIV/models",
            lastDictation: nil)

        XCTAssertEqual(report, """
        OLIV Diagnostics
        App: OLIV 0.1.5 (build 10)
        macOS: Version 15.5 (Build 24F74)
        Engine: typhoon-turbo-mlx
        Hotkey: right_option
        Cleanup: on
        Remove fillers: on
        Format commands: off
        Cloud fallback: off
        Permissions:
        - Microphone: granted
        - Input Monitoring: denied
        - Accessibility: not determined
        Models (storage: /Users/x/Library/Application Support/OLIV/models):
        - Thai STT (Typhoon Whisper Turbo MLX) [chayapats/typhoon-whisper-turbo-mlx]: Not downloaded
        - Cleanup (Gemma-E2B) [mlx-community/gemma-4-e2b-it-4bit]: Not downloaded
        Last dictation: none
        """)
    }

    func testReportPresentModelUsesFormattedSize() {
        let info = RepoInfo(repo: "chayapats/typhoon-whisper-turbo-mlx",
                            present: true, bytes: 1_234_567_890)
        let report = Diagnostics.report(
            appVersion: "0.1.5", build: "10", macOSVersion: "x",
            engineID: "e", hotkeyID: "h",
            cleanupEnabled: true, removeFillers: false, formatCommands: false,
            cloudFallbackEnabled: true,
            microphone: .granted, inputMonitoring: .granted, accessibility: .granted,
            models: [info], storagePath: "/p", lastDictation: nil)
        // Locale-safe: expect whatever ByteCountFormatter produced via sizeText.
        XCTAssertTrue(report.contains(
            "- Thai STT (Typhoon Whisper Turbo MLX) [chayapats/typhoon-whisper-turbo-mlx]: \(info.sizeText)"))
        XCTAssertTrue(report.contains("Cloud fallback: on"))
    }

    func testReportIncludesLastDictationStatsWhenPresent() {
        let report = Diagnostics.report(
            appVersion: "0.1.5", build: "10", macOSVersion: "x",
            engineID: "e", hotkeyID: "h",
            cleanupEnabled: false, removeFillers: false, formatCommands: true,
            cloudFallbackEnabled: false,
            microphone: .denied, inputMonitoring: .denied, accessibility: .denied,
            models: [], storagePath: "/p",
            lastDictation: LastDictationStats(chars: 38, sttSeconds: 0.9, cleanupSeconds: 0.5))
        XCTAssertTrue(report.contains("Last dictation: 1.4s · 38 chars"))
        XCTAssertTrue(report.contains("Cleanup: off"))
        XCTAssertTrue(report.contains("Format commands: on"))
    }
}
