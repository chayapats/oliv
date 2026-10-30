import SwiftUI

struct KeyboardSetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your keyboard.\nYour voice.")
                    .font(.system(.largeTitle, design: .serif))
                Text("A simple Thai and English keyboard. Use the Action button to dictate without a microphone button taking over your keyboard.")
                    .foregroundStyle(OlivTheme.secondary)
                OlivCard {
                    VStack(alignment: .leading, spacing: 18) {
                        step("1", "Enable OLIV", "iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard → OLIV.")
                        step("2", "Allow Full Access", "Open OLIV in that keyboard list and enable Allow Full Access. This lets the keyboard receive your requested transcript from the OLIV app. Ordinary typing stays on your iPhone.")
                        step("3", "Select the keyboard", "In a text field, hold the globe and choose OLIV. Use the ไทย / EN key to change languages.")
                        step("4", "Assign Toggle OLIV", "Create a shortcut containing Toggle OLIV, then select it under iPhone Settings → Action Button → Shortcut. By default, one invocation starts a capture that finishes after you pause.")
                    }
                }
                OlivCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Microphone only when requested", systemImage: "mic.slash")
                            .font(.headline)
                        Text("First connect your server and allow the microphone by recording once in OLIV. Leave Live Activities enabled for OLIV in iPhone Settings; recording from Toggle OLIV requires an active Live Activity.")
                        Text("With OLIV selected in your field, press and hold the Action button once. Wait for Listening, speak, then pause. OLIV finishes after 1.5 seconds without detected speech. Invoke again to finish sooner. No speech cancels the capture after a short wait. The microphone stops before transcription and stays off while idle.")
                        Text("Keep the same field and cursor while speaking. If you switch fields, edit text or hide the keyboard, use the finished result in OLIV instead. Inserted text is a draft: OLIV does not choose a conversation or send messages in LINE or other apps.")
                    }
                    .font(.subheadline)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("A few differences from Apple’s keyboard").font(.headline)
                    Text("This keyboard supports ordinary typing, Thai/English, shift, numbers, symbols, long-press accents and spacebar cursor movement. It does not include Apple’s predictive text, autocorrect or swipe-typing engine.")
                    Text("Passwords, some phone fields and apps that disallow third-party keyboards use the system keyboard. Background recording eligibility depends on iOS. Capture with OLIV opens the app to record; use Copy/Paste for that foreground route.")
                }
                .font(.caption).foregroundStyle(OlivTheme.secondary)
            }
            .padding(22)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .olivScreen()
        .navigationTitle("OLIV Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.bold())
                .frame(width: 26, height: 26).background(OlivTheme.inset, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(OlivTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
