import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            statusBanners
            TabView(selection: $model.selectedTab) {
                NavigationStack {
                    CaptureView(model: model)
                }
                .tabItem { Label("Capture", systemImage: "waveform") }
                .tag(0)
                .accessibilityIdentifier("captureTab")

                NavigationStack {
                    HistoryView(model: model)
                }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(1)
                .accessibilityIdentifier("historyTab")

                NavigationStack {
                    SettingsView(model: model)
                }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(2)
                .accessibilityIdentifier("settingsTab")
            }
            .tint(OlivTheme.olive)
            .toolbarBackground(OlivTheme.surface, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        }
        .background(OlivTheme.background.ignoresSafeArea())
        .tint(OlivTheme.olive)
    }

    private var statusBanners: some View {
        VStack(spacing: 0) {
            if model.isDemo {
                Label("Demo · simulated audio and server", systemImage: "testtube.2")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(OlivTheme.warning)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(OlivTheme.warm)
                    .accessibilityIdentifier("demoBanner")
            }
            if let message = model.message, !message.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(OlivTheme.olive)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.dismissMessage() } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Dismiss message")
                    .accessibilityIdentifier("dismissMessageButton")
                }
                .padding(16)
                .background(OlivTheme.inset)
                .accessibilityIdentifier("statusMessage")
            }
        }
    }
}
