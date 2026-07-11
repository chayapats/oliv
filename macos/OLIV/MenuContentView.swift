// The menu shown when the user clicks the menu-bar icon.

import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var coordinator: AppDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Status line: reflects DictationStatus live (the icon shows it too,
        // but the text names it for clarity).
        Text("OLIV — \(appState.status.label)")
        if let stats = appState.lastDictation {
            Text(stats.menuLine)
                .font(.caption).foregroundStyle(.secondary)
        }

        Toggle("Enable dictation", isOn: $appState.dictationEnabled)

        // Recent transcripts (0.1.5): grab back what just pasted (or vanished
        // into the wrong window). Hidden while empty — which also covers the
        // toggle being off, since recording is gated on it and flipping it off
        // clears retained entries (and publishes via appState, so this view
        // re-renders; a settings check here would NOT be reactive). Click =
        // copy + HUD notice, never a synthesized paste (locked decision).
        if !appState.transcripts.entries.isEmpty {
            Menu("Recent…") {
                ForEach(appState.transcripts.entries) { entry in
                    Button(entry.preview) {
                        coordinator.copyTranscript(entry)
                    }
                }
            }
        }

        Divider()

        // Onboarding entry point (W3-T4). Names the action when setup is
        // incomplete so the badge on the icon has a matching call to action.
        Button(coordinator.needsAttention ? "Setup… (action needed)" : "Setup…") {
            coordinator.showOnboarding()
        }

        // Sparkle auto-update (W5-T1). Automatic background checks run on their
        // own (SUEnableAutomaticChecks); this is the on-demand path. Sparkle
        // guards re-entrancy internally, so an always-enabled item is safe — a
        // second click while a check is live just refocuses the existing one.
        Button("Check for Updates…") {
            coordinator.updaterController.updater.checkForUpdates()
        }

        // A plain SettingsLink only OPENS the window — it never activates the
        // app, and an accessory (LSUIElement) app is usually NOT active when a
        // menu item fires, so the Settings window materialized BEHIND the
        // frontmost app. Activate first — the same treatment
        // OnboardingWindowController.show() gives the Setup window.
        Button("Settings…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        // One-click support report (0.1.5): version/engine/grants/models to the
        // clipboard, confirmed via the HUD — replaces the screenshot volley.
        Button("Copy Diagnostics") {
            coordinator.copyDiagnostics()
        }

        Button("Quit OLIV") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
