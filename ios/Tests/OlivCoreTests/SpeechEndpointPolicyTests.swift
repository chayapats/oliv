import XCTest
@testable import OlivCore

final class SpeechEndpointPolicyTests: XCTestCase {
    func testSustainedSpeechThenClassifiedPauseFinishesExactlyOnce() {
        var policy = SpeechEndpointPolicy()
        arm(&policy)
        for end in stride(from: 1.0, through: 2.0, by: 0.25) {
            XCTAssertNil(feed(&policy, start: end - 0.5, end: end, speech: false))
        }
        XCTAssertEqual(feed(&policy, start: 1.75, end: 2.25, speech: false), .finish(.trailingSilence))
        XCTAssertNil(policy.evaluate(elapsed: 120))
        XCTAssertNil(feed(&policy, start: 120, end: 120.5, speech: true))
    }

    func testInitialClassifiedSilenceCancelsWithoutArming() {
        var policy = SpeechEndpointPolicy()
        for end in stride(from: 0.5, through: 7.75, by: 0.25) {
            XCTAssertNil(feed(&policy, start: end - 0.5, end: end, speech: false))
        }
        XCTAssertEqual(feed(&policy, start: 7.5, end: 8, speech: false), .cancel(.initialSilence))
        XCTAssertFalse(policy.hasDetectedSpeech)
        XCTAssertNil(policy.evaluate(elapsed: 9))
    }

    func testSeparatedSingleWindowTransientsNeverArmSpeech() {
        var policy = SpeechEndpointPolicy()
        for end in stride(from: 0.5, through: 7.75, by: 0.25) {
            let transient = [0.5, 2.5, 4.5, 6.5].contains(end)
            XCTAssertNil(feed(&policy, start: end - 0.5, end: end, speech: transient))
            XCTAssertFalse(policy.hasDetectedSpeech)
        }
        XCTAssertEqual(feed(&policy, start: 7.5, end: 8, speech: false), .cancel(.initialSilence))
    }

    func testOverlappingWindowsCountOnlyUniqueVoicedDuration() throws {
        let config = try SpeechEndpointPolicy.Configuration(minimumSpeechDuration: 0.8)
        var policy = SpeechEndpointPolicy(configuration: config)
        for start in [0.0, 0.1, 0.2] {
            XCTAssertNil(feed(&policy, start: start, end: start + 0.5, speech: true))
            XCTAssertFalse(policy.hasDetectedSpeech, "Overlapping evidence must not be double-counted")
        }
        XCTAssertNil(feed(&policy, start: 0.3, end: 0.8, speech: true))
        XCTAssertTrue(policy.hasDetectedSpeech)
    }

    func testShortUtteranceCanUseExplicitSingleObservationConfiguration() throws {
        let config = try SpeechEndpointPolicy.Configuration(minimumSpeechDuration: 0.15,
                                                            minimumSpeechObservations: 1)
        var policy = SpeechEndpointPolicy(configuration: config)
        XCTAssertNil(feed(&policy, start: 0, end: 0.2, speech: true))
        XCTAssertTrue(policy.hasDetectedSpeech)
        XCTAssertNil(feed(&policy, start: 0.2, end: 0.7, speech: false))
        XCTAssertNil(feed(&policy, start: 0.7, end: 1.2, speech: false))
        XCTAssertEqual(feed(&policy, start: 1.2, end: 1.7, speech: false), .finish(.trailingSilence))
    }

    func testFutureMalformedDuplicateAndOutOfOrderWindowsDoNotCreateEvidence() {
        var policy = SpeechEndpointPolicy()
        for (start, end) in [(0.0, Double.nan), (-1, 0.5), (0, .infinity),
                             (1, 1), (2, 1), (0, 3), (.nan, 1)] {
            policy.observe(windowStart: start, windowEnd: end, isSpeech: true)
        }
        policy.observe(windowStart: 100, windowEnd: 100.5, isSpeech: true)
        XCTAssertNil(policy.evaluate(elapsed: 0.25))
        XCTAssertFalse(policy.hasDetectedSpeech)
        policy.observe(windowStart: 0, windowEnd: 0.2, isSpeech: true)
        XCTAssertNil(policy.evaluate(elapsed: 0.25))
        XCTAssertFalse(policy.hasDetectedSpeech)
        policy.observe(windowStart: 0, windowEnd: 0.2, isSpeech: true) // Duplicate.
        policy.observe(windowStart: 0, windowEnd: 0.1, isSpeech: true) // Older result.
        XCTAssertNil(policy.evaluate(elapsed: 0.25))
        XCTAssertFalse(policy.hasDetectedSpeech)
        XCTAssertNil(feed(&policy, start: 0.1, end: 0.3, speech: true))
        XCTAssertTrue(policy.hasDetectedSpeech, "Rejected future timestamps must not poison later valid input")
    }

    func testDetectorCallbackDelayIsNotInterpretedAsTrailingSilence() {
        var policy = SpeechEndpointPolicy()
        arm(&policy)
        XCTAssertNil(policy.evaluate(elapsed: 2.25), "No classified silence has arrived")
        XCTAssertEqual(policy.evaluate(elapsed: 2.251), .cancel(.detectorUnavailable))
        XCTAssertTrue(policy.hasDetectedSpeech, "The caller can preserve this recording for manual recovery")
        XCTAssertNil(policy.evaluate(elapsed: 3))
    }

    func testMissingAudioBetweenResultsDoesNotCountTowardPause() {
        var policy = SpeechEndpointPolicy()
        arm(&policy)
        // Analysis skipped 0.75...2.0. The next window supplies only 0.5s of silence.
        XCTAssertNil(feed(&policy, start: 2, end: 2.5, speech: false))
        XCTAssertNil(feed(&policy, start: 2.5, end: 3, speech: false))
        XCTAssertEqual(feed(&policy, start: 3, end: 3.5, speech: false), .finish(.trailingSilence))
    }

