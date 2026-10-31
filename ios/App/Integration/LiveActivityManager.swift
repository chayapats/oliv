import ActivityKit
import Foundation

/// What AppModel needs from ActivityKit, so tests can hold a call open.
@MainActor
protocol LiveActivityControlling: AnyObject {
    func start() async throws
    func updateProcessing() async
    func finish() async
    func cancel() async
}

@MainActor
final class LiveActivityManager: LiveActivityControlling {
    static let shared = LiveActivityManager()

    // Persist only the identifier. ActivityKit's Activity is not Sendable; obtain a fresh
    // local handle for each async operation instead of sending an actor-owned reference.
    private var activityID: String?
    private var observationTask: Task<Void, Never>?
    private var generation: UInt = 0

    enum StartError: LocalizedError {
        case disabled

        var errorDescription: String? {
            String(localized: "Enable Live Activities for OLIV in Settings to record from the Action button or Control Center.")
        }
    }

    private init() {}

    func start() async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw StartError.disabled }
        generation &+= 1
        let startingGeneration = generation
        await endCurrentActivity()
        guard generation == startingGeneration else { throw CancellationError() }
        // Recover status left behind if the app was terminated during a prior recording.
        for oldActivity in Activity<OlivActivityAttributes>.activities {
            await Self.endActivity(id: oldActivity.id, phase: .cancelled, dismissAfter: nil)
            guard generation == startingGeneration else { throw CancellationError() }
        }
        let newActivity = try Activity.request(
            attributes: OlivActivityAttributes(sessionID: UUID(), startedAt: Date()),
            content: ActivityContent(state: .init(phase: .recording), staleDate: nil),
            pushType: nil
        )
        let newID = newActivity.id
        activityID = newID
        let stateUpdates = newActivity.activityStateUpdates
        observationTask = Task { [weak self] in
            for await state in stateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed || state == .ended {
                    guard let self, self.activityID == newID else { return }
                    self.activityID = nil
                    // AudioRecordingIntent requires a visible Live Activity throughout recording.
                    if AppModel.shared.phase == .preparing || AppModel.shared.isRecording {
                        await AppModel.shared.cancel()
                    }
                    return
                }
            }
        }
    }

    func updateProcessing() async {
        guard let id = activityID else { return }
        await Self.updateActivity(id: id)
    }

    func finish() async {
        generation &+= 1
        observationTask?.cancel()
        observationTask = nil
        guard let id = activityID else { return }
        activityID = nil
        await Self.endActivity(id: id, phase: .ready, dismissAfter: Date().addingTimeInterval(60))
    }

    func cancel() async {
        generation &+= 1
        await endCurrentActivity()
    }

    private func endCurrentActivity() async {
        observationTask?.cancel()
        observationTask = nil
        guard let id = activityID else { return }
        activityID = nil
        await Self.endActivity(id: id, phase: .cancelled, dismissAfter: nil)
    }

    // ActivityKit's async methods execute outside MainActor on current SDKs. Keep
    // lookup and use together there; only Sendable identifiers and values cross actors.
    private nonisolated static func updateActivity(id: String) async {
        guard let active = Activity<OlivActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await active.update(ActivityContent(state: .init(phase: .processing), staleDate: Date().addingTimeInterval(120)))
    }

    private nonisolated static func endActivity(id: String, phase: OlivActivityAttributes.Phase, dismissAfter: Date?) async {
        guard let active = Activity<OlivActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await active.end(
            ActivityContent(state: .init(phase: phase), staleDate: nil),
            dismissalPolicy: dismissAfter.map { .after($0) } ?? .immediate
        )
    }
}
