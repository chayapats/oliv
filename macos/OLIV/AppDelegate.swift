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
import SwiftUI
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    let settings = OLIVSettings.shared
    let permissions = PermissionsModel()
    let models = ModelState()
    let controller: DictationController

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

    override init() {
        let state = appState
        let ctrl = DictationController(appState: state)
        // W3-T3/T4: delegate STT + cleanup to the Python sidecar (bundled runtime
        // if the .app ships one, else the dev venv). Cheap to construct; the
        // child spawns lazily on the first warm/dictate.
        ctrl.sidecar = SidecarClient()
        // W4-T2: the floating recording HUD. Constructed here (real-app path
        // only — the e2e harness never builds AppDelegate); the NSPanel itself is
        // created lazily on first show, so nothing appears until a recording.
        ctrl.hud = RecordingHUDController()
        controller = ctrl
        super.init()

        // Seed the controller from persisted settings — WITHOUT touching the tap
        // (start() installs it after launch on the resolved key).
        controller.hotkeyKey = settings.hotkeyKey
        controller.sttEngine = settings.engineID
        controller.cleanupEnabled = settings.cleanupEnabled
        controller.verbatimApps = settings.verbatimApps
        controller.removeFillers = settings.removeFillers
        controller.replacements = settings.replacements
        controller.vocabulary = settings.vocabulary
        controller.formatCommands = settings.formatCommands
        controller.showHUD = settings.showRecordingIndicator
        controller.micDevice = settings.micDevice
        controller.historyEnabled = settings.historyEnabled
        // Opt-in cloud fallback: inject GROQ_API_KEY into the sidecar's spawn env
        // only when the toggle is on and a key is set (nil = local-only).
        ctrl.sidecar?.setGroqAPIKey(settings.groqKeyForSidecar)

        // Live-apply: any settings change re-pushes into the running controller.
        settings.onChange = { [weak self] in self?.applyLiveSettings() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()          // install the tap + kick off the non-blocking warm
        refreshReadiness()
        if needsAttention { showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        models.close()
    }

    /// Push live settings into the running controller. Engine / cleanup /
    /// verbatim take effect on the NEXT utterance (read at release); a hotkey
    /// change restarts the tap immediately.
    private func applyLiveSettings() {
        controller.sttEngine = settings.engineID
        controller.cleanupEnabled = settings.cleanupEnabled
        controller.verbatimApps = settings.verbatimApps
        controller.removeFillers = settings.removeFillers
        controller.replacements = settings.replacements
        controller.vocabulary = settings.vocabulary
        controller.formatCommands = settings.formatCommands
        controller.showHUD = settings.showRecordingIndicator
        if !settings.showRecordingIndicator { controller.hud?.hide() }
        controller.micDevice = settings.micDevice
        controller.historyEnabled = settings.historyEnabled
        // Toggle OFF clears what's already retained immediately (the user just
        // said "stop keeping these"). Idempotent, so re-running on every
        // settings change is harmless.
        if !settings.historyEnabled { appState.clearTranscripts() }
        controller.applyHotkey(settings.hotkeyKey)
        // A Groq key/toggle change respawns the sidecar (self-heal) so the new
        // spawn env takes effect on the next dictate; a no-op when unchanged.
        controller.sidecar?.setGroqAPIKey(settings.groqKeyForSidecar)
        refreshReadiness()
    }

    /// Re-scan permissions + models, retry the hotkey tap (in case Input
    /// Monitoring was just granted), and update the badge.
    func refreshReadiness() {
        permissions.refresh()
        models.recheck()
        controller.start()   // idempotent; a no-op if the tap is already live
        needsAttention = !(permissions.allGranted && models.allPresent)
    }

    /// Menu "Recent…" item click: copy that transcript back to the clipboard.
    /// Copy-only BY DESIGN (locked decision) — never synthesize a paste; the
    /// HUD tells the user to ⌘V wherever their cursor is.
    func copyTranscript(_ entry: TranscriptLog.Entry) {
        copyToClipboard(entry.text, notice: "Copied — press ⌘V to paste")
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
            engineID: settings.engineID,
            // The RESOLVED key — a malformed stored id falls back to the
            // default, and the report must name what the tap actually
            // listens on, not what defaults happens to hold.
            hotkeyID: settings.hotkeyKey.id,
            cleanupEnabled: settings.cleanupEnabled,
            removeFillers: settings.removeFillers,
            formatCommands: settings.formatCommands,
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
            lastDictation: appState.lastDictation)
        copyToClipboard(report, notice: "Diagnostics copied")
    }

    /// Show (or bring forward) the onboarding window. Wired to the menu's
    /// "Setup…" and auto-invoked at launch when `needsAttention`.
    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                permissions: permissions,
                models: models,
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
    private let onClose: () -> Void

    init(permissions: PermissionsModel, models: ModelState, onClose: @escaping () -> Void) {
        self.permissions = permissions
        self.models = models
        self.onClose = onClose
        super.init()
    }

    func show() {
        if window == nil {
            let root = OnboardingView(
                permissions: permissions,
                models: models,
                onDone: { [weak self] in self?.window?.close() })
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