    func testMissingDetectorHasBoundedInitialGracePeriod() {
        var policy = SpeechEndpointPolicy()
        XCTAssertNil(policy.evaluate(elapsed: 8))
        XCTAssertNil(policy.evaluate(elapsed: 9.499))
        XCTAssertEqual(policy.evaluate(elapsed: 9.5), .cancel(.detectorUnavailable))
        XCTAssertFalse(policy.hasDetectedSpeech)
        XCTAssertNil(policy.evaluate(elapsed: 20))
    }

    func testLateInitialAnalysisCanConfirmSilenceWithinGraceButMissingCoverageCannot() {
        var policy = SpeechEndpointPolicy()
        for end in stride(from: 0.5, through: 7.5, by: 0.5) {
            XCTAssertNil(feed(&policy, start: end - 0.5, end: end, speech: false))
        }
        XCTAssertNil(policy.evaluate(elapsed: 8.2))
        policy.observe(windowStart: 7.5, windowEnd: 8, isSpeech: false)
        XCTAssertEqual(policy.evaluate(elapsed: 8.2), .cancel(.initialSilence))

        var incomplete = SpeechEndpointPolicy()
        incomplete.observe(windowStart: 7.5, windowEnd: 8, isSpeech: false)
        XCTAssertEqual(incomplete.evaluate(elapsed: 8), .cancel(.detectorUnavailable),
                       "A single late silence window does not prove the preceding recording was silent")
    }

    func testNaturalShortPauseAndNewSpeechResetTrailingDeadline() {
        var policy = SpeechEndpointPolicy()
        arm(&policy)
        for end in stride(from: 1.0, through: 1.75, by: 0.25) {
            XCTAssertNil(feed(&policy, start: end - 0.5, end: end, speech: false))
        }
        XCTAssertNil(feed(&policy, start: 1.5, end: 2, speech: true))
        XCTAssertNil(feed(&policy, start: 2, end: 2.5, speech: false))
        XCTAssertNil(feed(&policy, start: 2.5, end: 3, speech: false))
        XCTAssertEqual(feed(&policy, start: 3, end: 3.5, speech: false), .finish(.trailingSilence))
    }

    func testHardCapStopsWithOrWithoutSpeechEvenIfAnalysisStops() {
        var heard = SpeechEndpointPolicy()
        arm(&heard)
        XCTAssertEqual(heard.evaluate(elapsed: 120), .finish(.maximumDuration))
        XCTAssertNil(heard.evaluate(elapsed: 121))
        var silent = SpeechEndpointPolicy()
        XCTAssertEqual(silent.evaluate(elapsed: 120), .cancel(.maximumDurationWithoutSpeech))
        XCTAssertNil(silent.evaluate(elapsed: 121))
    }

    func testInvalidOrBackwardAudioClockCannotExpireRecording() {
        var policy = SpeechEndpointPolicy()
        arm(&policy)
        for elapsed in [Double.nan, .infinity, -.infinity, -1, 0.25] {
            XCTAssertNil(policy.evaluate(elapsed: elapsed))
        }
        XCTAssertNil(feed(&policy, start: 0.75, end: 1.25, speech: false))
        XCTAssertNil(feed(&policy, start: 1.25, end: 1.75, speech: false))
        XCTAssertEqual(feed(&policy, start: 1.75, end: 2.25, speech: false), .finish(.trailingSilence))
    }

    func testTimingConfigurationRejectsUnsafeValuesAndPauseCanBeAdjusted() throws {
        XCTAssertThrowsError(try SpeechEndpointPolicy.Configuration(trailingSilence: 0))
        XCTAssertThrowsError(try SpeechEndpointPolicy.Configuration(initialSilenceTimeout: .nan))
        XCTAssertThrowsError(try SpeechEndpointPolicy.Configuration(analysisGracePeriod: .infinity))
        XCTAssertThrowsError(try SpeechEndpointPolicy.Configuration(minimumSpeechDuration: -1))
        XCTAssertThrowsError(try SpeechEndpointPolicy.Configuration(minimumSpeechObservations: 0))
        XCTAssertThrowsError(try SpeechEndpointPolicy.Configuration(maximumDuration: 121))
        XCTAssertThrowsError(try SpeechEndpointPolicy.Configuration(maximumSpeechGap: 2))
        var policy = SpeechEndpointPolicy(configuration: try .init(trailingSilence: 1.2))
        arm(&policy)
        XCTAssertNil(feed(&policy, start: 0.75, end: 1.25, speech: false))
        XCTAssertNil(feed(&policy, start: 1.25, end: 1.75, speech: false))
        XCTAssertEqual(feed(&policy, start: 1.75, end: 1.95, speech: false), .finish(.trailingSilence))
    }

    private func arm(_ policy: inout SpeechEndpointPolicy, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(feed(&policy, start: 0, end: 0.5, speech: true), file: file, line: line)
        XCTAssertFalse(policy.hasDetectedSpeech, file: file, line: line)
        XCTAssertNil(feed(&policy, start: 0.25, end: 0.75, speech: true), file: file, line: line)
        XCTAssertTrue(policy.hasDetectedSpeech, file: file, line: line)
    }

    private func feed(_ policy: inout SpeechEndpointPolicy, start: Double, end: Double,
                      speech: Bool) -> SpeechEndpointPolicy.Decision? {
        policy.observe(windowStart: start, windowEnd: end, isSpeech: speech)
        return policy.evaluate(elapsed: end)
    }
}
