import XCTest

final class CleanupResidencyTests: XCTestCase {
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
