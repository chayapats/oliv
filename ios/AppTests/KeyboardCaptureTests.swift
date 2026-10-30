import Foundation
import XCTest
import OlivCore
@testable import Oliv

final class KeyboardCaptureTests: XCTestCase {
    @MainActor
    func testActionCaptureAutomaticallyFinishesAndDeliversOnceAfterClassifiedPause() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.capture.readingDuration = 3.5
        h.capture.speechObservations = [
            .init(startTime: 0, endTime: 1, isSpeech: true),
            .init(startTime: 0.5, endTime: 1.5, isSpeech: true),
            .init(startTime: 1, endTime: 2, isSpeech: false),
            .init(startTime: 1.5, endTime: 2.5, isSpeech: false),
            .init(startTime: 2, endTime: 3, isSpeech: false),
            .init(startTime: 2.5, endTime: 3.5, isSpeech: false)
        ]
        try await h.model.startFromIntent()
        try await waitForKeyboardTest { h.model.phase == .result }
        XCTAssertEqual(h.capture.detectionRequests, [true])
        XCTAssertFalse(h.capture.microphoneActive)
        XCTAssertEqual(h.capture.stopCount, 1)
        XCTAssertEqual(h.delivery.publications.count, 1)
        let states = await h.service.microphoneStatesAtUpload
        XCTAssertEqual(states, [false])
        await h.model.stopFromIntent()
        XCTAssertEqual(h.capture.stopCount, 1)
    }

    @MainActor
    func testAutomaticCaptureWithNoSpeechStopsWithoutUploadOrInsertion() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.capture.readingDuration = 8.5
        h.capture.speechObservations = stride(from: 0.0, through: 7.5, by: 0.5).map {
            .init(startTime: $0, endTime: $0 + 1, isSpeech: false)
        }
        try await h.model.startFromIntent()
        try await waitForKeyboardTest { h.model.phase == .idle }
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertFalse(h.capture.microphoneActive)
        XCTAssertEqual(h.capture.stopCount, 1, "Silence is discarded only after the classifier drains")
        XCTAssertEqual(h.capture.discardCount, 0, "The already-stopped microphone must not be discarded again")
        XCTAssertTrue(h.model.pending.isEmpty)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testClassifierFailureReleasesMicrophoneAndPreservesAudioWithoutNetwork() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.capture.analysisFailed = true
        try await h.model.startFromIntent()
        try await waitForKeyboardTest { h.model.phase == .failed }
        XCTAssertFalse(h.capture.microphoneActive)
        XCTAssertEqual(h.capture.stopCount, 1)
        XCTAssertEqual(h.model.pending.count, 1)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testClassifierFailureDuringDecisionOrStopNeverUploadsPartialSpeech() async throws {
        for failDuringStop in [false, true] {
            let h = try KeyboardHarness()
            defer { h.removeDirectory() }
            h.capture.readingDuration = 3.5
            h.capture.speechObservations = [
                .init(startTime: 0, endTime: 1, isSpeech: true),
                .init(startTime: 0.5, endTime: 1.5, isSpeech: true),
                .init(startTime: 1, endTime: 2, isSpeech: false),
                .init(startTime: 1.5, endTime: 2.5, isSpeech: false),
                .init(startTime: 2, endTime: 3, isSpeech: false),
                .init(startTime: 2.5, endTime: 3.5, isSpeech: false)
            ]
            h.capture.failAnalysisWhenDraining = !failDuringStop
            h.capture.failAnalysisWhenStopping = failDuringStop
            try await h.model.startFromIntent()
            try await waitForKeyboardTest { h.model.phase == .failed }
            XCTAssertFalse(h.capture.microphoneActive)
            XCTAssertEqual(h.capture.stopCount, 1)
            XCTAssertEqual(h.model.pending.count, 1)
            XCTAssertTrue(h.delivery.publications.isEmpty)
            let calls = await h.service.dictateCalls
            XCTAssertEqual(calls, 0)
        }
    }

    @MainActor
    func testLateClassifierFailureAfterNoSpeechDecisionPreservesAudioWithoutUploading() async throws {
        for failDuringStop in [false, true] {
            let h = try KeyboardHarness()
            defer { h.removeDirectory() }
            h.capture.readingDuration = 8.5
            h.capture.speechObservations = stride(from: 0.0, through: 7.5, by: 0.5).map {
                .init(startTime: $0, endTime: $0 + 1, isSpeech: false)
            }
            h.capture.failAnalysisWhenDraining = !failDuringStop
            h.capture.failAnalysisWhenStopping = failDuringStop
            try await h.model.startFromIntent()
            try await waitForKeyboardTest { h.model.phase == .failed }
            XCTAssertFalse(h.capture.microphoneActive)
            XCTAssertEqual(h.capture.stopCount, 1, "Reuse stopped audio instead of draining twice")
            XCTAssertEqual(h.capture.discardCount, 0, "An unreliable silence decision must never delete the recording")
            XCTAssertEqual(h.model.pending.count, 1)
            XCTAssertTrue(h.delivery.publications.isEmpty)
            let calls = await h.service.dictateCalls
            XCTAssertEqual(calls, 0)
        }
    }

    @MainActor
    func testFrozenAudioClockReleasesMicrophoneWithoutWaitingForSampleTime() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.capture.readingDuration = 0
        try await h.model.startFromIntent()
        try await waitForKeyboardTest(timeout: 5) { h.model.phase == .failed }
        XCTAssertFalse(h.capture.microphoneActive)
        XCTAssertEqual(h.capture.stopCount, 1)
        XCTAssertEqual(h.model.pending.count, 1)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testManualFinishCanWinRaceWithAutomaticFinishWithoutDuplicatingDelivery() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.capture.readingDuration = 3.5
        h.capture.speechObservations = [
            .init(startTime: 0, endTime: 1, isSpeech: true),
            .init(startTime: 0.5, endTime: 1.5, isSpeech: true),
            .init(startTime: 1, endTime: 2, isSpeech: false),
            .init(startTime: 1.5, endTime: 2.5, isSpeech: false),
            .init(startTime: 2, endTime: 3, isSpeech: false)
        ]
        try await h.model.startFromIntent()
        await h.model.stopFromIntent()
        try await waitForKeyboardTest { h.model.phase == .result }
        XCTAssertEqual(h.capture.stopCount, 1)
        XCTAssertEqual(h.delivery.publications.count, 1)
    }

    @MainActor
    func testAutomaticFinishPreferenceIsCapturedAtStartAndManualModeRemainsAvailable() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.model.settings.automaticActionButtonFinish = false
        try await h.model.startFromIntent()
        XCTAssertEqual(h.capture.detectionRequests, [false])
        h.model.settings.automaticActionButtonFinish = true
        await h.model.stopFromIntent()
        try await h.model.startFromIntent()
        XCTAssertEqual(h.capture.detectionRequests, [false, true])
        await h.model.cancel()
    }

    func testOldSettingsDecodeWithAutomaticActionFinishAndPreserveManualPreference() throws {
        let old = AppSettings()
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        dictionary.removeValue(forKey: "actionButtonAutoFinish")
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertTrue(migrated.automaticActionButtonFinish)
        XCTAssertFalse(migrated.stopAfterSilence)
        var disabled = migrated
        disabled.automaticActionButtonFinish = false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(disabled)).automaticActionButtonFinish)
    }

    @MainActor
    func testBackgroundCaptureReleasesItsProcessOnceWorkIsSaved() async throws {
        let directory = keyboardTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var releases = 0
        let capture = KeyboardTestCapture(directory: directory)
        let service = KeyboardTestService(mode: .success, microphoneActive: { capture.microphoneActive })
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "test-token"),
                             capture: capture, liveActivitiesEnabled: false, clientFactory: { _ in service },
                             isInBackground: { true }, releaseProcess: { releases += 1 })
        model.settings.serverURL = "https://oliv.example"
        model.saveSettings()
        try await model.startFromIntent(allowKeyboardDelivery: false)
        XCTAssertEqual(releases, 0, "A recording in progress must keep its process")
        await model.stopFromIntent()
        XCTAssertEqual(model.phase, .result)
        try await waitForKeyboardTest(timeout: 3) { releases == 1 }
        XCTAssertEqual(model.history.count, 1, "The result is on disk before the process goes")
    }

    @MainActor
    func testForegroundCaptureAndNewPressKeepTheProcess() async throws {
        let directory = keyboardTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var releases = 0
        let capture = KeyboardTestCapture(directory: directory)
        let service = KeyboardTestService(mode: .success, microphoneActive: { capture.microphoneActive })
        var background = false
        let model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "test-token"),
                             capture: capture, liveActivitiesEnabled: false, clientFactory: { _ in service },
                             isInBackground: { background }, releaseProcess: { releases += 1 })
        model.settings.serverURL = "https://oliv.example"
        model.saveSettings()
        await model.startInForeground()
        await model.stopFromIntent()
        try await Task.sleep(for: .seconds(1.8))
        XCTAssertEqual(releases, 0, "A capture started on screen never ends the process")

        background = true
        try await model.startFromIntent(allowKeyboardDelivery: false)
        await model.stopFromIntent()
        try await model.startFromIntent(allowKeyboardDelivery: false)
        try await Task.sleep(for: .seconds(1.8))
        XCTAssertEqual(releases, 0, "A new press cancels the pending release")
        await model.cancel()
    }

    @MainActor
    func testRecentResultReturnsAfterTheProcessRelaunches() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        try await h.model.startFromIntent(allowKeyboardDelivery: false)
        await h.model.stopFromIntent()
        let relaunched = AppModel(directory: h.directory, credentials: MemoryCredentialStore(token: "keyboard-test-token"),
                                  capture: h.capture, liveActivitiesEnabled: false)
        XCTAssertEqual(relaunched.latest?.id, h.model.latest?.id)
        XCTAssertEqual(relaunched.phase, .result)
    }

    @MainActor
    func testIdleAndTextOnlyActionsNeverStartMicrophoneOrRequestKeyboardFocus() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        await h.model.stopFromIntent()
        await h.model.checkConnection()
        await h.model.cleanText("typed text")
        XCTAssertEqual(h.capture.startCount, 0)
        XCTAssertFalse(h.capture.microphoneActive)
        XCTAssertEqual(h.delivery.snapshotCount, 0)
        XCTAssertTrue(h.delivery.publications.isEmpty)
    }

    @MainActor
    func testIntentCapturesOriginalTargetAndReleasesMicrophoneBeforeNetwork() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        let original = try XCTUnwrap(h.delivery.focus)
        try await h.model.startFromIntent()
        XCTAssertTrue(h.capture.microphoneActive)
        // A new field cannot become the target of an already-started recording.
        h.delivery.focus = keyboardLease(context: "b")
        await h.model.stopFromIntent()
        let publications = h.delivery.publications
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.target, original)
        XCTAssertEqual(publications.first?.text, h.model.latest?.finalText)
        XCTAssertEqual(h.capture.stopCount, 1)
        XCTAssertFalse(h.capture.microphoneActive)
        let activeAtUpload = await h.service.microphoneStatesAtUpload
        XCTAssertEqual(activeAtUpload, [false], "The recorder must release the microphone before the server is called")
        XCTAssertEqual(h.model.phase, .result)
    }

    @MainActor
    func testForegroundCaptureAndIntentFallbackNeverBindKeyboardFocus() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        await h.model.startInForeground()
        await h.model.stopFromIntent()
        try await h.model.startFromIntent(allowKeyboardDelivery: false)
        await h.model.stopFromIntent()
        XCTAssertEqual(h.delivery.snapshotCount, 0)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        XCTAssertEqual(h.capture.startCount, 2)
        XCTAssertEqual(h.capture.stopCount, 2)
    }

    @MainActor
    func testNoVisibleKeyboardStillRecordsButNeverPublishes() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.delivery.focus = nil
        try await h.model.startFromIntent()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertEqual(h.delivery.snapshotCount, 1)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        XCTAssertTrue(h.model.message?.contains("Allow Full Access") == true)
    }

    @MainActor
    func testRejectedKeyboardPublicationExplainsCopyFallback() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.delivery.acceptPublication = false
        try await h.model.startFromIntent()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertNotNil(h.model.latest)
        XCTAssertTrue(h.model.message?.contains("original keyboard field could not be confirmed") == true)
        XCTAssertTrue(h.model.message?.contains("Copy the result") == true)
        XCTAssertFalse(h.capture.microphoneActive)
    }

    @MainActor
    func testIntentFailureGuidancePreservesPermissionAndActivityCauses() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        let permission = h.model.intentStartFailure(AppCaptureError.microphoneDenied)
        XCTAssertTrue(permission.contains("Privacy & Security"))
        let activity = h.model.intentStartFailure(LiveActivityManager.StartError.disabled)
        XCTAssertTrue(activity.contains("Enable Live Activities"))
        let privateError = NSError(domain: "private token must not appear", code: 42,
                                   userInfo: [NSLocalizedDescriptionKey: "private transcript must not appear"])
        XCTAssertFalse(h.model.intentStartFailure(privateError).contains("private"))
    }

    @MainActor
    func testDeniedPermissionDoesNotRequestFocusOrStartMicrophone() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.capture.hasPermission = false
        do {
            try await h.model.startFromIntent()
            XCTFail("Intent must retain its pre-granted microphone permission requirement")
        } catch {}
        XCTAssertEqual(h.capture.startCount, 0)
        XCTAssertEqual(h.delivery.snapshotCount, 0)
        XCTAssertTrue(h.delivery.publications.isEmpty)
    }

    @MainActor
    func testFailedRecorderStartRevokesTargetWithoutPublishing() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.capture.startError = AppCaptureError.unavailable
        do {
            try await h.model.startFromIntent()
            XCTFail("Fixture start must fail")
        } catch {}
        XCTAssertFalse(h.capture.microphoneActive)
        XCTAssertEqual(h.delivery.snapshotCount, 1)
        XCTAssertEqual(h.delivery.cancelledIDs.count, 1)
        XCTAssertTrue(h.delivery.publications.isEmpty)
    }

    @MainActor
    func testCancellationDuringFocusHandshakeCannotStartMicrophone() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.delivery.holdSnapshot = true
        let start = Task { @MainActor in try await h.model.startFromIntent() }
        try await waitForKeyboardTest { h.delivery.snapshotContinuation != nil }
        await h.model.cancel()
        h.delivery.resolveSnapshot()
        try await start.value
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.capture.startCount, 0)
        XCTAssertTrue(h.delivery.publications.isEmpty)
    }

    @MainActor
    func testRecordingCancellationDiscardsMicrophoneAndCannotLeakTargetToCleanup() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        try await h.model.startFromIntent()
        await h.model.cancel()
        XCTAssertFalse(h.capture.microphoneActive)
        XCTAssertEqual(h.capture.discardCount, 1)
        XCTAssertEqual(h.delivery.cancelledIDs.count, 1)
        await h.model.cleanText("manual cleanup")
        XCTAssertTrue(h.delivery.publications.isEmpty)
        let calls = await h.service.dictateCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testCancelledLateReplyCannotPublishIntoNewRecordingTarget() async throws {
        let h = try KeyboardHarness(mode: .gated)
        defer { h.removeDirectory() }
        let firstFocus = try XCTUnwrap(h.delivery.focus)
        try await h.model.startFromIntent()
        let firstFinish = Task { @MainActor in await h.model.stopFromIntent() }
        try await waitForKeyboardTest { await h.service.isWaiting(1) }
        await h.model.cancel()

        let secondFocus = keyboardLease(context: "b")
        h.delivery.focus = secondFocus
        try await h.model.startFromIntent()
        await h.service.complete(1, text: "old result must never insert")
        await firstFinish.value
        XCTAssertEqual(h.model.phase, .recording)
        XCTAssertTrue(h.delivery.publications.isEmpty)

        let secondFinish = Task { @MainActor in await h.model.stopFromIntent() }
        try await waitForKeyboardTest { await h.service.isWaiting(2) }
        await h.service.complete(2, text: "new result")
        await secondFinish.value
        XCTAssertEqual(h.delivery.publications.count, 1)
        XCTAssertEqual(h.delivery.publications.first?.target, secondFocus)
        XCTAssertNotEqual(h.delivery.publications.first?.target, firstFocus)
        XCTAssertEqual(h.delivery.publications.first?.text, "new result")
    }

    @MainActor
    func testCancellationDuringDeliveryHandshakeDoesNotPublish() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        h.delivery.holdPublication = true
        try await h.model.startFromIntent()
        let finish = Task { @MainActor in await h.model.stopFromIntent() }
        try await waitForKeyboardTest { h.delivery.publicationContinuation != nil }
        XCTAssertFalse(h.capture.microphoneActive)
        await h.model.cancel()
        h.delivery.resolvePublication()
        await finish.value
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        XCTAssertEqual(h.delivery.cancelledIDs.count, 1)
    }

    @MainActor
    func testNoSpeechDoesNotPublishAndRevokesCaptureTarget() async throws {
        let h = try KeyboardHarness(mode: .noSpeech)
        defer { h.removeDirectory() }
        try await h.model.startFromIntent()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        XCTAssertEqual(h.delivery.cancelledIDs.count, 1)
        XCTAssertFalse(h.capture.microphoneActive)
    }

    @MainActor
    func testFailedUploadAndSuccessfulRetryNeverPublishOldRecording() async throws {
        let h = try KeyboardHarness(mode: .failure)
        defer { h.removeDirectory() }
        try await h.model.startFromIntent()
        await h.model.stopFromIntent()
        XCTAssertEqual(h.model.phase, .failed)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        XCTAssertEqual(h.delivery.cancelledIDs.count, 1)
        let item = try XCTUnwrap(h.model.pending.first)
        await h.service.setMode(.success)
        await h.model.retry(item)
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertEqual(h.model.latest?.source, .retry)
        XCTAssertTrue(h.delivery.publications.isEmpty)
        XCTAssertEqual(h.delivery.snapshotCount, 1)
    }

    @MainActor
    func testCompletedCaptureCannotBePublishedAgainByRepeatedStopOrCleanup() async throws {
        let h = try KeyboardHarness()
        defer { h.removeDirectory() }
        try await h.model.startFromIntent()
        await h.model.stopFromIntent()
        await h.model.stopFromIntent()
        await h.model.cleanText("different cleanup result")
        XCTAssertEqual(h.delivery.publications.count, 1)
        XCTAssertEqual(h.delivery.publications.first?.text, "new dictation")
        XCTAssertEqual(h.delivery.snapshotCount, 1)
    }

    @MainActor
    func testBridgeRequiresResponseToFreshRequestNotMerelyUnexpiredLease() async throws {
        let directory = keyboardTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeyboardDeliveryStore(directory: directory)
        let initial = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try store.publishFocus(id: UUID(), documentID: UUID(), revision: 1,
                                   contextHash: String(repeating: "a", count: 64), now: initial)
        var refreshes = 0
        let coordinator = KeyboardDeliveryCoordinator(store: store, refreshTimeout: .zero,
            now: { initial.addingTimeInterval(1) }, requestFocusRefresh: { refreshes += 1 },
            notifyDelivery: { XCTFail("No transcript was published") })
        XCTAssertEqual(refreshes, 0, "Creating the bridge must not start idle polling")
        let focus = await coordinator.snapshotFocus()
        XCTAssertNil(focus, "A six-second lease is insufficient without a response to this request")
        XCTAssertEqual(refreshes, 1)
    }

    @MainActor
    func testBridgeRejectsChangedFieldAtPublicationAndNeverSignalsDelivery() async throws {
        let directory = keyboardTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeyboardDeliveryStore(directory: directory)
        let instant = Date(timeIntervalSince1970: 2_000_000_000)
        let original = try store.publishFocus(id: UUID(), documentID: UUID(), revision: 1,
                                             contextHash: String(repeating: "a", count: 64), now: instant)
        let coordinator = KeyboardDeliveryCoordinator(store: store, refreshTimeout: .zero,
            now: { instant.addingTimeInterval(1) }, requestFocusRefresh: {
                _ = try? store.publishFocus(id: UUID(), documentID: UUID(), revision: 2,
                    contextHash: String(repeating: "b", count: 64), now: instant.addingTimeInterval(1))
            }, notifyDelivery: { XCTFail("A changed field must not receive the transcript") })
        let published = await coordinator.publish(text: "private result", target: original, recordingID: UUID())
        XCTAssertFalse(published)
        XCTAssertNil(try store.consume(for: original, now: instant.addingTimeInterval(1)))
    }

    @MainActor
    func testBridgeRefreshesSameTargetAfterLongCaptureAndPublishesOnlyOnce() async throws {
        let directory = keyboardTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeyboardDeliveryStore(directory: directory)
        let instant = Date(timeIntervalSince1970: 2_000_000_000)
        let original = try store.publishFocus(id: UUID(), documentID: UUID(), revision: 1,
                                             contextHash: String(repeating: "a", count: 64), now: instant)
        var refreshes = 0
        var deliveries = 0
        let coordinator = KeyboardDeliveryCoordinator(store: store, refreshTimeout: .zero,
            now: { instant.addingTimeInterval(100) }, requestFocusRefresh: {
                refreshes += 1
                _ = try? store.publishFocus(id: original.id, documentID: original.documentID,
                    revision: original.revision, contextHash: original.contextHash, now: instant.addingTimeInterval(100))
            }, notifyDelivery: { deliveries += 1 })
        let recordingID = UUID()
        let published = await coordinator.publish(text: "new result", target: original, recordingID: recordingID)
        XCTAssertTrue(published)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(deliveries, 1)
        let delivered = try store.consume(for: original, now: instant.addingTimeInterval(100))
        XCTAssertEqual(delivered?.text, "new result")
        XCTAssertEqual(delivered?.sessionID, recordingID)
        XCTAssertNil(try store.consume(for: original, now: instant.addingTimeInterval(100)))
    }
}

