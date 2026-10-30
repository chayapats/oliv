import SwiftUI
import AppIntents

struct QuickAccessView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "Ready where you type")
                    Text("Less switching.\nMore speaking.")
                        .font(.system(.largeTitle, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Use the OLIV keyboard for automatic insertion, or keep your usual keyboard and paste. The microphone opens only when you start a capture.")
                        .font(.subheadline)
                        .foregroundStyle(OlivTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                OlivCard {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Image(systemName: "button.programmable")
                                .font(.title2)
                                .foregroundStyle(OlivTheme.olive)
                            Spacer()
                            Text("OLIV KEYBOARD")
                                .font(.caption2.weight(.semibold))
                                .tracking(1)
                                .foregroundStyle(OlivTheme.olive)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(OlivTheme.inset, in: Capsule())
                        }
                        SectionHeading(title: "Speak into the same field", caption: "A minimal keyboard, started with your Action button or Back Tap.")
                        GuideStep(number: "1", title: "Enable the OLIV keyboard", detail: "iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard → OLIV. Enable Allow Full Access so OLIV can hand the finished text to its keyboard. The keyboard does not send your typing to a server.")
                        GuideStep(number: "2", title: "Select OLIV where you write", detail: "Use the keyboard switcher to choose OLIV. You can keep it selected for everyday Thai and English typing.")
                        GuideStep(number: "3", title: "Assign Toggle OLIV", detail: "iPhone Settings → Action Button → swipe to Controls → Choose a Control → Toggle OLIV. On any other iPhone, add Toggle OLIV to Control Center. Leave Live Activities enabled for OLIV in iPhone Settings.")
                        GuideStep(number: "4", title: "Start once. Speak. Pause.", detail: "Press and hold the Action button once, or use your assigned Back Tap gesture. Wait for Listening, then speak. By default, OLIV finishes after 1.5 seconds without detected speech. Invoke again to finish sooner. Keep the same field and cursor for automatic draft insertion; OLIV does not send the message.")
                        Label("Typing keeps the microphone off. Capture releases it before processing your words.", systemImage: "mic.slash")
                            .font(.caption)
                            .foregroundStyle(OlivTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ShortcutsLink()
                            .shortcutsLinkStyle(.automaticOutline)
                            .accessibilityIdentifier("openShortcutsButton")
                            .frame(maxWidth: .infinity)
                    }
                }

                OlivCard {
                    VStack(alignment: .leading, spacing: 17) {
                        SectionHeading(title: "Keep your usual keyboard", caption: "Use the same capture gesture, then paste.")
                        Text("Start with Toggle OLIV and speak. After automatic finish and processing, use Copy Latest OLIV, then paste where you’re writing.")
                        Text("For a two-run clipboard shortcut, turn off Action button auto-finish. Follow Toggle OLIV with If Result has any value → Copy to Clipboard. The first run starts; the second finishes and copies. Choose Local Only to keep the clipboard on this iPhone.")
                            .font(.caption)
                            .foregroundStyle(OlivTheme.secondary)
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }

                OlivCard {
                    VStack(alignment: .leading, spacing: 17) {
                        SectionHeading(title: "A reliable starting point", caption: "Use Capture with OLIV when opening the app suits your flow.")
                        Label("Opens Oliv and starts recording", systemImage: "arrow.up.forward.app")
                        Label("Finish from the app or Live Activity", systemImage: "waveform")
                        Label("Copy the result, then paste it anywhere", systemImage: "doc.on.clipboard")
                        Text("Add Capture with OLIV to a shortcut, the Home Screen, or an available widget. Finish OLIV stops an existing recording without starting a new one.")
                            .font(.caption)
                            .foregroundStyle(OlivTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                }

                OlivCard {
                    VStack(alignment: .leading, spacing: 15) {
                        SectionHeading(title: "Right where you need it")
                        accessRow(symbol: "switch.2", title: "Control Center & Lock Screen", detail: "Add an Oliv control from the iOS controls gallery for quick access.")
                        OlivDivider()
                        accessRow(symbol: "waveform", title: "Live Activity", detail: "While recording, finish or discard from the Live Activity. Your result is also available in OLIV.")
                        OlivDivider()
                        accessRow(symbol: "mic", title: "Siri & Shortcuts", detail: "Try “Capture with Oliv,” or use Oliv’s actions in your own shortcuts.")
                    }
                }

                VStack(alignment: .leading, spacing: 11) {
                    Label("A few iPhone realities", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                    Text("Connect your server and record once inside OLIV to allow microphone access. Toggle OLIV also requires Live Activities. If a background start fails, OLIV explains the problem without opening the app. Capture with OLIV is the separate action that opens it.")
                    Text("Automatic insertion needs the OLIV keyboard already active. Apple's keyboard still requires Paste. Secure and phone fields use the system keyboard, and some apps block custom keyboards.")
                    Text("OLIV’s layout does not include Apple’s prediction, autocorrection or swipe typing. Automatic finish detects speech, not who is speaking; nearby voices can delay it. If no speech is detected, capture cancels after a short wait. Releasing the Action button does not stop recording.")
                }
                .font(.caption)
                .foregroundStyle(OlivTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.bottom, 18)
            }
            .padding(22)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .olivScreen()
        .navigationTitle("Quick access")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func accessRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(OlivTheme.olive)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(OlivTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GuideStep: View {
    let number: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(OlivTheme.olive)
                .frame(width: 27, height: 27)
                .background(OlivTheme.inset, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(OlivTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}
