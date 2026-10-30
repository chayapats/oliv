import SwiftUI
import UIKit

/// First-run setup. Each step checks itself, so nobody has to judge whether a
/// system setting took effect or understand servers and keys.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var step = Step.welcome
    @State private var sampleText = ""
    @State private var keyboardReady = false
    @FocusState private var sampleFocused: Bool
    @Environment(\.openURL) private var openURL

    private enum Step: Int, CaseIterable { case welcome, microphone, dictation, keyboard, trigger }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                progress
                switch step {
                case .welcome: welcome
                case .microphone: microphone
                case .dictation: dictation
                case .keyboard: keyboard
                case .trigger: trigger
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .olivScreen()
        .onChange(of: model.isConfigured) { _, connected in
            if connected, step == .welcome { step = .microphone }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? OlivTheme.olive : OlivTheme.line)
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Speak. OLIV writes.", "Thai and English in one sentence, turned into clean text in any app.")
            if model.offersTrial {
                Button {
                    Task { await model.startTrial() }
                } label: {
                    HStack(spacing: 10) {
                        if model.isStartingTrial { ProgressView().tint(OlivTheme.oliveContrast) }
                        Text("Start free trial")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(OlivPrimaryButtonStyle())
                .disabled(model.isStartingTrial)
                .accessibilityIdentifier("startTrialButton")
                Text("7 days free. No account or card. Audio goes to the OLIV server to become text, and isn't kept there.")
                    .font(.caption)
                    .foregroundStyle(OlivTheme.secondary)
                if let message = model.trialMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.warning)
                        .accessibilityIdentifier("trialMessage")
                }
            }
            Button { leaveForSettings() } label: { wide("I have an API key") }
                .buttonStyle(OlivSecondaryButtonStyle())
                .accessibilityIdentifier("useOwnKeyButton")
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Let OLIV hear you", "The microphone turns on only when you start a recording, and off as soon as you finish.")
            if model.microphoneDenied {
                Text("Microphone access is off. Turn it on for OLIV in Settings, then come back.")
                    .font(.subheadline)
                    .foregroundStyle(OlivTheme.warning)
                Button { openSystemSettings() } label: { wide("Open Settings") }
                    .buttonStyle(OlivPrimaryButtonStyle())
                    .accessibilityIdentifier("openSettingsButton")
            } else {
                Button {
                    Task {
                        if await model.requestMicrophone() { step = .dictation }
                    }
                } label: { wide("Allow microphone") }
                .buttonStyle(OlivPrimaryButtonStyle())
                .accessibilityIdentifier("allowMicrophoneButton")
            }
        }
        .onAppear { if model.microphoneAllowed { step = .dictation } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if model.microphoneAllowed { step = .dictation }
        }
    }

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Try it now", "Tap, then say something the way you normally talk. Mix Thai and English.")
            Text("“พรุ่งนี้มี meeting ตอนสิบโมงนะครับ”")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(OlivTheme.secondary)
            if let latest = model.latest, latest.reply.hasText {
                OlivCard {
                    Text(latest.finalText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("setupResult")
                }
            }
            Button {
                Task { await model.toggleRecording() }
            } label: {
                HStack(spacing: 10) {
                    if model.phase == .processing || model.phase == .preparing {
                        ProgressView().tint(OlivTheme.oliveContrast)
                    } else {
                        Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                    }
                    Text(dictationButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(OlivPrimaryButtonStyle())
            .disabled(model.phase == .processing || model.phase == .preparing)
            .accessibilityIdentifier("setupRecordButton")
            if let message = model.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(OlivTheme.warning)
            }
            nextButton(model.latest?.reply.hasText == true ? "Next" : "Skip for now", to: .keyboard)
        }
    }

    private var dictationButtonTitle: LocalizedStringKey {
        if model.isRecording { return "Stop" }
        if model.phase == .processing { return "Writing…" }
        return model.latest?.reply.hasText == true ? "Try again" : "Start speaking"
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Use it in every app", "Add the OLIV keyboard so your words appear right where you're typing.")
            numbered("1", "Tap the button below, then Keyboards. Turn on OLIV and Allow Full Access.")
            Button { openSystemSettings() } label: { wide("Open Settings") }
                .buttonStyle(OlivSecondaryButtonStyle())
                .accessibilityIdentifier("openKeyboardSettingsButton")
            numbered("2", "Come back, tap the box below, then hold the globe key and choose OLIV.")
            TextField("Tap here", text: $sampleText, axis: .vertical)
                .lineLimit(2...3)
                .focused($sampleFocused)
                .olivField()
                .accessibilityIdentifier("keyboardPracticeField")
            if keyboardReady {
                Label("OLIV keyboard is ready", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OlivTheme.olive)
                    .accessibilityIdentifier("keyboardReadyLabel")
            }
            Text("Typing stays on your iPhone. Full Access only lets the keyboard receive text you dictated in OLIV.")
                .font(.caption)
                .foregroundStyle(OlivTheme.secondary)
            nextButton(keyboardReady ? "Next" : "Skip for now", to: .trigger)
        }
        .task {
            // Bounded to this screen; the bridge is otherwise never polled.
            while !Task.isCancelled, !keyboardReady {
                keyboardReady = await model.keyboardIsConnected()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var trigger: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Start with one press", "Set up one way to start OLIV from any app.")
            OlivCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Action button", systemImage: "button.programmable").font(.headline)
                    Text("iPhone Settings → Action Button → swipe to Controls → Choose a Control → Toggle OLIV. Then press and hold the button, speak, and pause.")
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.secondary)
                }
            }
            OlivCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Any other iPhone", systemImage: "switch.2").font(.headline)
                    Text("Open Control Center, tap +, then Add a Control, and choose Toggle OLIV. Tap it whenever you want to speak.")
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.secondary)
                }
            }
            Button { model.finishSetup() } label: { wide("Finish") }
                .buttonStyle(OlivPrimaryButtonStyle())
                .accessibilityIdentifier("finishSetupButton")
        }
    }

    private func wide(_ label: LocalizedStringKey) -> some View {
        Text(label).frame(maxWidth: .infinity)
    }

    private func title(_ heading: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading)
                .font(.system(.largeTitle, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.body)
                .foregroundStyle(OlivTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func numbered(_ number: String, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.bold())
                .frame(width: 26, height: 26)
                .background(OlivTheme.inset, in: Circle())
            Text(detail)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nextButton(_ label: LocalizedStringKey, to next: Step) -> some View {
        Button {
            sampleFocused = false
            step = next
        } label: { wide(label) }
        .buttonStyle(OlivSecondaryButtonStyle())
        .accessibilityIdentifier("setupNextButton")
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func leaveForSettings() {
        model.selectedTab = 2
        model.finishSetup()
    }
}
