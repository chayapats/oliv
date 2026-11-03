// App coordinator (W3-T4). Owns the shared state the SwiftUI scenes render
// (AppState, settings, permissions, models) and the DictationController, wires
// persisted settings into the live controller, and drives onboarding: auto-show
// at launch when something required is missing, and on demand from the menu's
// "Setup…". Also owns the menu-icon "needs attention" badge state.
//
// Why an AppDelegate rather than pure SwiftUI scenes: a menu-bar-only
// (LSUIElement) app has no window by default, and auto-showing one at launch +
// activating it reliably is squarely NSApplication territory. The onboarding
// window is a plain NSWindow hosting the SwiftUI OnboardingView (see
// OnboardingWindowController) so it can be shown/activated programmatically.

import AppKit
import Combine
import SwiftUI
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    let settings = OLIVSettings.shared
    let voiceEditSettings = VoiceEditSettings.shared
    let permissions = PermissionsModel()
    let models = ModelState()
    let controller: DictationController
    /// Keeps the Dictionary in step with the OLIV server (and other devices).
    let dictionarySync = DictionarySync()
    /// Last API configuration pushed to sync; a change triggers a resync.
    private var syncedAPIConfiguration: OLIVAPIConfiguration?
    /// Opt-in: dictate through the OLIV server while the models download.
    let trial = CloudTrial()
    /// What dictation uses right now: the selected engine, or the free trial
    /// in its place while that engine's models download. Menu and Settings
    /// label this, so "Cloud" shows whenever audio would leave the Mac.
    @Published private(set) var effectiveEngineID = SidecarClient.defaultEngine
    /// A trial hand-back to tell the user, held until nothing is recording.
    private var pendingAnnouncement: TrialAnnouncement?
    /// Fires when the trial key expires (see scheduleTrialExpiry).
    private var trialExpiryTimer: Timer?
    private var observers: Set<AnyCancellable> = []

    /// Sparkle auto-update (W5-T1). Owns the updater + its standard AppKit user
    /// driver (the update window/prompts). `startingUpdater: true` starts the
    /// scheduler now, which reads SUFeedURL + SUEnableAutomaticChecks from
    /// Info.plist and runs background checks on Sparkle's default cadence — no
    /// custom policy, exactly the SUEnableAutomaticChecks contract. The menu's
    /// "Check for Updates…" drives `updaterController.updater.checkForUpdates()`.
    /// Only ever constructed on the real-app path: this AppDelegate is never
    /// built by the --e2e-file harness (OLIVMain short-circuits before SwiftUI),
    /// so the headless packaged e2e never starts the updater or hits the network.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// Menu-icon badge: a required permission or model is missing. Published so
    /// the menu-bar label re-renders when readiness changes.
    @Published var needsAttention = false

    private var onboarding: OnboardingWindowController?
    private let resultReport = ResultReportWindowController()

    override init() {
        // Before anything else: if a previous run was killed while it had the
        // output volume ducked for a dictation, give the user their volume back.
        // A no-op on every normal launch (see OutputDucker.restoreOrphaned).
        OutputDucker.restoreOrphaned()

        let state = appState
        let ctrl = DictationController(appState: state)
        // W3-T3/T4: delegate orchestration + text to the Rust worker (bundled runtime
        // or locally built native workers during development). Cheap to construct; the
        // child spawns lazily on the first warm/dictate.
        ctrl.sidecar = SidecarClient()
        // W4-T2: the floating recording HUD. Constructed here (real-app path
        // only — the e2e harness never builds AppDelegate); the NSPanel itself is
        // created lazily on first show, so nothing appears until a recording.
        ctrl.hud = RecordingHUDController()
        controller = ctrl
        super.init()

        // Seed the controller from persisted settings — WITHOUT touching the tap
        // (start() installs it after launch on the resolved keys).
        controller.hotkeyChords = settings.activeChords
        controller.undoHotkeyChord = settings.undoHotkeyChord
        controller.voiceEdit = voiceEditSettings.configuration
        controller.sttEngine = settings.engineID
        controller.olivAPIConfiguration = settings.olivAPIConfiguration
        controller.cleanupEnabled = settings.cleanupEnabled
        controller.verbatimApps = settings.verbatimApps
        controller.removeFillers = settings.removeFillers
        controller.dictionaryEntries = settings.dictionaryEntries
        controller.legacySnippets = settings.legacySnippets
        controller.formatCommands = settings.formatCommands
        controller.thaiFormat = settings.thaiFormat
        controller.showHUD = settings.showRecordingIndicator
        controller.micDevice = settings.micDevice
        controller.echoCancellation = settings.echoCancellation
        controller.duckOtherAudio = settings.duckOtherAudio
        controller.historyEnabled = settings.historyEnabled
        // Opt-in cloud fallback: inject GROQ_API_KEY into the sidecar's spawn env
        // only when the toggle is on and a key is set (nil = local-only).
        ctrl.sidecar?.setGroqAPIKey(settings.groqKeyForSidecar)

        controller.dictionarySync = dictionarySync
        // Undo→redictate suggestions go to the settings inbox (gated there on
        // the auto-learn toggle and history; approval is always required).
        controller.autoLearnSettings = settings
        effectiveEngineID = settings.engineID

        // Live-apply: any settings change re-pushes into the running controller.
        settings.onChange = { [weak self] in self?.applyLiveSettings() }
        trial.onChange = { [weak self] in self?.applyEngine() }
        controller.onTrialKeyRejected = { [weak self] in self?.trial.keyRejected() }
        // Download start/finish and model presence decide whether the trial
        // still applies. Received on the next main-queue turn, so a finished
        // download is judged after its disk re-scan, not before.
        models.$isDownloading.combineLatest(models.$repos.map { $0.map(\.present) })
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyEngine() }
            .store(in: &observers)
        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in if status == .idle { self?.flushAnnouncement(after: 3) } }
            .store(in: &observers)
        voiceEditSettings.onChange = { [weak self] in
            guard let self else { return }
            self.controller.applyVoiceEdit(self.voiceEditSettings.configuration)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()          // install the tap + kick off the non-blocking warm
        syncedAPIConfiguration = settings.olivAPIConfiguration
        dictionarySync.attach(to: settings)
        refreshReadiness()
        if needsAttention { showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting mid-hold must not leave the mic open or the user's music
        // ducked. `immediate` makes the volume restore SYNCHRONOUS: the normal
        // path fades it back on a private queue, and a fade does not survive
        // process exit — the user would be left quiet until the next launch's
        // recovery. Idempotent; a no-op when nothing is recording.
        controller.stop(immediate: true)
        models.close()
    }

    /// Push live settings into the running controller. Engine / cleanup /
    /// verbatim take effect on the NEXT utterance (read at release); a hotkey
    /// change restarts the tap immediately.
    private func applyLiveSettings() {
        applyEngine()
        controller.olivAPIConfiguration = settings.olivAPIConfiguration
        controller.cleanupEnabled = settings.cleanupEnabled
        controller.verbatimApps = settings.verbatimApps
        controller.removeFillers = settings.removeFillers
        controller.dictionaryEntries = settings.dictionaryEntries
        controller.legacySnippets = settings.legacySnippets
        controller.formatCommands = settings.formatCommands
        controller.thaiFormat = settings.thaiFormat
        controller.showHUD = settings.showRecordingIndicator
        if !settings.showRecordingIndicator { controller.hud?.hide() }
        controller.micDevice = settings.micDevice
        controller.echoCancellation = settings.echoCancellation
        controller.duckOtherAudio = settings.duckOtherAudio
        controller.historyEnabled = settings.historyEnabled
        // Toggle OFF clears what's already retained immediately (the user just
        // said "stop keeping these"). Idempotent, so re-running on every
        // settings change is harmless.
        if !settings.historyEnabled { appState.clearTranscripts() }
        controller.applyHotkeys(settings.activeChords)
        controller.applyUndoHotkey(settings.undoHotkeyChord)
        // A Groq key/toggle change respawns the sidecar (self-heal) so the new
        // spawn env takes effect on the next dictate; a no-op when unchanged.
        controller.sidecar?.setGroqAPIKey(settings.groqKeyForSidecar)
        if settings.olivAPIConfiguration != syncedAPIConfiguration {
            syncedAPIConfiguration = settings.olivAPIConfiguration
            dictionarySync.configurationChanged()
        }
        refreshReadiness()
    }

    // MARK: Free trial while the models download (CloudTrial)

    var cloudTrialOffered: Bool {
        trial.isOffered(selectedEngine: settings.engineID,
                        modelsReady: models.arePresent(settings.requiredModelRepos))
    }

    /// Onboarding / Settings: the user opted in. The trial lasts as long as
    /// the download, so this starts the download too.
    func startCloudTrial() {
        guard cloudTrialOffered, trial.phase == .off else { return }
        if !models.isDownloading { models.download(settings.requiredModelRepos) }
        Task { await trial.start() }
    }

    func stopCloudTrial() { trial.stop() }

    /// Decide the engine dictation uses: end the trial when the models are
    /// ready, the download stopped, the key ran out, or the user chose a cloud
    /// engine; otherwise the trial stands in for the on-device engine.
    private func applyEngine() {
        let ready = models.arePresent(settings.requiredModelRepos)
        let announcement = trial.reconcile(selectedEngine: settings.engineID, modelsReady: ready,
                                           downloading: models.isDownloading)
        controller.trialConfiguration = trial.configuration
        controller.trialExpiresAt = trial.configuration == nil ? nil : trial.record?.expiresAt
        scheduleTrialExpiry(controller.trialExpiresAt)
        let engine = trial.effectiveEngine(selected: settings.engineID, modelsReady: ready)
        controller.sttEngine = engine
        if effectiveEngineID != engine { effectiveEngineID = engine }
        if let announcement {
            if ready { controller.warmAfterDownload() }
            pendingAnnouncement = announcement
            flushAnnouncement(after: 0)
        }
    }

    /// Reconcile again when the trial key runs out, so the menu, HUD and
    /// Settings stop saying Cloud without waiting for another event.
    /// (DictationController also re-checks the expiry at release.)
    private func scheduleTrialExpiry(_ expiry: Date?) {
        trialExpiryTimer?.invalidate()
        trialExpiryTimer = nil
        guard let expiry else { return }
        let timer = Timer(fire: expiry.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEngine() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trialExpiryTimer = timer
    }

    /// Say it once, when no dictation is using the HUD (the status observer
    /// retries after each one).
    private func flushAnnouncement(after delay: TimeInterval) {
        guard pendingAnnouncement != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.appState.status == .idle, let announcement = self.pendingAnnouncement else { return }
            self.pendingAnnouncement = nil
            self.controller.hud?.notice(announcement.text, systemImage: announcement.systemImage, duration: 6)
        }
    }

    /// Re-scan permissions + models, retry the hotkey tap (in case Input
    /// Monitoring was just granted), and update the badge.
    func refreshReadiness() {
        permissions.refresh()
        models.recheck()
        controller.start()   // idempotent; a no-op if the tap is already live
        needsAttention = !(permissions.allGranted && models.arePresent(settings.requiredModelRepos))
    }

    /// Menu "Recent…" item click: copy that transcript back to the clipboard.
    /// Copy-only BY DESIGN (locked decision) — never synthesize a paste; the
    /// HUD tells the user to ⌘V wherever their cursor is.
    func copyTranscript(_ entry: TranscriptLog.Entry) {
        copyToClipboard(entry.text, notice: "Copied — press ⌘V to paste")
    }

    /// Menu "Report a Wrong Result": show the preview for one Recent entry.
    /// The browser opens only from the preview's button (ResultReportDraft).
    func reportTranscript(_ entry: TranscriptLog.Entry) {
        let info = Bundle.main.infoDictionary
        let report = ResultReport.mac(
            entry: entry,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        resultReport.show(ResultReportDraft(report: report, open: { NSWorkspace.shared.open($0) }))
    }

    /// Shared clipboard+HUD glue for the menu's copy actions — one place to
    /// change if OLIV ever marks its pasteboard writes (e.g. transient types
    /// for clipboard managers).
    private func copyToClipboard(_ text: String, notice: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        controller.hud?.notice(notice, systemImage: "doc.on.clipboard")
    }

    /// Menu "Copy Diagnostics": put the support report on the clipboard. Glue
    /// only — the report body is the pure Diagnostics.report; this assembles
    /// live values (after a refresh, so grants/models are current) and confirms
    /// via the HUD. Note groqCloudEnabled is passed as a boolean; the key never
    /// reaches the builder.
    func copyDiagnostics() {
        refreshReadiness()
        // The report must cover the SELECTED engine's weights repo too:
        // models.repos only tracks RequiredModels, so a report for a failing
        // Pathumma/large-v3 selection would otherwise list two healthy repos
        // and omit the one whose absence explains the failure.
        var repoInfos = models.repos
        if let repo = OLIVSettings.Engine.all.first(where: { $0.id == settings.engineID })?.repo,
           !repoInfos.contains(where: { $0.repo == repo }) {
            let (present, bytes) = ModelState.diskInfo(repo)
            repoInfos.append(RepoInfo(repo: repo, present: present, bytes: bytes))
        }
        let info = Bundle.main.infoDictionary
        let report = Diagnostics.report(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            engineID: effectiveEngineID,
            // The RESOLVED keys — a malformed stored id falls back to the
            // default, and the report must name what the tap actually
            // listens on, not what defaults happens to hold.
            hotkeyID: settings.activeChords.map(\.displayName).joined(separator: " | "),
            cleanupEnabled: settings.cleanupEnabled,
            removeFillers: settings.removeFillers,
            formatCommands: settings.formatCommands && !settings.usesOLIVAPI,
            thaiFormat: settings.thaiFormat,
            echoCancellation: settings.echoCancellation,
            duckOtherAudio: settings.duckOtherAudio,
            // EFFECTIVE state (toggle AND key present) — the toggle alone
            // can't reach the cloud, and "on" without a key would send a
            // privacy triage down the wrong path. Still boolean-only; the
            // key itself never reaches the builder.
            cloudFallbackEnabled: settings.groqKeyForSidecar != nil,
            microphone: permissions.microphone,
            inputMonitoring: permissions.inputMonitoring,
            accessibility: permissions.accessibility,
            models: repoInfos,
            storagePath: models.storagePath,
            lastDictation: appState.lastDictation,
            olivAPIEnabled: settings.olivAPIConfiguration != nil)
        copyToClipboard(report, notice: "Diagnostics copied")
    }

    /// Show (or bring forward) the onboarding window. Wired to the menu's
    /// "Setup…" and auto-invoked at launch when `needsAttention`.
    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                permissions: permissions,
                models: models,
                settings: settings,
                trial: trial,
                onStartTrial: { [weak self] in self?.startCloudTrial() },
                onStopTrial: { [weak self] in self?.stopCloudTrial() },
                onClose: { [weak self] in self?.refreshReadiness() })
        }
        onboarding?.show()
    }
}

