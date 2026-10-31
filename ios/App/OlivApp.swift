import SwiftUI

@main
struct OlivApp: App {
    #if DEBUG
    @UIApplicationDelegateAdaptor(KeyboardReferenceAppDelegate.self) private var referenceDelegate
    #endif
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            appContent
                .onOpenURL { url in
                    guard url.scheme == "oliv" else { return }
                    // URL links navigate only. Recording always requires an explicit user action.
                    model.selectedTab = url.host == "settings" ? 2 : 0
                }
                .onChange(of: scenePhase) { _, phase in
                    // Pick up Dictionary edits made on other devices.
                    if phase == .active { model.scheduleDictionarySync(after: 0) }
                }
        }
    }

    @ViewBuilder private var appContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--keyboard-test-host") {
            KeyboardTestHostView(model: model)
        } else {
            ContentView(model: model)
        }
        #else
        ContentView(model: model)
        #endif
    }
}
