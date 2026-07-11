// OLIV — local Thai+English push-to-talk dictation, menu-bar shell (W3-T1).
//
// Architecture: this Swift app owns ALL macOS
// integration — menu-bar UI, the push-to-talk hotkey (W3-T2), audio capture
// (W3-T2), paste-at-cursor (W3-T2), onboarding + settings (W3-T4) — and
// delegates STT + cleanup to one bundled Python sidecar over stdio JSON
// (W3-T3). The Python prototype under ../app remains the dev harness; this
// app is the shippable product.

import SwiftUI

// NOTE: `@main` lives on OLIVMain (OLIVMain.swift), not here — it intercepts
// `--e2e-file` for the headless latency harness BEFORE any SwiftUI scene builds,
// then hands off to `OLIVApp.main()` for the normal menu-bar launch.
struct OLIVApp: App {
    // The coordinator (W3-T4) owns AppState, the settings/permissions/model
    // stores, the DictationController, and onboarding. Constructed by SwiftUI as
    // the NSApplicationDelegate; it starts the pipeline + auto-shows onboarding
    // in applicationDidFinishLaunching.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate)
        } label: {
            // The menu-bar label is the app's only always-visible surface
            // (LSUIElement = no Dock icon): the icon doubles as the recording-
            // state indicator AND carries the "setup needed" badge (W3-T4).
            MenuBarLabel(appState: appDelegate.appState, coordinator: appDelegate)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.models)
                .environmentObject(appDelegate.permissions)
                .environmentObject(appDelegate)
        }
    }
}

/// The menu-bar icon: the live dictation-status symbol, overlaid (while idle)
/// with a warning when a required permission/model is missing.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var coordinator: AppDelegate

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("OLIV: \(accessibilityLabel)")
    }

    private var symbol: String {
        // Recording/processing keep their own live symbol so state is never
        // hidden; the badge only shows in the resting (idle) state.
        if coordinator.needsAttention && appState.status == .idle {
            return "exclamationmark.triangle"
        }
        return appState.status.symbolName
    }

    private var accessibilityLabel: String {
        if coordinator.needsAttention && appState.status == .idle {
            return "\(appState.status.label) — setup needed"
        }
        return appState.status.label
    }
}