/// A plain NSWindow hosting the SwiftUI OnboardingView, shown/activated
/// programmatically (an LSUIElement app has no window to route through
/// otherwise). Closing it — via the Done button or the red button — refreshes
/// readiness so the badge updates.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let permissions: PermissionsModel
    private let models: ModelState
    private let settings: OLIVSettings
    private let trial: CloudTrial
    private let onStartTrial: () -> Void
    private let onStopTrial: () -> Void
    private let onClose: () -> Void

    init(permissions: PermissionsModel, models: ModelState, settings: OLIVSettings, trial: CloudTrial,
         onStartTrial: @escaping () -> Void, onStopTrial: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.permissions = permissions
        self.models = models
        self.settings = settings
        self.trial = trial
        self.onStartTrial = onStartTrial
        self.onStopTrial = onStopTrial
        self.onClose = onClose
        super.init()
    }

    func show() {
        if window == nil {
            let root = OnboardingView(
                permissions: permissions,
                models: models,
                settings: settings,
                trial: trial,
                onDone: { [weak self] in self?.window?.close() },
                onStartTrial: onStartTrial,
                onStopTrial: onStopTrial)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "OLIV Setup"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.center()
            win.delegate = self
            window = win
        }
        // Accessory (menu-bar) apps must activate to bring a window forward.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Release the window (and its NSHostingController): a retained hosting
        // view keeps OnboardingView alive, and its 1 s permission/model poll
        // would keep firing forever behind a closed window. show() rebuilds.
        window = nil
        onClose()
    }
}