@MainActor
private struct KeyboardHarness {
    let directory: URL
    let capture: KeyboardTestCapture
    let delivery: KeyboardDeliverySpy
    let service: KeyboardTestService
    let model: AppModel

    init(mode: KeyboardTestService.Mode = .success) throws {
        directory = keyboardTestDirectory()
        capture = KeyboardTestCapture(directory: directory)
        delivery = KeyboardDeliverySpy()
        let recorder = capture
        service = KeyboardTestService(mode: mode, microphoneActive: { recorder.microphoneActive })
        let server = service
        model = AppModel(directory: directory, credentials: MemoryCredentialStore(token: "keyboard-test-token"),
                         capture: capture, liveActivitiesEnabled: false, keyboardDelivery: delivery,
                         clientFactory: { _ in server })
        model.settings.serverURL = "https://oliv.example"
        model.settings.autoCopy = false
        model.saveSettings()
    }

    func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class KeyboardDeliverySpy: KeyboardDelivering {
    func isConnected() async -> Bool { false }
    struct Publication {
        let text: String
        let target: KeyboardFocusLease
        let recordingID: UUID
    }
    var focus: KeyboardFocusLease? = keyboardLease()
    var snapshotCount = 0
    var publications: [Publication] = []
    var cancelledIDs: [UUID] = []
    var holdSnapshot = false
    var holdPublication = false
    var acceptPublication = true
    var snapshotContinuation: CheckedContinuation<KeyboardFocusLease?, Never>?
    var publicationContinuation: CheckedContinuation<Void, Never>?

    func snapshotFocus() async -> KeyboardFocusLease? {
        snapshotCount += 1
        if holdSnapshot {
            return await withCheckedContinuation { snapshotContinuation = $0 }
        }
        return focus
    }

    func publish(text: String, target: KeyboardFocusLease, recordingID: UUID) async -> Bool {
        if holdPublication {
            await withCheckedContinuation { publicationContinuation = $0 }
        }
        guard acceptPublication, !Task.isCancelled, !cancelledIDs.contains(recordingID) else { return false }
        publications.append(Publication(text: text, target: target, recordingID: recordingID))
        return true
    }

    func cancel(recordingID: UUID) { cancelledIDs.append(recordingID) }
    func resolveSnapshot() {
        snapshotContinuation?.resume(returning: focus)
        snapshotContinuation = nil
    }
    func resolvePublication() {
        publicationContinuation?.resume()
        publicationContinuation = nil
    }
}

@MainActor
private final class KeyboardTestCapture: AudioCapturing {
    let recoveryURL: URL
    var hasPermission = true
    var onInterruption: (() -> Void)?
    var microphoneActive = false
    var startCount = 0
    var stopCount = 0
    var discardCount = 0
    var startError: (any Error)?
    var readingDuration: TimeInterval = 1
    var speechObservations: [AudioSpeechObservation] = []
    var detectionRequests: [Bool] = []
    var analysisFailed = false
    var failAnalysisWhenDraining = false
    var failAnalysisWhenStopping = false

