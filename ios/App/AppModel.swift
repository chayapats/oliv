import Foundation
import CryptoKit
import Observation
import OlivCore
import UIKit

protocol OlivServing: Sendable {
    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply
    func clean(text: String, options: OlivOptions) async throws -> DictationReply
    func health() async throws -> ServerHealth
}
extension OlivClient: OlivServing {}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel.makeDefault()

    var phase: CapturePhase = .idle
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
    var hasToken = false
    var selectedTab = 0
    var isDemo = false

    var isConfigured: Bool {
        guard hasToken, settings.requiresNewAPIKey != true, savedCredentialBinding != nil,
              settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) == savedServerURL,
              let url = URL(string: savedServerURL) else { return false }
        // UI redraws must not read Keychain on every audio-meter tick.
        return (try? OlivConfiguration(baseURL: url, token: "configured", allowsInsecureHTTP: settings.allowsInsecureHTTP)) != nil
    }
    var isBusy: Bool { phase == .preparing || phase == .recording || phase == .processing }
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
    @ObservationIgnored private let keyboardDelivery: (any KeyboardDelivering)?
    @ObservationIgnored private var keyboardTarget: KeyboardCaptureTarget?
    @ObservationIgnored private var keyboardCaptureRequested = false
    private enum IntentStartStage { case setup, liveActivity, microphone }
    @ObservationIgnored private var intentStartStage: IntentStartStage = .setup
    @ObservationIgnored private var savedServerURL = ""
    @ObservationIgnored private var savedCredentialBinding: String?
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

    init(directory: URL? = nil,
         credentials: any CredentialStoring = KeychainCredentialStore(),
         capture: (any AudioCapturing)? = nil,
         liveActivitiesEnabled: Bool = true,
         keyboardDelivery: (any KeyboardDelivering)? = nil,
         clientFactory: @escaping (OlivConfiguration) -> any OlivServing = { OlivClient(configuration: $0) }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OLIV", isDirectory: true)
        self.credentials = credentials
        self.capture = capture ?? AudioCaptureService(directory: self.directory)
        self.clientFactory = clientFactory
        self.liveActivitiesEnabled = liveActivitiesEnabled
        self.keyboardDelivery = keyboardDelivery
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var folder = self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let settingsURL = self.directory.appendingPathComponent("settings.json")
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                do {
                    settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
                    if settings.requiresNewAPIKey == true {
                        message = "OLIV now uses a public HTTPS API. Enter your new individual API key in Settings; your writing preferences and recordings were kept."
                    }
                    savedServerURL = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    savedCredentialBinding = settings.credentialBinding
                }
                catch { message = "Saved settings could not be read. Reconnect in Settings; your history and recordings were preserved." }
            }
            do {
                if settings.requiresNewAPIKey == true { hasToken = false }
                else { hasToken = !(try credentials.read() ?? "").isEmpty }
            }
            catch { message = safeDescription(error) }
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
                message = "An interrupted recording was incomplete and could not be retried. Its partial file was preserved. You can record again."
            }
            try refreshStores()
        } catch {
            message = "Saved data could not be loaded. Existing files were preserved. \(safeDescription(error))"
        }
        self.capture.onInterruption = { [weak self] in
            Task { @MainActor [weak self] in await self?.stopFromIntent() }
        }
    }

    private static func makeDefault() -> AppModel {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") || arguments.contains("--demo")
            || arguments.contains("--keyboard-test-host") || arguments.contains("--keyboard-integration-demo") {
            return PreviewEnvironment.makeModel()
        }
        #endif
        return AppModel(keyboardDelivery: KeyboardDeliveryCoordinator.makeDefault())
    }

    private func configuration() throws -> OlivConfiguration {
        guard settings.requiresNewAPIKey != true else {
            throw OlivError.invalidConfiguration("The old shared token is retired. Enter a new individual API key in Settings and save it.")
        }
        guard let url = URL(string: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let token = try credentials.read(), !token.isEmpty else { throw AppCaptureError.setupRequired }
        guard settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) == savedServerURL else {
            throw OlivError.invalidConfiguration("Save the server address in Settings before connecting or recording.")
        }
        guard savedCredentialBinding == Self.credentialBinding(token: token, serverURL: savedServerURL) else {
            throw OlivError.invalidConfiguration("Save your server settings again to pair this address with its access token.")
        }
        return try OlivConfiguration(baseURL: url, token: token, allowsInsecureHTTP: settings.allowsInsecureHTTP)
    }

    func saveSettings() {
        guard !isBusy else { message = "Finish this dictation before changing settings."; return }
        do {
            try settings.options.validate()
            try settings.options.validateServerLimits()
            let entered = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if settings.requiresNewAPIKey == true && entered.isEmpty {
                throw OlivError.invalidConfiguration("Enter your new individual API key. The retired shared token cannot be reused.")
            }
            let token = entered.isEmpty ? (try credentials.read() ?? "") : entered
            guard let url = URL(string: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AppCaptureError.setupRequired
            }
            _ = try OlivConfiguration(baseURL: url, token: token, allowsInsecureHTTP: settings.allowsInsecureHTTP)
            var approved = settings
            approved.requiresNewAPIKey = false
            approved.credentialBinding = Self.credentialBinding(token: token,
                serverURL: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
            let data = try JSONEncoder().encode(approved)
            if !entered.isEmpty { try credentials.write(entered) }
            try data.write(to: directory.appendingPathComponent("settings.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            savedServerURL = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            savedCredentialBinding = approved.credentialBinding
            settings = approved
            tokenInput = ""
            hasToken = true
            connectionMessage = "Settings saved. API key permissions are checked when you dictate or clean text."
            message = nil
        } catch { message = safeDescription(error) }
    }

    func checkConnection() async {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        do {
            guard let url = URL(string: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw OlivError.invalidConfiguration("Enter a valid OLIV server URL.")
            }
            // Liveness is public and must neither disclose a saved key to an unsaved
            // address nor require the separate clean scope as a dictation preflight.
            let client = clientFactory(try OlivConfiguration(baseURL: url, token: "liveness-only",
                allowsInsecureHTTP: settings.allowsInsecureHTTP))
            let health = try await client.health()
            guard health.ok else {
                connectionMessage = "The API responded but did not report healthy liveness."
                return
            }
            connectionMessage = "API reachable · key and speech models not verified. Dictation requires dictate permission; text cleanup requires clean permission."
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
            return "iOS could not start OLIV’s Live Activity. Check iPhone Settings → Apps → OLIV → Live Activities, then try Toggle OLIV again."
        case .microphone:
            return "iOS could not start the microphone. Recording did not begin. If a call or another recording is active, finish it before trying Toggle OLIV again."
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

    private func beginRecording(fromIntent: Bool, startID: UUID, allowKeyboardDelivery: Bool) async throws {
        intentStartStage = .setup
        if fromIntent { CaptureDiagnostics.record(event: .startRequested, detail: diagnosticAppState) }
        do {
            _ = try configuration()
            try settings.options.validate()
            try settings.options.validateServerLimits()
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
                    try await LiveActivityManager.shared.start()
                    if fromIntent { CaptureDiagnostics.record(event: .liveActivityStarted) }
                }
                catch { if fromIntent { throw error } }
            }
            try Task.checkCancellation()
            guard operationID == startID else { return }
            intentStartStage = .setup
            activeOptions = settings.options
            try JSONEncoder().encode(activeOptions).write(to: optionsRecoveryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            intentStartStage = .microphone
            if fromIntent { CaptureDiagnostics.record(event: .microphoneStarting, detail: diagnosticAppState) }
            let automaticFinish = fromIntent ? settings.automaticActionButtonFinish : settings.stopAfterSilence
            try capture.start(detectSpeech: automaticFinish)
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
                if liveActivitiesEnabled { await LiveActivityManager.shared.cancel() }
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
                message = "No speech was detected. The microphone is off; nothing was sent."
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
            try pendingStore.recordAttempt(id: item.id, errorDescription: "Automatic finish was unavailable. No request was sent.")
            try refreshStores()
            try capture.removeRecoveredAudio()
            try? FileManager.default.removeItem(at: optionsRecoveryURL)
            message = "Automatic finish became unavailable. The microphone is off and your audio is saved for retry. Nothing was inserted."
        } catch {
            // Keep the recovery file if reading, conversion or persistence failed.
            message = "Recording stopped because automatic finish became unavailable. Nothing was inserted. Open OLIV to review the recording."
        }
        if liveActivitiesEnabled { await LiveActivityManager.shared.cancel() }
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
                try? pendingStore.recordAttempt(id: item.id, errorDescription: "Automatic finish was unavailable. No request was sent.")
                CaptureDiagnostics.record(event: .speechAnalysisFailed)
                phase = .failed
                message = "Automatic finish became unavailable. The microphone is off and your audio is saved for retry. Nothing was inserted."
                if liveActivitiesEnabled { await LiveActivityManager.shared.cancel() }
                return
            }
            await submit(item, source: .dictation, keyboardTarget: target,
                         expectsKeyboardDelivery: expectsKeyboardDelivery)
        } catch {
            clearKeyboardDelivery()
            phase = .failed
            message = safeDescription(error)
            if liveActivitiesEnabled { await LiveActivityManager.shared.cancel() }
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
        if liveActivitiesEnabled { await LiveActivityManager.shared.updateProcessing() }
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
                        deliveryNotice = "Your text is ready here. Automatic insertion was unavailable because the original keyboard field could not be confirmed. Copy the result to continue."
                    }
                } else {
                    self.clearKeyboardDelivery()
                    if expectsKeyboardDelivery && reply.hasText {
                        deliveryNotice = "Your text is ready here. OLIV could not connect to the active keyboard. Enable Allow Full Access for OLIV and keep the same field open when using Toggle OLIV."
                    }
                }
                self.phase = .result
                if self.settings.autoCopy && reply.hasText && UIApplication.shared.applicationState == .active { self.copy(entry) }
                if let deliveryNotice { self.message = deliveryNotice }
                if !reply.hasText { self.message = "No speech was detected. Nothing was copied." }
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
                if self.phase == .result { await LiveActivityManager.shared.finish() }
                else { await LiveActivityManager.shared.cancel() }
            }
        }
        operationTask = task
        await task.value
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
                let reply = try await self.clientFactory(try self.configuration()).clean(text: text, options: self.settings.options)
                try Task.checkCancellation()
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
        message = wasProcessing && !pending.isEmpty ? "Stopped waiting. Your recording is saved for retry." : nil
        if liveActivitiesEnabled { await LiveActivityManager.shared.cancel() }
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
        } catch { message = "Text copied, but the history could not be updated." }
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
        message = "Recovered an interrupted recording. It is ready to retry."
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
        if error is CancellationError { return "The request was cancelled." }
        if let known = error as? OlivError { return known.localizedDescription }
        if let known = error as? AppCaptureError { return known.localizedDescription }
        if let known = error as? CredentialError { return known.localizedDescription }
        return "OLIV could not finish this operation. Check available storage, microphone access, and your server connection."
    }
}
