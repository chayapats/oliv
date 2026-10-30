import AppIntents
import Foundation

private enum OlivIntentError: LocalizedError {
    case appProcessRequired
    case noTranscript
    case processingFailed
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .appProcessRequired:
            return "Open OLIV once to finish setup, then try again."
        case .noTranscript:
            return "There is no transcript to copy yet. Record something in OLIV first."
        case .processingFailed:
            return "OLIV could not finish this recording. Open the app to review or retry it."
        case .startFailed(let guidance):
            return guidance
        }
    }
}

/// A separate throwing boundary preserves opaque result inference in extension builds.
/// It never lets the extension report success for an app-owned operation.
private func refuseExtensionExecution() throws {
    throw OlivIntentError.appProcessRequired
}

/// Both protocols matter: recording declares microphone use; LiveActivityIntent routes to the app.
/// The same declaration belongs to the app and the widget extension, but recording is app-owned.
struct ToggleCaptureIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle OLIV"
    static let description = IntentDescription(
        "Start dictation and finish automatically after a pause, inserting into the active OLIV keyboard. Run again to finish sooner. Automatic finish can be disabled in OLIV. The microphone stays off between captures."
    )
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        CaptureDiagnostics.record(event: .intentToggle)
        #if OLIV_APP
        let model = AppModel.shared
        if model.isRecording {
            let previousID = model.latest?.id
            await model.stopFromIntent()
            guard model.latest?.id != previousID, model.phase == .result else {
                throw OlivIntentError.processingFailed
            }
            return .result(value: model.latestTextForIntent ?? "")
        }
        do {
            // Keep perform alive until both the Live Activity and microphone have started.
            try await model.startFromIntent()
        } catch is CancellationError {
            // An explicit cancellation must not reopen the app or restart capture.
            return .result(value: "")
        } catch {
            let failure = model.intentStartFailure(error)
            model.message = failure
            // Keep the original editing context. A failed toggle must not open OLIV
            // and begin a different capture after losing the keyboard's target field.
            throw OlivIntentError.startFailed(failure)
        }
        #else
        try refuseExtensionExecution()
        #endif
        return .result(value: "")
    }
}

enum OlivCaptureTarget: String, AppEnum {
    case capture

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OLIV screen")
    static let caseDisplayRepresentations: [OlivCaptureTarget: DisplayRepresentation] = [
        .capture: DisplayRepresentation(title: "Capture")
    ]
}

// OpenIntent is the documented app-opening contract for WidgetKit controls.
// No URL representation: perform() remains responsible for opening capture and starting audio.
struct QuickCaptureIntent: OpenIntent {
    static let title: LocalizedStringResource = "Capture with OLIV"
    static let description = IntentDescription("Open OLIV and immediately begin recording after setup is complete.")
    static var openAppWhenRun: Bool { true }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Screen", default: .capture)
    var target: OlivCaptureTarget

    static var parameterSummary: some ParameterSummary {
        Summary("Capture with OLIV")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureDiagnostics.record(event: .intentForeground)
        #if OLIV_APP
        let model = AppModel.shared
        model.selectedTab = model.isConfigured ? 0 : 2
        await model.startInForeground()
        #else
        try refuseExtensionExecution()
        #endif
        return .result()
    }
}

struct StopCaptureIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish OLIV"
    static let description = IntentDescription("Finish the current recording and return its text. This never starts a new recording.")
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        CaptureDiagnostics.record(event: .intentFinish)
        let result: String
        #if OLIV_APP
        let model = AppModel.shared
        guard model.isRecording else { return .result(value: "") }
        let previousID = model.latest?.id
        await model.stopFromIntent()
        guard model.latest?.id != previousID, model.phase == .result else {
            throw OlivIntentError.processingFailed
        }
        result = model.latestTextForIntent ?? ""
        #else
        try refuseExtensionExecution()
        result = ""
        #endif
        return .result(value: result)
    }
}

struct CancelCaptureIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel OLIV"
    static let description = IntentDescription("Discard the current recording without sending it for transcription.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if OLIV_APP
        await AppModel.shared.cancel()
        #else
        try refuseExtensionExecution()
        #endif
        return .result()
    }
}

struct CopyLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest OLIV"
    static let description = IntentDescription("Open OLIV and copy the latest transcript, ready to paste into any app.")
    // Foreground copying avoids relying on background pasteboard access.
    static var openAppWhenRun: Bool { true }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if OLIV_APP
        let model = AppModel.shared
        let current = model.latest.flatMap { $0.reply.hasText ? $0 : nil }
        guard let entry = current ?? model.history.first(where: { $0.reply.hasText }) else {
            throw OlivIntentError.noTranscript
        }
        model.copy(entry)
        #else
        try refuseExtensionExecution()
        #endif
        return .result()
    }
}
