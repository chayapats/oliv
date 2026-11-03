// Offscreen renders of the Mac interface — every Settings page, onboarding,
// the menu and the recording HUD — for checking a translation for truncation
// or clipped Thai vowels and tone marks. Nothing is shown on screen and no
// real settings, Keychain items, hotkeys or microphone are touched.
//
// Skipped unless OLIV_SCREENSHOT_DIR is set. To render the Thai interface:
//
//   TEST_RUNNER_OLIV_SCREENSHOT_DIR=/tmp/oliv-th TEST_RUNNER_HF_HOME=/tmp/oliv-th-models \
//   xcodebuild test -project macos/OLIV.xcodeproj -scheme OLIV \
//     -destination 'platform=macOS,arch=arm64' -testLanguage th -testRegion TH \
//     -only-testing:OLIVTests/InterfaceScreenshotTests
//
// (HF_HOME points the Models page at an empty folder, so no local paths or
// model sizes appear in the pictures.)

import AppKit
import SwiftUI
import XCTest
@testable import OLIV

@MainActor
final class InterfaceScreenshotTests: XCTestCase {
    private var outputDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["OLIV_SCREENSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("set OLIV_SCREENSHOT_DIR to render the interface")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        suiteName = "oliv.tests.screenshots.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Settings with a few Dictionary words, a waiting suggestion and the OLIV
    /// API filled in with a placeholder server (never a real one).
    private func sampleSettings() -> OLIVSettings {
        let settings = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        _ = settings.addDictionaryEntry(word: "Grafana", correction: "กราฟาน่า")
        if let entry = settings.addDictionaryEntry(word: "บางแค", correction: nil) {
            settings.setDictionaryEntryStarred(id: entry.id, starred: true)
        }
        _ = settings.addDictionaryEntry(word: "Kubernetes", correction: nil)
        _ = settings.proposeAutoLearnCandidates(
            [AutoLearnCandidate(word: "Typhoon", correction: "ไต้ฝุ่น", reason: AutoLearnCandidate.reasonUndoRedictate)],
            explicit: true)
        settings.olivAPIEnabled = true
        settings.olivAPIURL = "https://oliv.example.com"
        return settings
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) throws {
        let root = view
            .environment(\.locale, Locale(identifier: language))
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let onAppear, timers and async layout settle before drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent("\(language)-\(name).png"))
        window.contentView = nil
    }

    func testSettingsPages() throws {
        let settings = sampleSettings()
        let appState = AppState()
        let sync = DictionarySync(defaults: defaults, autoSync: false)
        let models = ModelState()
        let permissions = PermissionsModel()
        for (index, page) in SettingsPage.allCases.enumerated() {
            let view = SettingsView(page: page)
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(sync)
                .environmentObject(models)
                .environmentObject(permissions)
            // The window's default size, then tall enough to show the whole page.
            try render(view, size: CGSize(width: 980, height: 740), name: "settings-\(index + 1)-\(page.rawValue)")
            try render(view, size: CGSize(width: 980, height: 1700), name: "settings-\(index + 1)-\(page.rawValue)-full")
        }
    }

    func testOnboarding() throws {
        let settings = sampleSettings()
        let view = OnboardingView(permissions: PermissionsModel(), models: ModelState(), settings: settings, onDone: {})
        try render(view, size: CGSize(width: 520, height: 560), name: "onboarding")
    }

    func testMenu() throws {
        // The real menu is an NSMenu that only exists while the app runs; this
        // lays out the same items, from the same strings, the way the menu shows them.
        let stats = LastDictationStats(chars: 38, sttSeconds: 0.9, cleanupSeconds: 0.5, engineID: "typhoon-turbo-mlx")
        try render(MenuPreview(stats: stats), size: CGSize(width: 320, height: 380), name: "menu")
    }

    func testRecordingHUD() throws {
        let model = HUDModel()
        model.engineID = "typhoon-turbo-mlx"
        for i in 0..<HUDModel.barCount { model.push(level: Float(abs(sin(Double(i) / 3))) * 0.8) }
        let size = CGSize(width: 240, height: 76)
        for phase in [HUDPhase.warming, .recording, .processing] {
            model.phase = phase
            try render(RecordingHUDView(model: model).padding(10), size: size, name: "hud-\(phase)")
        }
        let notices: [(String, String)] = [
            ("mic", String(localized: "Couldn’t open the microphone — try again")),
            ("api", String(localized: "OLIV API is disabled or incomplete — check Settings")),
            ("limit", String(localized: "Hit the \(2)-minute recording limit — the end was cut off")),
            ("fallback", String(localized: "Used \(DictationExecution(engineID: "typhoon-turbo-mlx").label) fallback")),
            ("suggestion", DictationController.suggestionNotice(
                AutoLearnCandidate(word: "Grafana", correction: "กราฟาน่า", reason: AutoLearnCandidate.reasonUndoRedictate))),
            ("clipboard", String(localized: "Text is on the clipboard — press ⌘V")),
            ("copied", String(localized: "Copied — press ⌘V to paste")),
            ("error", OLIVAPIError.http(403).errorDescription ?? ""),
        ]
        model.phase = .notice
        for (name, text) in notices {
            model.noticeText = text
            model.noticeSymbol = "exclamationmark.triangle.fill"
            try render(RecordingHUDView(model: model).padding(10), size: size, name: "hud-notice-\(name)")
        }
    }
}

/// The menu bar menu's items (MenuContentView), drawn like a menu.
private struct MenuPreview: View {
    let stats: LastDictationStats

    var body: some View {
        let execution = DictationExecution(engineID: "typhoon-turbo-mlx")
        VStack(alignment: .leading, spacing: 0) {
            item(Text("OLIV — \(DictationStatus.idle.label)"), dimmed: true)
            item(Label("Engine: \(execution.label)", systemImage: execution.systemImage), dimmed: true)
            item(Text(stats.menuLine).font(.caption), dimmed: true)
            item(Text("Enable dictation"), check: true)
            item(Text("Recent…"), trailing: "›")
            Divider().padding(.vertical, 5)
            item(Text("Setup… (action needed)"))
            item(Text("Check for Updates…"))
            item(Text("Settings…"), trailing: "⌘,")
            item(Text("Review Dictionary Suggestions (\(1))…"))
            Divider().padding(.vertical, 5)
            item(Text("Copy Diagnostics"))
            item(Text("Quit OLIV"), trailing: "⌘Q")
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .padding(10)
    }

    private func item<Content: View>(_ content: Content, dimmed: Bool = false, check: Bool = false,
                                     trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: check ? "✓" : " ").frame(width: 12)
            content.foregroundStyle(dimmed ? .secondary : .primary)
            Spacer(minLength: 12)
            if let trailing { Text(trailing).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
    }
}
