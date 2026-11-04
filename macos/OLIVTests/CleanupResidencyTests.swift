import XCTest

final class CleanupResidencyTests: XCTestCase {
    func testRecordingReservationBlocksIdleUntilProcessingFinishes() {
        var state = CleanupResidency()
        let token = UUID()
        let oldTimer = state.epoch
        state.reserveRecording(token)
        state.begin(); state.end() // Background prewarm finished, recording continues.
        XCTAssertFalse(state.canEvict(epoch: oldTimer))
        XCTAssertFalse(state.canEvict(epoch: state.epoch))
        state.begin(); state.end() // Cleanup completed, controller still owns reservation.
        XCTAssertFalse(state.canEvict(epoch: state.epoch))
        state.releaseRecording(token)
        XCTAssertTrue(state.canEvict(epoch: state.epoch))
    }

    func testOldAndDuplicateReleasesCannotClearANewerRecording() {
        var state = CleanupResidency()
        let first = UUID(), second = UUID()
        state.reserveRecording(first); state.reserveRecording(first)
        state.reserveRecording(second)
        state.releaseRecording(first); state.releaseRecording(first)
        XCTAssertEqual(state.recordings, [second])
        XCTAssertFalse(state.canEvict(epoch: state.epoch))
        state.releaseRecording(second)
        XCTAssertTrue(state.canEvict(epoch: state.epoch))
    }

    func testMemoryPressureOverridesRecordingButWaitsForGeneration() {
        var state = CleanupResidency()
        let token = UUID()
        state.reserveRecording(token)
        state.begin()
        state.requestEviction()
        XCTAssertFalse(state.canEvict(epoch: state.epoch))
        state.end()
        XCTAssertTrue(state.canEvict(epoch: state.epoch))
        state.didEvict()
        XCTAssertFalse(state.canEvict(epoch: state.epoch))
        state.releaseRecording(token)
    }

    func testOldTimerCannotEvictNewRequest() {
        var state = CleanupResidency()
        state.begin(); state.end()
        let oldTimer = state.epoch
        state.begin()
        XCTAssertFalse(state.canEvict(epoch: oldTimer))
        state.end()
        XCTAssertFalse(state.canEvict(epoch: oldTimer))
        XCTAssertTrue(state.canEvict(epoch: state.epoch))
    }

    func testPressureWaitsForAllLoadingAndGeneratingCallers() {
        var state = CleanupResidency()
        state.begin(); state.begin()
        state.requestEviction()
        XCTAssertFalse(state.canEvict(epoch: state.epoch))
        state.end()
        XCTAssertTrue(state.evictionRequested)
        XCTAssertFalse(state.canEvict(epoch: state.epoch))
        state.end()
        XCTAssertTrue(state.canEvict(epoch: state.epoch))
        state.didEvict()
        XCTAssertFalse(state.evictionRequested)
    }

    func testRepeatedTrimInvalidatesPendingTimer() {
        var state = CleanupResidency()
        state.requestEviction()
        let timer = state.epoch
        state.requestEviction()
        XCTAssertFalse(state.canEvict(epoch: timer))
        XCTAssertTrue(state.canEvict(epoch: state.epoch))
    }
}