    init(directory: URL) { recoveryURL = directory.appendingPathComponent("test-recording.wav") }
    func requestPermission() async -> Bool { hasPermission }
    func start() throws {
        if let startError { throw startError }
        startCount += 1
        microphoneActive = true
    }
    func start(detectSpeech: Bool) throws {
        detectionRequests.append(detectSpeech)
        try start()
    }
    func takeSpeechObservations() -> [AudioSpeechObservation] {
        if failAnalysisWhenDraining { analysisFailed = true }
        defer { speechObservations.removeAll() }
        return speechObservations
    }
    func meter() -> (duration: TimeInterval, level: Double, decibels: Float) { (readingDuration, 0.2, -20) }
    func stop() throws -> Data {
        if failAnalysisWhenStopping { analysisFailed = true }
        stopCount += 1
        microphoneActive = false
        return try WAVEncoder.encode(samples: Array(repeating: 1, count: 16_000))
    }
    func discard() { discardCount += 1; microphoneActive = false }
    func removeRecoveredAudio() throws {}
}

private actor KeyboardTestService: OlivServing {
    enum Mode: Sendable { case success, failure, noSpeech, gated }
    private var mode: Mode
    private let microphoneActive: @MainActor @Sendable () -> Bool
    private(set) var dictateCalls = 0
    private(set) var microphoneStatesAtUpload: [Bool] = []
    private var waiting: [Int: CheckedContinuation<DictationReply, Never>] = [:]

    init(mode: Mode, microphoneActive: @escaping @MainActor @Sendable () -> Bool) {
        self.mode = mode
        self.microphoneActive = microphoneActive
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func isWaiting(_ call: Int) -> Bool { waiting[call] != nil }
    func complete(_ call: Int, text: String) {
        waiting.removeValue(forKey: call)?.resume(returning: DictationReply(raw: text, finalText: text))
    }
    func dictate(wav: Data, options: OlivOptions) async throws -> DictationReply {
        _ = try WAVMetadata(data: wav)
        dictateCalls += 1
        let call = dictateCalls
        let active = await microphoneActive()
        microphoneStatesAtUpload.append(active)
        switch mode {
        case .success: return DictationReply(raw: "new dictation", finalText: "new dictation")
        case .failure: throw OlivError.networkUnavailable
        case .noSpeech: return DictationReply(noSpeech: true)
        case .gated: return await withCheckedContinuation { waiting[call] = $0 }
        }
    }
    func clean(text: String, options: OlivOptions) async throws -> DictationReply {
        text.isEmpty ? DictationReply(noSpeech: true) : DictationReply(raw: text, finalText: text)
    }
    func verifyKey() async throws {}
    func health() async throws -> ServerHealth {
        try JSONDecoder().decode(ServerHealth.self, from: Data(
            #"{"ok":true,"whisper":true,"gemma":true,"version":"fixture","prompt":"v5","llm_timeout":5}"#.utf8))
    }
}

private func keyboardLease(context: Character = "a") -> KeyboardFocusLease {
    let instant = Date()
    return KeyboardFocusLease(id: UUID(), documentID: UUID(), revision: 1,
        contextHash: String(repeating: String(context), count: 64), updatedAt: instant,
        expiresAt: instant.addingTimeInterval(6))
}

private func keyboardTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("OLIV-keyboard-tests-" + UUID().uuidString)
}

@MainActor
private func waitForKeyboardTest(timeout: TimeInterval = 2, _ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<Int(timeout * 100) {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for explicit test operation")
    throw CancellationError()
}
