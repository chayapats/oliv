import AVFoundation
import Foundation
import CryptoKit
import Observation
import OlivCore
import UIKit

protocol OlivServing: Sendable {
    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply
    func clean(text: String, options: OlivOptions) async throws -> DictationReply
    func health() async throws -> ServerHealth
    func verifyKey() async throws
    func dictionary(ops: [DictionaryOp]?) async throws -> DictionarySnapshot
}
extension OlivClient: OlivServing {}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel.makeDefault()

    var phase: CapturePhase = .idle {
        didSet {
            guard !isBusy, oldValue != phase else { return }
            // A capture running when the app came on screen delayed this.
            if Self.busyPhases.contains(oldValue), !isInBackground() { clearCompletion() }
            scheduleProcessRelease()
        }
    }
    var settings = AppSettings()
    var tokenInput = ""
    var cleanupDraft = ""
    var history: [HistoryEntry] = []
    var pending: [PendingRecording] = []
    var latest: HistoryEntry?
    var elapsed: TimeInterval = 0
    var level: Double = 0
    var message: String?
    var connectionMessage: String?
    var isCheckingConnection = false
    var isStartingTrial = false
    /// Stays set after connecting so setup can finish its remaining steps.
    var isInSetup = false
    var trialMessage: String?
    /// Stored, because iOS doesn't tell SwiftUI when this permission changes.
    private(set) var microphoneDenied = false
    var hasToken = false
    var selectedTab = 0
    var isDemo = false
    /// The personal Dictionary, synced with the server and other devices.
    private(set) var dictionary = DictionaryBook()
    private(set) var dictionarySyncStatus: DictionarySyncStatus = .localOnly
    /// Words the server refused on the last sync (duplicate or full).
    private(set) var dictionaryRejectedWords: [String] = []

    var isConfigured: Bool {
        guard hasToken, settings.requiresNewAPIKey != true, savedCredentialBinding != nil,
              settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) == savedServerURL,
              let url = URL(string: savedServerURL) else { return false }
        // UI redraws must not read Keychain on every audio-meter tick.
        return (try? OlivConfiguration(baseURL: url, token: "configured", allowsInsecureHTTP: settings.allowsInsecureHTTP)) != nil
    }
    /// Free trials come from the server this build ships with. A source build
    /// without one has nothing to ask.
    var trialServerURL = AppSettings.defaultServerURL
    var offersTrial: Bool { !trialServerURL.isEmpty }
    var trialHasEnded: Bool { settings.trialExpiresAt.map { $0 <= Date() } ?? false }
    private static let busyPhases: Set<CapturePhase> = [.preparing, .recording, .processing]
    var isBusy: Bool { Self.busyPhases.contains(phase) }
    var isRecording: Bool { phase == .recording }
    var formattedElapsed: String {
        let seconds = Int(max(0, elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    /// Only the most recently completed operation can become a Shortcut output.
    var latestTextForIntent: String? {
        phase == .result && latest?.reply.hasText == true ? latest?.finalText : nil
    }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let clientFactory: (OlivConfiguration) -> any OlivServing
    @ObservationIgnored private let liveActivitiesEnabled: Bool
    @ObservationIgnored private let liveActivity: any LiveActivityControlling
    @ObservationIgnored private let keyboardDelivery: (any KeyboardDelivering)?
    @ObservationIgnored private var keyboardTarget: KeyboardCaptureTarget?
    @ObservationIgnored private var keyboardCaptureRequested = false
    @ObservationIgnored private let requestTrialKey: (URL) async throws -> TrialKey
    @ObservationIgnored private let isInBackground: @MainActor () -> Bool
    private enum IntentStartStage { case setup, liveActivity, microphone }
    @ObservationIgnored private var intentStartStage: IntentStartStage = .setup
    @ObservationIgnored private var savedServerURL = ""
    @ObservationIgnored private var savedCredentialBinding: String?
    @ObservationIgnored private var dictionaryStore: DictionaryBookStore?
    @ObservationIgnored private var dictionarySyncTask: Task<Void, Never>?
    /// The exchange in progress; later callers wait for it instead of racing.
    @ObservationIgnored private var dictionarySyncRun: Task<Void, Never>?
    @ObservationIgnored private var dictionarySyncAgain = false
    @ObservationIgnored private var historyStore: HistoryStore?
    @ObservationIgnored private var pendingStore: PendingRecordingStore?
    @ObservationIgnored private var retryCooldown: RetryCooldownStore?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var activeOptions = OlivOptions()
    @ObservationIgnored private var activeRecordID: UUID?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var speechEndpoint: SpeechEndpointPolicy?
    @ObservationIgnored private let releaseProcess: (() -> Void)?
    @ObservationIgnored private var capturedInBackground = false
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivityCalls = 0
    private static let completionLifetime: TimeInterval = 86_400
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var persistedSettings = AppSettings()
    @ObservationIgnored private var connectionGeneration = 0

    init(directory: URL? = nil,
         credentials: any CredentialStoring = KeychainCredentialStore(),
         capture: (any AudioCapturing)? = nil,
         liveActivitiesEnabled: Bool = true,
         liveActivity: (any LiveActivityControlling)? = nil,
         keyboardDelivery: (any KeyboardDelivering)? = nil,
         clientFactory: @escaping (OlivConfiguration) -> any OlivServing = { OlivClient(configuration: $0) },
         requestTrialKey: @escaping (URL) async throws -> TrialKey = { try await TrialClient.requestKey(baseURL: $0) },
         isInBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background },
         releaseProcess: (() -> Void)? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OLIV", isDirectory: true)
        self.credentials = credentials
        self.capture = capture ?? AudioCaptureService(directory: self.directory)
        self.clientFactory = clientFactory
        self.requestTrialKey = requestTrialKey
        self.isInBackground = isInBackground
        self.releaseProcess = releaseProcess
        self.liveActivitiesEnabled = liveActivitiesEnabled
        self.liveActivity = liveActivity ?? LiveActivityManager.shared
        self.keyboardDelivery = keyboardDelivery
        var installedBefore = false
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var folder = self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let settingsURL = self.directory.appendingPathComponent("settings.json")
            installedBefore = FileManager.default.fileExists(atPath: settingsURL.path)
            // Read before any settings migration rewrites the file.
            var legacyDictionary: LegacyDictionarySettings?
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                do {
                    let data = try Data(contentsOf: settingsURL)
                    settings = try JSONDecoder().decode(AppSettings.self, from: data)
                    legacyDictionary = try? JSONDecoder().decode(LegacyDictionarySettings.self, from: data)
                    if settings.requiresNewAPIKey == true {
                        message = String(localized: "OLIV now uses a public HTTPS API. Enter your new individual API key in Settings; your writing preferences and recordings were kept.")
                    }
                    savedServerURL = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    savedCredentialBinding = settings.credentialBinding
                }
                catch { message = String(localized: "Saved settings could not be read. Reconnect in Settings; your history and recordings were preserved.") }
            }
            do {
                if settings.requiresNewAPIKey == true { hasToken = false }
                else { hasToken = !(try credentials.read() ?? "").isEmpty }
            }
            catch { message = safeDescription(error) }
            // Its own failure: a damaged Dictionary must not stop recording.
            do { try loadDictionary(legacy: legacyDictionary) }
            catch { message = String(localized: "Your Dictionary could not be read, so OLIV kept the file and isn't changing it. Dictation still works.") }
            historyStore = try HistoryStore(directory: self.directory)
            pendingStore = try PendingRecordingStore(directory: self.directory.appendingPathComponent("Pending"))
            retryCooldown = try RetryCooldownStore(directory: self.directory)
            do { try recoverInterruptedRecording() }
            catch {
                // Preserve invalid partial files for inspection without hiding good history
                // or permanently blocking the next recording.
                let recovered = self.directory.appendingPathComponent("Interrupted", isDirectory: true)
                try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
                let name = UUID().uuidString
                if FileManager.default.fileExists(atPath: self.capture.recoveryURL.path) {
                    try FileManager.default.moveItem(at: self.capture.recoveryURL,
                        to: recovered.appendingPathComponent(name + ".wav"))
                }
                if FileManager.default.fileExists(atPath: optionsRecoveryURL.path) {
                    try FileManager.default.moveItem(at: optionsRecoveryURL,
                        to: recovered.appendingPathComponent(name + "-options.json"))
                }
                message = String(localized: "An interrupted recording was incomplete and could not be retried. Its partial file was preserved. You can record again.")
            }
            try refreshStores()
        } catch {
            message = String(localized: "Saved data could not be loaded. Existing files were preserved. \(safeDescription(error))")
        }
        self.capture.onInterruption = { [weak self] in
            Task { @MainActor [weak self] in await self?.stopFromIntent() }
        }
        // Decided once: editing the address in Settings must never reopen setup.
        // An explicit false is a trial that started here and hasn't finished yet;
        // nil with saved settings is an install from before setup existed, even
        // one that must reconnect first.
        isInSetup = settings.finishedSetup == false || (settings.finishedSetup == nil && !installedBefore)
        persistedSettings = settings
        restoreCompletion()
        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.isBusy { self.capturedInBackground = true }
                    self.scheduleProcessRelease()
                }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Only now has the person had the chance to see it.
                MainActor.assumeIsolated {
                    if self?.isBusy == false { self?.clearCompletion() }
                }
            }
        ]
        if isConfigured { scheduleDictionarySync(after: 0) }
    }

    /// Options for a new request (see `AppSettings.options(dictionary:)`).
    var currentOptions: OlivOptions { settings.options(dictionary: dictionary) }

    private static func makeDefault() -> AppModel {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") || arguments.contains("--demo")
            || arguments.contains("--keyboard-test-host") || arguments.contains("--keyboard-integration-demo") {
            return PreviewEnvironment.makeModel()
        }
        #endif
        return AppModel(keyboardDelivery: KeyboardDeliveryCoordinator.makeDefault(), releaseProcess: { exit(0) })
    }

    private func configuration() throws -> OlivConfiguration {
        guard settings.requiresNewAPIKey != true else {
            throw OlivError.invalidConfiguration(String(localized: "The old shared token is retired. Enter a new individual API key in Settings and save it."))
        }
        guard let url = URL(string: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let token = try credentials.read(), !token.isEmpty else { throw AppCaptureError.setupRequired }
        guard settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) == savedServerURL else {
            throw OlivError.invalidConfiguration(String(localized: "Save the server address in Settings before connecting or recording."))
        }
        guard savedCredentialBinding == Self.credentialBinding(token: token, serverURL: savedServerURL) else {
            throw OlivError.invalidConfiguration(String(localized: "Save your server settings again to pair this address with its access token."))
        }
        return try OlivConfiguration(baseURL: url, token: token, allowsInsecureHTTP: settings.allowsInsecureHTTP)
    }

    func saveSettings() {
        guard !isBusy else { message = String(localized: "Finish this dictation before changing settings."); return }
        do {
            try currentOptions.validate()
            try currentOptions.validateServerLimits()
            let entered = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if settings.requiresNewAPIKey == true && entered.isEmpty {
                throw OlivError.invalidConfiguration(String(localized: "Enter your new individual API key. The retired shared token cannot be reused."))
            }
            let token = entered.isEmpty ? (try credentials.read() ?? "") : entered
            // A trial key belongs to the server that issued it. Only a key
            // someone chose for the new address may go there.
            if entered.isEmpty, let issuer = settings.trialIssuer,
               settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) != issuer {
                throw OlivError.invalidConfiguration(String(localized: "Enter an API key for this server. Your trial key works only with the server that issued it."))
            }
            guard let url = URL(string: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AppCaptureError.setupRequired
            }
            _ = try OlivConfiguration(baseURL: url, token: token, allowsInsecureHTTP: settings.allowsInsecureHTTP)
            var approved = settings
            approved.requiresNewAPIKey = false
            if !entered.isEmpty {
                approved.trialExpiresAt = nil
                approved.trialIssuerURL = nil
            }
            approved.credentialBinding = Self.credentialBinding(token: token,
                serverURL: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
            let data = try JSONEncoder().encode(approved)
            if !entered.isEmpty { try credentials.write(entered) }
            try data.write(to: directory.appendingPathComponent("settings.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let previousBinding = savedCredentialBinding
            savedServerURL = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            savedCredentialBinding = approved.credentialBinding
            settings = approved
            persistedSettings = approved
            connectionChanged(from: previousBinding)
            tokenInput = ""
            hasToken = true
            connectionMessage = String(localized: "Settings saved.")
            message = nil
            scheduleDictionarySync(after: 0)
        } catch { message = safeDescription(error) }
    }

    /// One tap from nothing to a working connection: the key goes straight into
    /// Keychain, so nobody copies, pastes or sees it.
    func startTrial() async {
        guard !isBusy, !isStartingTrial, let url = URL(string: trialServerURL) else { return }
        isStartingTrial = true
        trialMessage = nil
        defer {
            isStartingTrial = false
            scheduleProcessRelease()
        }
        let generation = connectionGeneration
        let address = settings.serverURL
        do {
            let key = try await requestTrialKey(url)
            guard !isBusy else { throw OlivError.invalidConfiguration(String(localized: "Finish this dictation before changing settings.")) }
            // Someone who connected another way while this waited keeps that.
            guard generation == connectionGeneration, address == settings.serverURL else { return }
            try commitTrial(key)
            connectionMessage = nil
        } catch TrialRefusal.closed {
            showTrialFailure(String(localized: "The free trial is closed right now. Try again later."))
        } catch TrialRefusal.limitReached {
            showTrialFailure(String(localized: "Today's free trials are taken. Try again tomorrow."))
        } catch {
            showTrialFailure(safeDescription(error))
        }
    }

    private func showTrialFailure(_ text: String) {
        trialMessage = text
        // Setup shows this itself; a renewal from the banner has only the message.
        if !isInSetup { message = text }
    }

    private func commitTrial(_ key: TrialKey) throws {
        var approved = settings
        approved.serverURL = trialServerURL
        approved.allowsInsecureHTTP = false
        approved.requiresNewAPIKey = false
        approved.trialExpiresAt = key.expiresAt
        approved.trialIssuerURL = trialServerURL
        if isInSetup { approved.finishedSetup = false }
        approved.credentialBinding = Self.credentialBinding(token: key.token, serverURL: trialServerURL)
        let data = try JSONEncoder().encode(approved)
        // Settings first, because they name the key's issuer: a key must never
        // sit in Keychain without it, and release builds can't delete one.
        let settingsURL = directory.appendingPathComponent("settings.json")
        let previousSettings = try? Data(contentsOf: settingsURL)
        try data.write(to: settingsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try credentials.write(key.token)
        } catch {
            if let previousSettings {
                try? previousSettings.write(to: settingsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                try? FileManager.default.removeItem(at: settingsURL)
            }
            throw error
        }
        settings = approved
        persistedSettings = approved
        let previousBinding = savedCredentialBinding
        savedServerURL = trialServerURL
        savedCredentialBinding = approved.credentialBinding
        connectionChanged(from: previousBinding)
        hasToken = true
        message = nil
    }

    var microphoneAllowed: Bool { capture.hasPermission }
    func refreshMicrophonePermission() { microphoneDenied = capture.permissionDenied }
    func requestMicrophone() async -> Bool {
        let granted = await capture.requestPermission()
        refreshMicrophonePermission()
        return granted
    }
    func keyboardIsConnected() async -> Bool { await keyboardDelivery?.isConnected() ?? false }

    func finishSetup() {
        isInSetup = false
        settings.finishedSetup = true
        persistSettings()
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        do {
            try data.write(to: directory.appendingPathComponent("settings.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            persistedSettings = settings
        } catch {}
    }

    func checkConnection() async {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        do {
            guard let url = URL(string: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw OlivError.invalidConfiguration(String(localized: "Enter a valid OLIV server URL."))
            }
            // Liveness is public and must not disclose a saved key to an unsaved address.
            let client = clientFactory(try OlivConfiguration(baseURL: url, token: "liveness-only",
                allowsInsecureHTTP: settings.allowsInsecureHTTP))
            let health = try await client.health()
            guard health.ok else {
                connectionMessage = String(localized: "The server answered but isn't ready. Try again in a moment.")
                return
            }
            guard isConfigured else {
                connectionMessage = String(localized: "Server found. Save your settings to check your API key.")
                return
            }
            do {
                try await clientFactory(try configuration()).verifyKey()
                connectionMessage = String(localized: "Connected. Your API key works.")
            } catch OlivError.forbidden(reason: .missingScope) {
                // The server knew the key, so only this permission is missing.
                connectionMessage = String(localized: "Connected, but this API key can't dictate. Ask the administrator to add the dictate scope.")
            }
        } catch { connectionMessage = safeDescription(error) }
    }

    func toggleRecording() async {
        if isRecording { await stopFromIntent() }
        else if !isBusy { await startInForeground() }
    }

    func startInForeground() async {
        guard !isBusy else { return }
        clearKeyboardDelivery()
        let id = UUID()
        operationID = id
        do { try await beginRecording(fromIntent: false, startID: id, allowKeyboardDelivery: false) }
        catch {
            guard operationID == id else { return }
            phase = .failed
            message = safeDescription(error)
            if !isConfigured { selectedTab = 2 }
        }
    }

    func startFromIntent(allowKeyboardDelivery: Bool = true) async throws {
        guard !isBusy else { return }
        clearKeyboardDelivery()
        keyboardCaptureRequested = allowKeyboardDelivery
        let id = UUID()
        operationID = id
        try await beginRecording(fromIntent: true, startID: id, allowKeyboardDelivery: allowKeyboardDelivery)
    }

    /// Fixed, actionable guidance; raw system diagnostics remain numeric and local.
    func intentStartFailure(_ error: any Error) -> String {
        CaptureDiagnostics.record(event: .startFailed, error: error, detail: diagnosticAppState)
        if let known = error as? LiveActivityManager.StartError { return known.localizedDescription }
        switch intentStartStage {
        case .setup: return safeDescription(error)
        case .liveActivity:
            return String(localized: "iOS could not start OLIV’s Live Activity. Check iPhone Settings → Apps → OLIV → Live Activities, then try Toggle OLIV again.")
        case .microphone:
            return String(localized: "iOS could not start the microphone. Recording did not begin. If a call or another recording is active, finish it before trying Toggle OLIV again.")
        }
    }

    private var diagnosticAppState: CaptureDiagnostics.Detail {
        switch UIApplication.shared.applicationState {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }

    /// iOS lets a process it launched in the background start audio once. Every
    /// later start fails with 561015905 (`!pla`) until that process is gone, and
    /// waiting doesn't help, while a fresh launch always succeeds. So a process
    /// that started audio in the background ends itself once it is idle there,
    /// and the next press gets a new one. Nothing visible changes: the app isn't
    /// on screen, the outcome is saved for `restoreCompletion`, and iOS relaunches
    /// the app for the next intent.
    private func scheduleProcessRelease() {
        guard capturedInBackground, let releaseProcess else { return }
        releaseTask?.cancel()
        // Lets the intent return its result before the process goes.
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.canReleaseProcess else { return }
            do { try self.saveCompletion() } catch { return }
            releaseProcess()
        }
    }

    private var canReleaseProcess: Bool {
        !isBusy && !isStartingTrial && liveActivityCalls == 0 && isInBackground()
            && cleanupDraft.isEmpty && tokenInput.isEmpty && settings == persistedSettings
    }

    /// `entry` is set only for a result history doesn't hold (history off, or
    /// dropped by its limit), which would otherwise end with this process.
    private struct Completion: Codable {
        let entryID: UUID?
        let entry: HistoryEntry?
        let message: String?
        let savedAt: Date
    }
    private var completionURL: URL { directory.appendingPathComponent("last-completion.json") }

    private func saveCompletion() throws {
        let unsaved = latest.flatMap { entry in history.contains { $0.id == entry.id } ? nil : entry }
        // Passing through a background launch doesn't restart its day.
        let earlier = (try? Data(contentsOf: completionURL)).flatMap { try? JSONDecoder().decode(Completion.self, from: $0) }
        let savedAt = earlier.flatMap { $0.entryID == latest?.id && latest != nil ? $0.savedAt : nil } ?? Date()
        let completion = Completion(entryID: latest?.id, entry: unsaved, message: message, savedAt: savedAt)
        guard completion.entryID != nil || completion.message != nil else { return }
        try JSONEncoder().encode(completion).write(to: completionURL, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func clearCompletion() { try? FileManager.default.removeItem(at: completionURL) }

    /// Shows what a released process left behind. A background launch can read
    /// it too, so the file stays until the app is actually on screen.
    private func restoreCompletion() {
        guard let data = try? Data(contentsOf: completionURL),
              let completion = try? JSONDecoder().decode(Completion.self, from: data) else { return }
        // Someone who never came back shouldn't find it, or keep it, any longer.
        guard Date().timeIntervalSince(completion.savedAt) < Self.completionLifetime else {
            clearCompletion()
            return
        }
        if let entry = completion.entry ?? completion.entryID.flatMap({ id in history.first { $0.id == id } }) {
            latest = entry
            phase = .result
        }
        if message == nil { message = completion.message }
    }

    /// `await` on ActivityKit has no time limit, and cancelling a capture doesn't
    /// stop a call already running, so the release waits for each of them rather
    /// than for a fixed delay.
    private func trackLiveActivity<T>(_ call: () async throws -> T) async rethrows -> T {
        liveActivityCalls += 1
        defer {
            liveActivityCalls -= 1
            scheduleProcessRelease()
        }
        return try await call()
    }

    private func beginRecording(fromIntent: Bool, startID: UUID, allowKeyboardDelivery: Bool) async throws {
        releaseTask?.cancel()
        if fromIntent, isInBackground() { capturedInBackground = true }
        intentStartStage = .setup
        if fromIntent { CaptureDiagnostics.record(event: .startRequested, detail: diagnosticAppState) }
        do {
            _ = try configuration()
            try currentOptions.validate()
            try currentOptions.validateServerLimits()
        } catch {
            if fromIntent { CaptureDiagnostics.record(event: .setupRejected, error: error) }
            throw error
        }
        guard pendingStore != nil else { throw OlivError.corruptedStore }
        phase = .preparing
        message = nil
        latest = nil
        elapsed = 0
        level = 0
        if fromIntent {
            guard capture.hasPermission else {
                CaptureDiagnostics.record(event: .microphonePermissionMissing)
                phase = .idle
                throw AppCaptureError.needsForeground
            }
        } else {
            let granted = await capture.requestPermission()
            guard operationID == startID, phase == .preparing else { return }
            guard granted else { phase = .idle; throw AppCaptureError.microphoneDenied }
        }
        // Cancellation can occur while a permission dialog is open.
        guard operationID == startID, phase == .preparing else { return }
        do {
            if fromIntent && allowKeyboardDelivery, let keyboardDelivery {
                let focus = await keyboardDelivery.snapshotFocus()
                try Task.checkCancellation()
                guard operationID == startID, phase == .preparing else { return }
                if let focus {
                    keyboardTarget = KeyboardCaptureTarget(recordingID: startID, focus: focus)
                }
            } else if fromIntent && allowKeyboardDelivery {
                CaptureDiagnostics.record(event: .bridgeUnavailable)
            }
            if liveActivitiesEnabled {
                intentStartStage = .liveActivity
                if fromIntent { CaptureDiagnostics.record(event: .liveActivityStarting) }
                do {
                    try await trackLiveActivity { try await liveActivity.start() }
                    if fromIntent { CaptureDiagnostics.record(event: .liveActivityStarted) }
                }
                catch { if fromIntent { throw error } }
            }
            try Task.checkCancellation()
            guard operationID == startID else { return }
            intentStartStage = .setup
            activeOptions = currentOptions
            try JSONEncoder().encode(activeOptions).write(to: optionsRecoveryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            intentStartStage = .microphone
            if fromIntent { CaptureDiagnostics.record(event: .microphoneStarting, detail: diagnosticAppState) }
            let automaticFinish = fromIntent ? settings.automaticActionButtonFinish : settings.stopAfterSilence
            try await capture.start(detectSpeech: automaticFinish)
            if fromIntent { CaptureDiagnostics.record(event: .microphoneStarted, detail: diagnosticAppState) }
            phase = .recording
            speechEndpoint = automaticFinish ? SpeechEndpointPolicy() : nil
            meterTask = Task { @MainActor [weak self] in
                let started = ContinuousClock.now
                var lastProgress = started
                var previousDuration: TimeInterval = 0
                while !Task.isCancelled {
                    guard let self, self.phase == .recording, self.operationID == startID else { break }
                    let reading = self.capture.meter()
                    self.elapsed = reading.duration
                    self.level = reading.level
                    let now = ContinuousClock.now
                    if reading.duration.isFinite, reading.duration > previousDuration {
                        previousDuration = reading.duration
                        lastProgress = now
                    }
                    let decision: SpeechEndpointPolicy.Decision?
                    if started.duration(to: now) >= .seconds(AudioCaptureService.maximumDuration) {
                        decision = self.speechEndpoint?.hasDetectedSpeech == false
                            ? .cancel(.maximumDurationWithoutSpeech) : .finish(.maximumDuration)
                    } else if automaticFinish,
                              !reading.duration.isFinite || reading.duration < 0 || lastProgress.duration(to: now) >= .seconds(3) {
                        // A stalled input freezes sample time. This active-capture
                        // watchdog releases the microphone even with no new PCM.
                        decision = .cancel(.detectorUnavailable)
                    } else {
                        decision = self.captureCompletionDecision(elapsed: reading.duration)
                    }
                    if let decision {
                        // Do not await a task from itself when stop cancels the meter.
                        Task { @MainActor [weak self] in
                            guard let self, self.operationID == startID, self.phase == .recording else { return }
                            await self.completeAutomaticCapture(decision)
                        }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            if operationID == startID {
                speechEndpoint = nil
                clearKeyboardDelivery()
                phase = .idle
                if liveActivitiesEnabled { await trackLiveActivity { await liveActivity.cancel() } }
            }
            throw error
        }
    }

    private func captureCompletionDecision(elapsed: TimeInterval) -> SpeechEndpointPolicy.Decision? {
        guard var endpoint = speechEndpoint else {
            return elapsed >= AudioCaptureService.maximumDuration ? .finish(.maximumDuration) : nil
        }
        if capture.analysisFailed { return .cancel(.detectorUnavailable) }
        for observation in capture.takeSpeechObservations() {
            endpoint.observe(windowStart: observation.startTime, windowEnd: observation.endTime,
                             isSpeech: observation.isSpeech)
        }
        let decision = endpoint.evaluate(elapsed: elapsed)
        speechEndpoint = endpoint
        return decision
    }

    private func completeAutomaticCapture(_ decision: SpeechEndpointPolicy.Decision) async {
        guard phase == .recording else { return }
        // Analysis can fail after the meter read, including while its final
        // observations are drained. A no-speech decision must recheck too.
        if speechEndpoint != nil, capture.analysisFailed {
            await preserveAutomaticCaptureFailure()
            return
        }
        switch decision {
        case .finish:
            CaptureDiagnostics.record(event: .automaticFinish)
            await stopFromIntent(requireHealthyAnalysis: speechEndpoint != nil)
        case .cancel(.initialSilence), .cancel(.maximumDurationWithoutSpeech):
            // Stop and drain before deleting anything. The classifier's final
            // callback can fail during stop even after a healthy preflight.
            let stoppedAudio = Result { try capture.stop() }
            CaptureDiagnostics.record(event: .microphoneStopped)
            if capture.analysisFailed {
                await preserveAutomaticCaptureFailure(stoppedAudio: stoppedAudio)
                return
            }
            do {
                _ = try stoppedAudio.get()
                try capture.removeRecoveredAudio()
            } catch {
                await preserveAutomaticCaptureFailure(stoppedAudio: stoppedAudio)
                return
            }
            try? FileManager.default.removeItem(at: optionsRecoveryURL)
            // The microphone is already stopped and its validated silence was
            // removed. cancel now clears state without stopping/discarding twice.
            phase = .processing
            CaptureDiagnostics.record(event: .noSpeechCancelled)
            await cancel()
            if phase == .idle, operationID == nil {
                message = String(localized: "No speech was detected. The microphone is off; nothing was sent.")
            }
        case .cancel(.detectorUnavailable):
            await preserveAutomaticCaptureFailure()
        }
    }

    /// Classifier stalls or audio-pipeline errors must never look like the user
    /// finished speaking. Preserve recoverable audio without uploading/inserting it.
    private func preserveAutomaticCaptureFailure(stoppedAudio: Result<Data, any Error>? = nil) async {
        guard phase == .recording else { return }
        let captureID = operationID
        phase = .processing
        speechEndpoint = nil
        meterTask?.cancel()
        meterTask = nil
        level = 0
        clearKeyboardDelivery()
        CaptureDiagnostics.record(event: .speechAnalysisFailed)
        do {
            let outcome: Result<Data, any Error>
            if let stoppedAudio { outcome = stoppedAudio }
            else {
                outcome = Result { try capture.stop() }
                CaptureDiagnostics.record(event: .microphoneStopped)
            }
            let wav = try outcome.get()
            guard let pendingStore else { throw OlivError.corruptedStore }
            let item = try pendingStore.enqueue(wav: wav, options: activeOptions)
            try pendingStore.recordAttempt(id: item.id, errorDescription: String(localized: "Automatic finish was unavailable. No request was sent."))
            try refreshStores()
            try capture.removeRecoveredAudio()
            try? FileManager.default.removeItem(at: optionsRecoveryURL)
            message = String(localized: "Automatic finish became unavailable. The microphone is off and your audio is saved for retry. Nothing was inserted.")
        } catch {
            // Keep the recovery file if reading, conversion or persistence failed.
            message = String(localized: "Recording stopped because automatic finish became unavailable. Nothing was inserted. Open OLIV to review the recording.")
        }
        if liveActivitiesEnabled { await trackLiveActivity { await liveActivity.cancel() } }
        guard operationID == captureID else { return }
        phase = .failed
    }

    func stopFromIntent(requireHealthyAnalysis: Bool = false) async {
        guard phase == .recording else { return }
        speechEndpoint = nil
        // Keep only the focus captured for this recording, never the latest visible field.
        let target = keyboardTarget.flatMap { $0.recordingID == operationID ? $0 : nil }
        let expectsKeyboardDelivery = keyboardCaptureRequested
        phase = .processing
        meterTask?.cancel()
        meterTask = nil
        level = 0
        do {
            let wav = try capture.stop()
            CaptureDiagnostics.record(event: .microphoneStopped)
            let metadata = try WAVMetadata(data: wav)
            guard metadata.duration >= 0.25 else {
                capture.discard()
                throw AppCaptureError.tooShort
            }
            guard let pendingStore else { throw OlivError.corruptedStore }
            let item = try pendingStore.enqueue(wav: wav, options: activeOptions)
            // Show the durable queue even if deleting the temporary file fails.
            pending = try pendingStore.recordings()
            try capture.removeRecoveredAudio()
            try? FileManager.default.removeItem(at: optionsRecoveryURL)
            try refreshStores()
            if requireHealthyAnalysis, capture.analysisFailed {
                // A worker can fail while stop drains it. The result is saved,
                // but an unreliable endpoint must never publish partial speech.
                clearKeyboardDelivery()
                try? pendingStore.recordAttempt(id: item.id, errorDescription: String(localized: "Automatic finish was unavailable. No request was sent."))
                CaptureDiagnostics.record(event: .speechAnalysisFailed)
                phase = .failed
                message = String(localized: "Automatic finish became unavailable. The microphone is off and your audio is saved for retry. Nothing was inserted.")
                if liveActivitiesEnabled { await trackLiveActivity { await liveActivity.cancel() } }
                return
            }
            await submit(item, source: .dictation, keyboardTarget: target,
                         expectsKeyboardDelivery: expectsKeyboardDelivery)
        } catch {
            clearKeyboardDelivery()
            phase = .failed
            message = safeDescription(error)
            if liveActivitiesEnabled { await trackLiveActivity { await liveActivity.cancel() } }
        }
    }

    func retry(_ item: PendingRecording) async {
        guard !isBusy else { return }
        clearKeyboardDelivery()
        phase = .processing
        latest = nil
        await submit(item, source: .retry)
    }

    private func submit(_ item: PendingRecording, source: HistorySource,
                        keyboardTarget: KeyboardCaptureTarget? = nil,
                        expectsKeyboardDelivery: Bool = false) async {
        let id = UUID()
        operationID = id
        activeRecordID = item.id
        message = nil
        startBackgroundTask()
        if liveActivitiesEnabled { await trackLiveActivity { await liveActivity.updateProcessing() } }
        guard operationID == id else { return }
        let task = Task { @MainActor [weak self] in
            guard let self, self.operationID == id else { return }
            let start = ContinuousClock.now
            do {
                let client = self.clientFactory(try self.configuration())
                guard let pendingStore = self.pendingStore else { throw OlivError.corruptedStore }
                let wav = try pendingStore.audio(for: item.id)
                guard let retryCooldown = self.retryCooldown else { throw OlivError.corruptedStore }
                try retryCooldown.check()
                let reply = try await client.dictate(wav: wav, options: item.options)
                try Task.checkCancellation()
                self.noteDictionaryRevision(reply.dictionaryRevision)
                guard self.operationID == id else { return }
                let duration = Self.seconds(start.duration(to: .now))
                let entry = HistoryEntry(id: item.id, createdAt: item.createdAt, source: source,
                    audioDuration: item.audioDuration, totalDuration: duration, reply: reply)
                // Result must be durable before removing the only retryable audio.
                if self.settings.keepHistory {
                    guard let historyStore = self.historyStore else { throw OlivError.corruptedStore }
                    try historyStore.append(entry)
                }
                self.latest = entry
                try pendingStore.remove(id: item.id)
                try self.refreshStores()
                CaptureDiagnostics.record(event: .resultReady)
                var deliveryNotice: String?
                if source == .dictation, reply.hasText, let keyboardTarget, let keyboardDelivery = self.keyboardDelivery {
                    // The microphone was released by capture.stop() before any networking.
                    // Only this new result may reach the exact field captured at recording start.
                    let published = await keyboardDelivery.publish(text: entry.finalText, target: keyboardTarget.focus,
                                                                    recordingID: keyboardTarget.recordingID)
                    try Task.checkCancellation()
                    guard self.operationID == id else { return }
                    if !published {
                        deliveryNotice = String(localized: "Your text is ready here. Automatic insertion was unavailable because the original keyboard field could not be confirmed. Copy the result to continue.")
                    }
                } else {
                    self.clearKeyboardDelivery()
                    if expectsKeyboardDelivery && reply.hasText {
                        deliveryNotice = String(localized: "Your text is ready here. OLIV could not connect to the active keyboard. Enable Allow Full Access for OLIV and keep the same field open when using Toggle OLIV.")
                    }
                }
                self.phase = .result
                if self.settings.autoCopy && reply.hasText && UIApplication.shared.applicationState == .active { self.copy(entry) }
                if let deliveryNotice { self.message = deliveryNotice }
                if !reply.hasText { self.message = String(localized: "No speech was detected. Nothing was copied.") }
                if reply.cleanupError != nil {
                    self.message = [deliveryNotice, "AI cleanup was unavailable. Your words were preserved with OLIV’s deterministic cleanup."].compactMap { $0 }.joined(separator: " ")
                }
            } catch {
                let description = self.rememberAPIFailure(error)
                guard self.operationID == id else { return }
                self.clearKeyboardDelivery()
                try? self.pendingStore?.recordAttempt(id: item.id, errorDescription: description)
                try? self.refreshStores()
                self.phase = .failed
                self.message = description + (self.pending.contains(where: { $0.id == item.id })
                    ? " Your audio is saved on this iPhone for retry." : " Your completed text is available in History.")
            }
            guard self.operationID == id else { return }
            self.activeRecordID = nil
            self.endBackgroundTask()
            if self.liveActivitiesEnabled {
                if self.phase == .result { await trackLiveActivity { await liveActivity.finish() } }
                else { await trackLiveActivity { await liveActivity.cancel() } }
            }
        }
        operationTask = task
        await task.value
    }

    // MARK: Dictionary

    /// Load dictionary.json; on first launch, seed it from the old
    /// vocabulary/replacement settings. Their keys stay inert in settings.json
    /// (loading never rewrites it) until the next save drops them.
    private func loadDictionary(legacy: LegacyDictionarySettings?) throws {
        let store = try DictionaryBookStore(directory: directory)
        if store.exists {
            dictionary = try store.load()
        } else {
            dictionary = DictionaryBook.migrate(vocabularyText: legacy?.vocabularyText ?? "",
                                                replacements: legacy?.replacements ?? [])
            try store.save(dictionary)
        }
        // Only now: a file that wouldn't load must never be overwritten.
        dictionaryStore = store
    }

    /// The saved server or key changed. The Dictionary starts over with the
    /// new connection, and any reply still on its way from the old one is
    /// ignored. Saving the same connection again changes nothing.
    private func connectionChanged(from previousBinding: String?) {
        connectionGeneration += 1
        guard savedCredentialBinding != previousBinding else { return }
        dictionary.connectionChanged()
        persistDictionary()
    }

    /// Add or edit an entry. Returns an error message when the word is not
    /// accepted (empty, too long, or already in the Dictionary).
    @discardableResult
    func saveDictionaryEntry(id: String? = nil, word: String, correction: String?) -> String? {
        guard dictionaryStore != nil else {
            return String(localized: "Your Dictionary could not be read, so new words can't be saved.")
        }
        guard let word = DictionaryEntry.clean(word) else {
            return String(localized: "Enter a word of up to \(DictionaryEntry.maxFieldLength) characters.")
        }
        let heard = correction.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        var cleanHeard: String?
        if let heard {
            guard let value = DictionaryEntry.clean(heard) else {
                return String(localized: "The spoken phrase needs up to \(DictionaryEntry.maxFieldLength) characters.")
            }
            cleanHeard = value
        }
        var entries = dictionary.entries
        guard entries.count < DictionaryBook.maxEntries || entries.contains(where: { $0.id == id }) else {
            return String(localized: "Your Dictionary is full. Remove a word to add another.")
        }
        var entry = entries.first { $0.id == id } ?? DictionaryEntry(word: word)
        entry.word = word
        entry.correction = cleanHeard
        guard !entries.contains(where: { $0.id != entry.id && $0.identity == entry.identity }) else {
            return String(localized: "That word is already in your Dictionary.")
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
        editDictionary(entries)
        return nil
    }

    func removeOlderVocabulary(_ line: String) {
        dictionary.removeOlderVocabulary(line)
        persistDictionary()
    }

    func removeOlderRule(spoken: String) {
        dictionary.removeOlderRule(spoken: spoken)
        persistDictionary()
    }

    func removeDictionaryEntries(_ ids: Set<String>) {
        editDictionary(dictionary.entries.filter { !ids.contains($0.id) })
    }

    func setDictionaryEntry(_ id: String, starred: Bool? = nil, enabled: Bool? = nil) {
        editDictionary(dictionary.entries.map { entry in
            guard entry.id == id else { return entry }
            var entry = entry
            if let starred { entry.starred = starred }
            if let enabled { entry.enabled = enabled }
            return entry
        })
    }

    private func editDictionary(_ entries: [DictionaryEntry]) {
        dictionary.edit(entries)
        persistDictionary()
        scheduleDictionarySync(after: 1)
    }

    private func persistDictionary() {
        do { try dictionaryStore?.save(dictionary) }
        catch { message = String(localized: "Your Dictionary could not be saved on this iPhone. \(safeDescription(error))") }
    }

    /// A reply carried the server's revision; refresh if another device
    /// changed the Dictionary. It also proves the server is reachable again,
    /// so edits still waiting go now: dictation doesn't use them until then.
    private func noteDictionaryRevision(_ revision: Int?) {
        let changedElsewhere = revision != nil && revision != dictionary.revision
        guard changedElsewhere || !dictionary.pending.isEmpty else { return }
        scheduleDictionarySync(after: 0)
    }

    /// Coalesce bursts of edits into one request.
    func scheduleDictionarySync(after seconds: Double) {
        dictionarySyncTask?.cancel()
        dictionarySyncTask = Task { @MainActor [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            await self?.syncDictionary()
        }
    }

    /// One exchange with the server (server/docs/DICTIONARY.md); reruns
    /// while edits keep arriving. Offline, changes simply wait for the next
    /// trigger (an edit, a dictation, opening OLIV, or pull to refresh).
    func syncDictionary() async {
        if let running = dictionarySyncRun {
            dictionarySyncAgain = true
            await running.value
            return
        }
        let run = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDictionarySync()
        }
        dictionarySyncRun = run
        await run.value
        dictionarySyncRun = nil
    }

    private func runDictionarySync() async {
        var rejectedWords: [String] = []
        repeat {
            guard dictionaryStore != nil, isConfigured, let configuration = try? configuration() else {
                dictionarySyncStatus = .localOnly
                return
            }
            dictionarySyncAgain = false
            let generation = connectionGeneration
            let ops = dictionary.outgoing()
            persistDictionary()
            dictionarySyncStatus = .syncing
            let result: Result<DictionarySnapshot, Error>
            do { result = .success(try await clientFactory(configuration).dictionary(ops: ops)) }
            catch { result = .failure(error) }
            // The answer is about a connection this iPhone has left.
            guard generation == connectionGeneration else {
                dictionarySyncAgain = true
                continue
            }
            do {
                let snapshot = try result.get()
                let refused = Set(snapshot.rejected.map(\.id))
                rejectedWords += (ops ?? []).compactMap { op in
                    guard case .upsert(let entry) = op, refused.contains(entry.id) else { return nil }
                    return entry.word
                }
                dictionaryRejectedWords = rejectedWords
                dictionary.acknowledge(snapshot)
                dictionarySyncStatus = dictionary.pending.isEmpty ? .synced : .waiting
                if !dictionary.pending.isEmpty { dictionarySyncAgain = true }
            } catch OlivError.dictionaryUnsupported {
                dictionary.serverUnsupported()
                dictionarySyncStatus = .unsupported
            } catch let error as OlivError where error == .unauthorized || error == .forbidden(reason: .missingScope) {
                dictionary.exchangeFailed()
                dictionarySyncStatus = .failed(safeDescription(error))
            } catch {
                dictionary.exchangeFailed()
                dictionarySyncStatus = .waiting
            }
            persistDictionary()
        } while dictionarySyncAgain && dictionarySyncStatus != .unsupported
    }

    func cleanText(_ text: String) async {
        guard !isBusy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearKeyboardDelivery()
        phase = .processing
        latest = nil
        message = nil
        let id = UUID()
        operationID = id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let start = ContinuousClock.now
            do {
                guard let retryCooldown = self.retryCooldown else { throw OlivError.corruptedStore }
                try retryCooldown.check()
                let reply = try await self.clientFactory(try self.configuration()).clean(text: text, options: self.currentOptions)
                try Task.checkCancellation()
                self.noteDictionaryRevision(reply.dictionaryRevision)
                guard self.operationID == id else { return }
                let entry = HistoryEntry(source: .cleanup, audioDuration: 0,
                    totalDuration: Self.seconds(start.duration(to: .now)), reply: reply)
                if self.settings.keepHistory {
                    guard let historyStore = self.historyStore else { throw OlivError.corruptedStore }
                    try historyStore.append(entry)
                }
                self.latest = entry
                try self.refreshStores()
                self.phase = .result
                self.selectedTab = 0
                self.cleanupDraft = ""
                if self.settings.autoCopy && reply.hasText && UIApplication.shared.applicationState == .active { self.copy(entry) }
            } catch {
                let description = self.rememberAPIFailure(error)
                guard self.operationID == id else { return }
                self.phase = .failed
                self.message = description
            }
        }
        operationTask = task
        await task.value
    }

    func cancel() async {
        let wasProcessing = phase == .processing
        operationID = nil
        clearKeyboardDelivery()
        operationTask?.cancel()
        operationTask = nil
        meterTask?.cancel()
        meterTask = nil
        speechEndpoint = nil
        if phase == .recording || phase == .preparing {
            let wasRecording = phase == .recording
            capture.discard()
            if wasRecording { CaptureDiagnostics.record(event: .microphoneStopped) }
            try? FileManager.default.removeItem(at: optionsRecoveryURL)
        }
        activeRecordID = nil
        endBackgroundTask()
        phase = .idle
        elapsed = 0
        level = 0
        latest = nil
        message = wasProcessing && !pending.isEmpty ? String(localized: "Stopped waiting. Your recording is saved for retry.") : nil
        if liveActivitiesEnabled { await trackLiveActivity { await liveActivity.cancel() } }
    }

    private func clearKeyboardDelivery() {
        keyboardCaptureRequested = false
        guard let target = keyboardTarget else { return }
        keyboardTarget = nil
        keyboardDelivery?.cancel(recordingID: target.recordingID)
    }

    private func rememberAPIFailure(_ error: Error) -> String {
        let description = safeDescription(error)
        if let until = (error as? OlivError)?.retryAfter {
            do {
                guard let retryCooldown else { throw OlivError.corruptedStore }
                try retryCooldown.record(until: until)
            } catch {
                // Fail closed if the server's cooldown cannot be saved. There is
                // no sleep loop or automatic resend, and retry audio stays intact.
                retryCooldown = nil
                return description + " The retry delay could not be saved. API requests are paused; reopen OLIV after checking device storage."
            }
        }
        return description
    }

    func copy(_ entry: HistoryEntry) {
        guard entry.reply.hasText else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: entry.finalText]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
        if latest?.id == entry.id { latest?.copied = true }
        do {
            try historyStore?.markCopied(id: entry.id)
            try refreshStores()
        } catch { message = String(localized: "Text copied, but the history could not be updated.") }
    }

    func deleteHistory(_ entry: HistoryEntry) {
        guard !isBusy else { return }
        do {
            try historyStore?.remove(id: entry.id)
            if latest?.id == entry.id { latest = nil; phase = .idle }
            try refreshStores()
        } catch { message = safeDescription(error) }
    }

    func clearHistory() {
        guard !isBusy else { return }
        do {
            try historyStore?.removeAll()
            latest = nil
            phase = .idle
            try refreshStores()
        } catch { message = safeDescription(error) }
    }

    func deletePending(_ item: PendingRecording) {
        guard !isBusy else { return }
        do { try pendingStore?.remove(id: item.id); try refreshStores() }
        catch { message = safeDescription(error) }
    }

    func dismissMessage() { message = nil }

    private func refreshStores() throws {
        history = try historyStore?.entries() ?? []
        pending = try pendingStore?.recordings() ?? []
    }

    private var optionsRecoveryURL: URL { directory.appendingPathComponent("inflight-options.json") }
    private func recoverInterruptedRecording() throws {
        guard FileManager.default.fileExists(atPath: capture.recoveryURL.path) else { return }
        let wav = try Data(contentsOf: capture.recoveryURL)
        let options = try JSONDecoder().decode(OlivOptions.self, from: Data(contentsOf: optionsRecoveryURL))
        guard let pendingStore else { throw OlivError.corruptedStore }
        _ = try pendingStore.enqueue(wav: wav, options: options)
        try capture.removeRecoveredAudio()
        try? FileManager.default.removeItem(at: optionsRecoveryURL)
        message = String(localized: "Recovered an interrupted recording. It is ready to retry.")
    }

    private func startBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish OLIV dictation") { [weak self] in
            Task { @MainActor [weak self] in await self?.cancel() }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func credentialBinding(token: String, serverURL: String) -> String {
        SHA256.hash(data: Data(("OLIV-iOS\u{0}" + serverURL + "\u{0}" + token).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func safeDescription(_ error: any Error) -> String {
        if error is CancellationError { return String(localized: "The request was cancelled.") }
        if let known = error as? OlivError { return known.localizedDescription }
        if let known = error as? AppCaptureError { return known.localizedDescription }
        if let known = error as? CredentialError { return known.localizedDescription }
        return String(localized: "OLIV could not finish this operation. Check available storage, microphone access, and your server connection.")
    }
}
