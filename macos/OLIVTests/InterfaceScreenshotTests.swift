// Offscreen renders of the Mac interface — every Settings page, onboarding,
// the free-trial offer, the wrong-result report, the menu and the recording
// HUD — for checking a translation for truncation or clipped Thai vowels and
// tone marks. Nothing is shown on screen and no real settings, Keychain items,
// hotkeys, network or microphone are touched (the trial's server is the
// placeholder oliv.example.com, and its sign-up is faked).
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

    /// `scrolledToEnd` scrolls every scroll view to its end first (the Setup
    /// window is a fixed 520×560 with a scrolling middle).
    private func render<V: View>(_ view: V, size: CGSize, name: String, scrolledToEnd: Bool = false) throws {
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
        if scrolledToEnd {
            for scroll in Self.scrollViews(in: hosting) {
                guard let document = scroll.documentView else { continue }
                let end = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent("\(language)-\(name).png"))
        window.contentView = nil
    }

    /// Voice-editing settings in the throwaway suite, never the user's own.
    private func sampleVoiceSettings() -> VoiceEditSettings {
        let voice = VoiceEditSettings(defaults: defaults)
        voice.commandEnabled = true
        voice.translateWithSecondary = true
        voice.addTranslationApp("com.apple.mail")
        return voice
    }

    /// A trial on the placeholder server whose sign-up never touches the
    /// network: it grants a key, or fails with `error`.
    private func sampleTrial(failing error: Error? = nil) -> CloudTrial {
        let now = Date(timeIntervalSince1970: 1_798_000_000)   // a fixed date in 2026
        return CloudTrial(serverURL: "https://oliv.example.com", keychain: InMemoryKeychain(),
                          defaults: defaults, now: { now }, requestKey: { _ in
            if let error { throw error }
            return TrialGrant(token: "trial-dummy", expiresAt: now.addingTimeInterval(7 * 86_400),
                              requestsPerMinute: 6, dailyRequests: 60)
        })
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { ($0 as? NSScrollView).map { [$0] } ?? scrollViews(in: $0) }
    }

    func testCleanupMemoryModes() throws {
        let settings = sampleSettings()
        for mode in CleanupMemoryMode.allCases {
            settings.cleanupMemoryMode = mode
            try render(GeneralSettingsView().environmentObject(settings),
                       size: CGSize(width: 720, height: 850), name: "memory-\(mode.rawValue)")
        }
    }

    func testSettingsPages() throws {
        let settings = sampleSettings()
        let appState = AppState()
        let sync = DictionarySync(defaults: defaults, autoSync: false)
        let models = ModelState()
        let permissions = PermissionsModel()
        let trial = sampleTrial()
        let voice = sampleVoiceSettings()
        // Dictation engine needs the running app's coordinator (its effective
        // engine and the trial's actions); its trial card is rendered on its
        // own in testCloudTrial.
        for (index, page) in SettingsPage.allCases.enumerated() where page != .engines {
            let view = SettingsView(page: page, voice: voice)
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(sync)
                .environmentObject(models)
                .environmentObject(permissions)
                .environmentObject(trial)
            // The window's default size, then tall enough to show the whole page.
            try render(view, size: CGSize(width: 980, height: 740), name: "settings-\(index + 1)-\(page.rawValue)")
            try render(view, size: CGSize(width: 980, height: 1700), name: "settings-\(index + 1)-\(page.rawValue)-full")
        }
    }

    func testVoiceEditingWithPausedShortcuts() throws {
        // Both shortcuts overlap another one: Settings says each is paused.
        let settings = sampleSettings()
        settings.engineID = OLIVSettings.Engine.typhoon.id
        settings.hotkeySecondaryID = HotkeyChord(keys: [.rightOption, .rightCommand]).id
        let voice = sampleVoiceSettings()
        voice.commandHotkeyID = HotkeyChord.default.id
        let view = SettingsView(page: .voiceEditing, voice: voice)
            .environmentObject(AppState())
            .environmentObject(settings)
            .environmentObject(DictionarySync(defaults: defaults, autoSync: false))
            .environmentObject(ModelState())
            .environmentObject(PermissionsModel())
            .environmentObject(sampleTrial())
        try render(view, size: CGSize(width: 980, height: 1700), name: "settings-voiceEditing-paused-full")
    }

    func testOnboarding() throws {
        let settings = sampleSettings()
        let view = OnboardingView(permissions: PermissionsModel(), models: ModelState(), settings: settings,
                                  trial: sampleTrial(), onDone: {})
        try render(view, size: CGSize(width: 520, height: 560), name: "onboarding")
    }

    func testCloudTrial() async throws {
        // The offer as Setup shows it on a new Mac (on-device engine, models
        // still downloading), then on, then each reason it is off.
        let settings = sampleSettings()
        settings.engineID = OLIVSettings.Engine.typhoon.id
        let offered = sampleTrial()
        try render(OnboardingView(permissions: PermissionsModel(), models: ModelState(), settings: settings,
                                  trial: offered, onDone: {}),
                   size: CGSize(width: 520, height: 560), name: "onboarding-trial-offer", scrolledToEnd: true)
        let active = sampleTrial()
        await active.start()
        XCTAssertEqual(active.phase, .on)
        try render(OnboardingView(permissions: PermissionsModel(), models: ModelState(), settings: settings,
                                  trial: active, onDone: {}),
                   size: CGSize(width: 520, height: 560), name: "onboarding-trial-on", scrolledToEnd: true)

        var states: [(String, CloudTrial)] = [("offer", sampleTrial()), ("on", active)]
        let refusals: [(String, Error)] = [
            ("client-limit", TrialRefusal.clientLimit), ("daily-limit", TrialRefusal.dailyLimit),
            ("full", TrialRefusal.full), ("closed", TrialRefusal.closed),
            ("unavailable", TrialRefusal.unavailable), ("unreachable", OLIVAPIError.network),
            ("failed", OLIVAPIError.invalidReply),
        ]
        for (name, error) in refusals {
            let trial = sampleTrial(failing: error)
            await trial.start()
            states.append((name, trial))
        }
        let stopped = sampleTrial()
        await stopped.start()
        _ = stopped.reconcile(selectedEngine: OLIVSettings.Engine.typhoon.id, modelsReady: false, downloading: false)
        states.append(("download-stopped", stopped))
        let ended = sampleTrial()
        await ended.start()
        ended.keyRejected()
        states.append(("ended", ended))
        // The width the card gets inside Settings › Dictation engine.
        let sheet = VStack(alignment: .leading, spacing: 12) {
            ForEach(states.indices, id: \.self) { i in
                CloudTrialOfferView(trial: states[i].1, offered: true, onStart: {}, onStop: {})
            }
        }
        .padding(16)
        .frame(width: 640, alignment: .top)
        try render(sheet, size: CGSize(width: 640, height: 1900), name: "trial-states")
    }

    func testResultReport() throws {
        var details = TranscriptLog.Details(raw: "ประชุม กับ ทีม กราฟาน่า พรุ่งนี้ บ่าย สอง", engineID: "typhoon-turbo-mlx",
                                            cleanup: true)
        details.llmRan = true
        details.gateReason = "dict-hit"
        details.guardrailFlag = "ok"
        details.sttSeconds = 0.6
        details.cleanupSeconds = 0.4
        details.audioSeconds = 3.2
        let entry = TranscriptLog.Entry(text: "ประชุมกับทีม Grafana พรุ่งนี้บ่ายสอง", details: details)
        let report = ResultReport.mac(entry: entry, appVersion: "0.2.2", build: "19", macOSVersion: "Version 26.1")
        let draft = ResultReportDraft(report: report, open: { _ in XCTFail("nothing opens from a render") })
        draft.meant = "ประชุมกับทีม Grafana พรุ่งนี้บ่ายสองโมง"
        try render(ResultReportView(draft: draft, onClose: {}), size: CGSize(width: 540, height: 720),
                   name: "report-preview")
        // Long text: the cut note appears.
        draft.typed = String(repeating: "ข้อความยาวมาก ", count: 600)
        try render(ResultReportView(draft: draft, onClose: {}), size: CGSize(width: 540, height: 760),
                   name: "report-preview-truncated")
        // A Command mode edit: selection, instruction and result, each labelled.
        details.raw = "ทำ ให้ สุภาพ ขึ้น"
        details.voiceEdit = TranscriptLog.VoiceEdit(
            mode: .command, heard: "ทำให้สุภาพขึ้น", selection: "ส่งไฟล์ deck มาด่วนเลย ลูกค้าจะเอาบ่ายนี้",
            applied: true, flag: "ok")
        let edit = TranscriptLog.Entry(text: "รบกวนช่วยส่งไฟล์ deck มาให้หน่อยนะครับ ลูกค้าต้องการภายในบ่ายนี้ครับ",
                                       details: details)
        let command = ResultReportDraft(
            report: ResultReport.mac(entry: edit, appVersion: "0.2.2", build: "19", macOSVersion: "Version 26.1"),
            open: { _ in XCTFail("nothing opens from a render") })
        try render(ResultReportView(draft: command, onClose: {}), size: CGSize(width: 540, height: 820),
                   name: "report-preview-command")
    }

    func testMenu() throws {
        // The real menu is an NSMenu that only exists while the app runs; this
        // lays out the same items, from the same strings, the way the menu shows them.
        let stats = LastDictationStats(chars: 38, sttSeconds: 0.9, cleanupSeconds: 0.5, engineID: "typhoon-turbo-mlx")
        try render(MenuPreview(stats: stats), size: CGSize(width: 320, height: 380), name: "menu")
        try render(RecentMenuPreview(), size: CGSize(width: 640, height: 200), name: "menu-recent")
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
        // Command mode and translation name themselves instead of the engine.
        for mode in [DictationMode.translate, .command] {
            model.mode = mode
            for phase in [HUDPhase.recording, .processing] {
                model.phase = phase
                try render(RecordingHUDView(model: model).padding(10), size: size, name: "hud-\(mode)-\(phase)")
            }
        }
        model.mode = .dictate
        model.engineID = CloudTrial.engineID
        model.phase = .recording
        try render(RecordingHUDView(model: model).padding(10), size: size, name: "hud-trial-recording")
        let undo = HotkeyChord.defaultUndo.displayName
        let notices: [(String, String)] = [
            ("trial-ready", String(localized: "Models ready — dictating on this Mac again")),
            ("trial-ended", String(localized: "Free trial ended — wait for the download to finish")),
            ("trial-stopped", String(localized: "Download stopped — the OLIV server trial is off")),
            ("trial-off", String(localized: "The free trial is off — nothing was sent")),
            ("trial-403", CloudTrial.notice(for: OLIVAPIError.http(403)) ?? ""),
            ("trial-429", CloudTrial.notice(for: OLIVAPIError.http(429)) ?? ""),
            ("trial-cooldown", CloudTrial.notice(for: OLIVAPIError.cooldown(42)) ?? ""),
            ("edit-done", String(localized: "Edited · \(undo) undoes it")),
            ("edit-nothing", String(localized: "Nothing to change")),
            ("edit-no-instruction", String(localized: "Didn’t catch an instruction — your text is unchanged")),
            ("edit-model", String(localized: "Command mode needs the on-device cleanup model — download it in Settings")),
            ("edit-too-long", VoiceEditRunner.failedNotice("tooLong").text),
            ("edit-select", VoiceEditRunner.failedNotice("emptySelection").text),
            ("edit-unsure", VoiceEditRunner.failedNotice("guardrail").text),
            ("edit-unreachable", VoiceEditRunner.failedNotice("llmError").text),
            ("edit-other-app", VoiceEditRunner.clipboardNotice(.otherApp).text),
            ("edit-changed", VoiceEditRunner.clipboardNotice(.changed).text),
            ("edit-unconfirmed", VoiceEditRunner.clipboardNotice(.unverifiable).text),
            ("edit-verbatim", VoiceEditRunner.refused(.verbatim).notice?.text ?? ""),
            ("edit-password", VoiceEditRunner.refused(.passwordManager).notice?.text ?? ""),
            ("translate-off-here", String(localized: "Translation is off in this app — pasted what you said")),
            ("translate-model", String(localized: "Translation needs the on-device cleanup model — pasted what you said")),
            ("translate-failed", String(localized: "Couldn’t translate — pasted what you said")),
            ("translate-unsure", String(localized: "Couldn’t translate that — pasted what you said")),
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

/// The Recent submenu with its Report a Wrong Result submenu open.
private struct RecentMenuPreview: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            menu {
                item(Text(verbatim: "ประชุมกับทีม Grafana พรุ่งนี้บ่ายสอง"))
                item(Text(verbatim: "ส่งไฟล์ให้หน่อยนะ"))
                Divider().padding(.vertical, 5)
                item(Text("Report a Wrong Result"), trailing: "›")
            }
            menu {
                item(Text(verbatim: "ประชุมกับทีม Grafana พรุ่งนี้บ่ายสอง"))
                item(Text(verbatim: "ส่งไฟล์ให้หน่อยนะ"))
            }
            .padding(.top, 62)
        }
        .padding(10)
    }

    private func menu<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .font(.system(size: 13))
            .padding(.vertical, 6)
            .frame(width: 290, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func item(_ content: Text, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            content.lineLimit(1)
            Spacer(minLength: 12)
            if let trailing { Text(trailing).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 22).padding(.vertical, 3)
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
