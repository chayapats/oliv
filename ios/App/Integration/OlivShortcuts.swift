import AppIntents

struct OlivShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .grayGreen }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleCaptureIntent(),
            phrases: ["Toggle \(.applicationName)", "Dictate with \(.applicationName)"],
            shortTitle: "Toggle OLIV",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: QuickCaptureIntent(),
            phrases: ["Capture with \(.applicationName)", "Start recording in \(.applicationName)"],
            shortTitle: "Capture",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopCaptureIntent(),
            phrases: ["Finish \(.applicationName)", "Stop recording in \(.applicationName)"],
            shortTitle: "Finish",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: CopyLatestTranscriptIntent(),
            phrases: ["Copy latest from \(.applicationName)"],
            shortTitle: "Copy Latest",
            systemImageName: "doc.on.doc"
        )
    }
}
