import XCTest

final class KeyboardShiftPolicyTests: XCTestCase {
    func testShiftChangesOnTouchDownAndReleaseNeverTogglesAgain() {
        var policy = KeyboardShiftPolicy()
        XCTAssertEqual(policy.begin(current: .off, at: 1), .on)
        XCTAssertTrue(policy.isHeld)
        XCTAssertEqual(policy.heldState, .on)
        XCTAssertEqual(policy.end(at: 1.1), .on)
        XCTAssertFalse(policy.isHeld)
        XCTAssertNil(policy.end(at: 1.2))
    }

    func testSecondTapLocksAndThirdTapCanUnlock() {
        var policy = KeyboardShiftPolicy()
        _ = policy.begin(current: .off, at: 1)
        _ = policy.end(at: 1.05)
        XCTAssertEqual(policy.begin(current: .on, at: 1.15), .locked)
        XCTAssertEqual(policy.end(at: 1.2), .locked)
        XCTAssertEqual(policy.begin(current: .locked, at: 1.25), .off)
        XCTAssertEqual(policy.end(at: 1.3), .off)
    }

    func testDoubleTapFromAutocapitalizedStateStillLocks() {
        var policy = KeyboardShiftPolicy()
        XCTAssertEqual(policy.begin(current: .on, at: 1), .off)
        _ = policy.end(at: 1.05)
        XCTAssertEqual(policy.begin(current: .off, at: 1.15), .locked)
    }

    func testHeldChordKeepsCaseForMultipleLettersThenReturnsToLowercase() {
        var policy = KeyboardShiftPolicy()
        _ = policy.begin(current: .off, at: 1)
        XCTAssertEqual(policy.characterCommitted(current: .on), .on)
        // Host autocapitalization may propose off between character callbacks.
        XCTAssertEqual(policy.heldState, .on)
        XCTAssertEqual(policy.characterCommitted(current: .off), .on)
        XCTAssertEqual(policy.end(at: 2), .off)
    }

    func testSlideToLetterConsumesOneShotWithoutLeavingShiftOn() {
        var policy = KeyboardShiftPolicy()
        _ = policy.begin(current: .off, at: 1)
        XCTAssertEqual(policy.characterCommitted(current: .on), .on)
        XCTAssertEqual(policy.end(at: 1.2), .off)
        XCTAssertEqual(policy.begin(current: .off, at: 1.25), .on)
    }

    func testLockedCaseReturnsAfterTemporaryLowercaseChord() {
        var policy = KeyboardShiftPolicy()
        XCTAssertEqual(policy.begin(current: .locked, at: 1), .off)
        XCTAssertEqual(policy.characterCommitted(current: .off), .off)
        XCTAssertEqual(policy.end(at: 2), .locked)
    }

    func testCancellationRestoresExactPriorStateAndSuppressesStaleRelease() {
        for previous: KeyboardShiftState in [.off, .on, .locked] {
            var policy = KeyboardShiftPolicy()
            _ = policy.begin(current: previous, at: 1)
            XCTAssertEqual(policy.cancel(), previous)
            XCTAssertFalse(policy.isHeld)
            XCTAssertNil(policy.end(at: 1.1))
            XCTAssertNil(policy.cancel())
        }
    }

    func testLongHoldDoesNotBecomeDoubleTapCandidateOnRelease() {
        var policy = KeyboardShiftPolicy()
        _ = policy.begin(current: .off, at: 1)
        XCTAssertEqual(policy.end(at: 9), .on)
        XCTAssertEqual(policy.begin(current: .on, at: 9.1), .off)
    }

    func testInterveningCharacterOrControlBreaksDoubleTapSequence() {
        var policy = KeyboardShiftPolicy()
        _ = policy.begin(current: .off, at: 1)
        _ = policy.end(at: 1.05)
        XCTAssertEqual(policy.characterCommitted(current: .on), .off)
        XCTAssertEqual(policy.begin(current: .off, at: 1.1), .on)
        _ = policy.end(at: 1.15)
        policy.otherActionCommitted()
        XCTAssertEqual(policy.begin(current: .on, at: 1.2), .off)
    }

    func testDuplicateDownAndHostStateChangeCannotReplaceHold() {
        var policy = KeyboardShiftPolicy()
        _ = policy.begin(current: .off, at: 1)
        XCTAssertEqual(policy.begin(current: .off, at: 1.01), .on)
        XCTAssertEqual(policy.begin(current: .locked, at: 1.02), .on)
        XCTAssertEqual(policy.cancel(), .off)
    }

    func testHostStateChangeOrExpiredWindowDoesNotLock() {
        var policy = KeyboardShiftPolicy()
        _ = policy.begin(current: .off, at: 1)
        _ = policy.end(at: 1.05)
        XCTAssertEqual(policy.begin(current: .off, at: 1.1), .on)
        _ = policy.end(at: 1.15)
        XCTAssertEqual(policy.begin(current: .on, at: 2), .off)
    }

    func testInvalidClockDoesNotCreateHeldStateOrLock() {
        var policy = KeyboardShiftPolicy()
        XCTAssertEqual(policy.begin(current: .off, at: .nan), .off)
        XCTAssertFalse(policy.isHeld)
        _ = policy.begin(current: .off, at: 1)
        XCTAssertEqual(policy.end(at: 0), .off)
        XCTAssertFalse(policy.isHeld)
        XCTAssertEqual(policy.begin(current: .off, at: 1.1), .on)
    }
}
