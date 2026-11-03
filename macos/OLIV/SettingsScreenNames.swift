import ApplicationServices
import SwiftUI

/// Settings › Text: names on screen (opt-in). See ScreenContext.
struct ScreenNamesSettingsCard: View {
    @EnvironmentObject private var settings: OLIVSettings

    var body: some View {
        SettingsCard(title: "Names on screen", icon: "person.text.rectangle",
                     subtitle: "Spell the names you can see, without adding them to the Dictionary.") {
            SettingsToggle(title: "Spell names that are on screen",
                           detail: "When you start dictating, OLIV reads the text in the window you’re typing into and uses the names and terms it finds for that one dictation. The text stays in memory on this Mac and is never saved or sent anywhere. Password fields, password managers and your verbatim apps are skipped. Your Dictionary always wins. Applies when cleanup is enabled.",
                           isOn: $settings.screenNames)
            if settings.usesOLIVAPI {
                SettingsNotice(text: "Works with on-device text processing only. With OLIV API selected, cleanup runs on the server, so OLIV doesn’t read the screen.",
                               icon: "info.circle", warning: true)
            } else if settings.screenNames, !AXIsProcessTrusted() {
                SettingsNotice(text: "Needs Accessibility, which OLIV also uses to paste. Turn it on in System Settings › Privacy & Security › Accessibility.",
                               warning: true)
            }
        }
    }
}
