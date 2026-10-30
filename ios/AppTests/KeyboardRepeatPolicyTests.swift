import XCTest

final class KeyboardRepeatPolicyTests: XCTestCase {
    private let fixture = KeyboardRepeatPolicy.Configuration(initialDelay: 0.5, phases: [
        .init(interval: 0.1),
        .init(minimumHold: 1, minimumRepeats: 3, interval: 0.06),
        .init(minimumHold: 2, minimumRepeats: 5, interval: 0.15, unit: .word)
    ])

    func testIdlePolicyNeverSchedulesOrDeletes() {
        var policy = KeyboardRepeatPolicy(configuration: fixture)
        XCTAssertNil(policy.delayUntilNext(at: 100))
        XCTAssertNil(policy.next(at: 100))
    }

    func testCharacterRepeatsNeverReadWordContext() {
        var policy = KeyboardRepeatPolicy(configuration: .measuredIOS27)
        var reads = 0
        func readHost() -> Bool { reads += 1; return true }
        _ = policy.begin(at: 0)
        XCTAssertNil(policy.next(at: 0.4, supportsWordDeletion: readHost()))
        for index in 0..<20 {
            XCTAssertEqual(policy.next(at: 0.5 + Double(index) * 0.100001,
                                       supportsWordDeletion: readHost()), .character)
        }
        XCTAssertEqual(reads, 0, "Character cadence must not pay for cross-process word eligibility")
        XCTAssertEqual(policy.next(at: 2.50003, supportsWordDeletion: readHost()), .word)
        XCTAssertEqual(reads, 1)
    }

    func testResponsiveHoldStartsEarlierAndStillCancelsWithoutCatchUp() throws {
        var policy = KeyboardRepeatPolicy(configuration: .responsive)
        XCTAssertEqual(policy.begin(at: 0), .character)
        XCTAssertNil(policy.next(at: 0.219))
        for index in 0..<12 {
            XCTAssertEqual(policy.next(at: 0.22 + Double(index) * 0.060001), .character)
        }
        XCTAssertEqual(policy.next(at: 0.94003), .word)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 0.94003)), 1.29 - 0.94003, accuracy: 0.000001)
        policy.cancel()
        XCTAssertNil(policy.next(at: 5))
        XCTAssertNil(policy.delayUntilNext(at: 5))
        XCTAssertEqual(policy.begin(at: 6), .character)
        XCTAssertNil(policy.next(at: 6.219))
    }

    func testPressDeletesOnceThenWaitsForInitialDelay() throws {
        var policy = KeyboardRepeatPolicy(configuration: fixture)
        XCTAssertEqual(policy.begin(at: 10), .character)
        XCTAssertNil(policy.begin(at: 10.1))
        XCTAssertNil(policy.next(at: 10.499))
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 10.499)), 0.001, accuracy: 0.000001)
        XCTAssertEqual(policy.next(at: 10.5), .character)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 10.5)), 0.1, accuracy: 0.000001)
    }

    func testAccelerationRequiresBothMinimumTimeAndRepeatCount() throws {
        var policy = KeyboardRepeatPolicy(configuration: fixture)
        _ = policy.begin(at: 0)
        // A delayed first wakeup may not jump to words without any repeats.
        XCTAssertEqual(policy.next(at: 10), .character)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 10)), 0.1, accuracy: 0.000001)
        var time = 10.0
        for _ in 0..<2 {
            time += try XCTUnwrap(policy.delayUntilNext(at: time))
            _ = policy.next(at: time)
        }
        time += try XCTUnwrap(policy.delayUntilNext(at: time))
        XCTAssertEqual(policy.next(at: time), .character)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: time)), 0.06, accuracy: 0.000001)
        time += try XCTUnwrap(policy.delayUntilNext(at: time))
        _ = policy.next(at: time)
        time += try XCTUnwrap(policy.delayUntilNext(at: time))
        XCTAssertEqual(policy.next(at: time), .word)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: time)), 0.15, accuracy: 0.000001)
    }

    func testMissedDeadlinesNeverCreateCatchUpDeletionBurst() throws {
        var policy = KeyboardRepeatPolicy(configuration: fixture)
        _ = policy.begin(at: 0)
        XCTAssertEqual(policy.next(at: 5), .character)
        for _ in 0..<100 { XCTAssertNil(policy.next(at: 5)) }
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 5)), 0.1, accuracy: 0.000001)
        XCTAssertNil(policy.next(at: 5.099))
    }

    func testFiveMillisecondJitterDoesNotAccumulateIntoLateWordAcceleration() throws {
        var policy = KeyboardRepeatPolicy(configuration: .measuredIOS27)
        _ = policy.begin(at: 0)
        var time = 0.0
        for index in 0..<20 {
            time += try XCTUnwrap(policy.delayUntilNext(at: time)) + 0.005
            XCTAssertEqual(time, 0.505 + Double(index) * 0.1, accuracy: 0.000001)
            XCTAssertEqual(policy.next(at: time), .character)
            XCTAssertNil(policy.next(at: time))
        }
        time += try XCTUnwrap(policy.delayUntilNext(at: time)) + 0.005
        XCTAssertEqual(time, 2.505, accuracy: 0.000001)
        XCTAssertEqual(policy.next(at: time), .word)
        time += try XCTUnwrap(policy.delayUntilNext(at: time)) + 0.005
        XCTAssertEqual(time, 2.855, accuracy: 0.000001)
        XCTAssertEqual(policy.next(at: time), .word)
    }

    func testNearlyMissedIntervalStillLeavesAtLeastHalfAnIntervalBetweenDeletes() throws {
        var policy = KeyboardRepeatPolicy(configuration: .measuredIOS27)
        _ = policy.begin(at: 0)
        XCTAssertEqual(policy.next(at: 0.595), .character)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 0.595)), 0.05, accuracy: 0.000001)
        XCTAssertNil(policy.next(at: 0.644))
        XCTAssertEqual(policy.next(at: 0.645), .character)
    }

    func testOneFullMissedIntervalRestartsCadenceWithoutShortenedNextGap() throws {
        var policy = KeyboardRepeatPolicy(configuration: .measuredIOS27)
        _ = policy.begin(at: 0)
        XCTAssertEqual(policy.next(at: 0.601), .character)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 0.601)), 0.1, accuracy: 0.000001)
        XCTAssertNil(policy.next(at: 0.700))
        XCTAssertEqual(policy.next(at: 0.701), .character)
    }

    func testCancellationAndNewTouchDiscardOldAcceleration() throws {
        var policy = KeyboardRepeatPolicy(configuration: fixture)
        _ = policy.begin(at: 0)
        for tick in 1...8 { _ = policy.next(at: Double(tick)) }
        policy.cancel()
        policy.cancel()
        XCTAssertNil(policy.next(at: 20))
        XCTAssertNil(policy.delayUntilNext(at: 20))
        XCTAssertEqual(policy.begin(at: 21), .character)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 21)), 0.5, accuracy: 0.000001)
        XCTAssertEqual(policy.next(at: 21.5), .character)
    }

    func testInvalidOrBackwardClockCancelsInsteadOfRepeating() {
        var policy = KeyboardRepeatPolicy(configuration: fixture)
        XCTAssertNil(policy.begin(at: .nan))
        _ = policy.begin(at: 10)
        XCTAssertNil(policy.next(at: 9))
        XCTAssertNil(policy.next(at: 11))
        _ = policy.begin(at: 12)
        XCTAssertNil(policy.next(at: .infinity))
        XCTAssertNil(policy.delayUntilNext(at: 13))
    }

    func testEnglishWordBoundaryIncludesSeparatorsAndAttachedPunctuation() {
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "first second   ", language: "en", wordCount: 1), " second   ")
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "can't", language: "en", wordCount: 1), "can't")
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "one two!", language: "en", wordCount: 1), " two!")
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "The small green bird sings bes", language: "en"), " sings bes")
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "beside the quiet river.", language: "en"), " quiet river.")
    }

    func testWordBoundaryKeepsEmojiAndAccentedGraphemesIntact() {
        let family = "👩🏽‍👩🏻‍👧🏾‍👦🏼"
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "hello " + family, language: "en", wordCount: 1), " " + family)
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "a 🇹🇭", language: "en", wordCount: 1), " 🇹🇭")
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "cafe\u{301}", language: "en"), "cafe\u{301}")
    }

    func testThaiWithoutSpacesUsesLocalWordSegmentationAndGraphemeBoundaries() throws {
        let context = "วันนี้สวัสดีครับ"
        let suffix = try XCTUnwrap(KeyboardDeletionBoundary.wordSuffix(in: context, language: "th", wordCount: 1))
        XCTAssertEqual(suffix, "ครับ")
        XCTAssertTrue(context.hasSuffix(suffix))
        let prefix = context.dropLast(suffix.count)
        XCTAssertEqual(String(prefix) + suffix, context)
        // A tone mark remains attached to its base in the returned word.
        let toned = "หนึ่งเก้า"
        let tonedSuffix = try XCTUnwrap(KeyboardDeletionBoundary.wordSuffix(in: toned, language: "th", wordCount: 1))
        XCTAssertTrue(toned.hasSuffix(tonedSuffix))
        XCTAssertTrue(toned.indices.contains(toned.index(toned.endIndex, offsetBy: -tonedSuffix.count)))
        XCTAssertNotEqual(tonedSuffix.unicodeScalars.first?.properties.generalCategory, .nonspacingMark)
    }

    func testEmptyNewlineAndTruncatedLongWordAreConservative() {
        XCTAssertNil(KeyboardDeletionBoundary.wordSuffix(in: "", language: "en"))
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "hello\r\n", language: "en"), "\r\n")
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: String(repeating: "x", count: 300), language: "en"), "x")
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "   ", language: "en"), " ")
        XCTAssertEqual(KeyboardDeletionBoundary.wordSuffix(in: "previous\nnext", language: "en"), "next")
    }

    func testMeasuredProfileHasTwentyCharacterRepeatsThenTwoWordPulseCadence() throws {
        var policy = KeyboardRepeatPolicy(configuration: .measuredIOS27)
        XCTAssertEqual(policy.begin(at: 0), .character)
        for index in 0..<20 {
            let due = Double(index) * 0.100001 + 0.5
            XCTAssertEqual(policy.next(at: due), .character)
        }
        XCTAssertEqual(policy.next(at: 2.50003), .word)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 2.50003)), 2.85 - 2.50003, accuracy: 0.000001)
        XCTAssertNil(policy.next(at: 2.84))
        XCTAssertEqual(policy.next(at: 2.851), .word)
    }

    func testUnavailableWordContextKeepsCharacterCadenceAndCanRecover() throws {
        var policy = KeyboardRepeatPolicy(configuration: .measuredIOS27)
        _ = policy.begin(at: 0)
        for index in 0..<20 { _ = policy.next(at: 0.5 + Double(index) * 0.100001) }
        XCTAssertEqual(policy.next(at: 2.50003, supportsWordDeletion: false), .character)
        XCTAssertEqual(try XCTUnwrap(policy.delayUntilNext(at: 2.50003)), 2.6 - 2.50003, accuracy: 0.000001)
        XCTAssertEqual(policy.next(at: 2.60003, supportsWordDeletion: true), .word)
    }

    func testHoldBindsAfterOnlyWhenStaleWebFocusSnapshotBecomesUsable() {
        let id = UUID()
        let stale = KeyboardDeletionContext(documentID: id, before: nil, after: "keep first word", selected: nil)
        var hold = KeyboardDeletionHold(context: stale)
        XCTAssertTrue(hold.accepts(stale), "Initial Delete stays immediate while proxy context is unready")
        XCTAssertTrue(hold.accepts(.init(documentID: id, before: "keep first wor", after: nil, selected: nil)))
        XCTAssertTrue(hold.accepts(.init(documentID: id, before: "keep first wo", after: nil, selected: nil)))
        XCTAssertFalse(hold.accepts(.init(documentID: id, before: "keep first", after: " wo", selected: nil)),
                       "After-context must be strict after its first usable binding")
        XCTAssertFalse(hold.accepts(.init(documentID: id, before: "keep first wo", after: nil, selected: nil)),
                       "A cancelled hold must not resume when an older context returns")
    }

    func testUnreadyHoldStillRejectsNewDocumentOrSelection() {
        let id = UUID()
        let initial = KeyboardDeletionContext(documentID: id, before: nil, after: "text", selected: nil)
        for changed in [KeyboardDeletionContext(documentID: UUID(), before: "tex", after: nil, selected: nil),
                        KeyboardDeletionContext(documentID: id, before: "tex", after: nil, selected: "t")] {
            var hold = KeyboardDeletionHold(context: initial)
            XCTAssertFalse(hold.accepts(changed))
            XCTAssertFalse(hold.accepts(initial))
        }
    }

    func testEmptyButAvailableBeforeContextBindsImmediatelyAndSelectionCannotReturn() {
        let id = UUID()
        var empty = KeyboardDeletionHold(context: .init(documentID: id, before: "", after: "text", selected: nil))
        XCTAssertFalse(empty.accepts(.init(documentID: id, before: "tex", after: nil, selected: nil)),
                       "An available empty context is distinct from an unavailable nil context")
        var selected = KeyboardDeletionHold(context: .init(documentID: id, before: "keep", after: "", selected: " text"))
        XCTAssertTrue(selected.accepts(.init(documentID: id, before: "keep", after: "", selected: " text")))
        XCTAssertTrue(selected.accepts(.init(documentID: id, before: "keep", after: "", selected: nil)))
        XCTAssertFalse(selected.accepts(.init(documentID: id, before: "keep", after: "", selected: " text")))
    }

    func testProgressWaitsWithoutIssuingAnotherDeletionUntilHostAcknowledges() throws {
        let id = UUID()
        func context(_ text: String) -> KeyboardDeletionContext {
            .init(documentID: id, before: text, after: "", selected: nil)
        }
        var progress = try XCTUnwrap(KeyboardDeletionProgress(context: context("หนึ่ง เก้า"), deleting: " เก้า", at: 0))
        XCTAssertEqual(progress.next(context: context("หนึ่ง เก้า"), at: 0), .delete)
        for tick in 1...3 {
            XCTAssertEqual(progress.next(context: context("หนึ่ง เก้า"), at: Double(tick) / 100), .wait)
        }
        for (index, text) in ["หนึ่ง เก้", "หนึ่ง เก", "หนึ่ง เ", "หนึ่ง "].enumerated() {
            XCTAssertEqual(progress.next(context: context(text), at: 0.04 + Double(index) / 100), .delete)
        }
        XCTAssertEqual(progress.next(context: context("หนึ่ง"), at: 0.10), .stop(.completed))
        XCTAssertEqual(progress.next(context: context("หนึ่"), at: 0.11), .stop(.completed))
    }

    func testProgressRejectsFieldSelectionCursorMissingAndUnexpectedTextChanges() throws {
        let id = UUID()
        let initial = KeyboardDeletionContext(documentID: id, before: "first word", after: " next", selected: nil)
        let cases: [KeyboardDeletionContext?] = [nil,
            .init(documentID: UUID(), before: "first wor", after: " next", selected: nil),
            .init(documentID: id, before: "first wor", after: " next", selected: "d"),
            .init(documentID: id, before: "first wor", after: "d next", selected: nil),
            .init(documentID: id, before: nil, after: " next", selected: nil),
            .init(documentID: id, before: "other word", after: " next", selected: nil),
            .init(documentID: id, before: "first word!", after: " next", selected: nil),
            .init(documentID: id, before: "fir", after: " next", selected: nil)]
        for response in cases {
            var progress = try XCTUnwrap(KeyboardDeletionProgress(context: initial, deleting: " word", at: 0))
            XCTAssertEqual(progress.next(context: initial, at: 0), .delete)
            XCTAssertEqual(progress.next(context: response, at: 0.01), .stop(.contextChanged))
            XCTAssertEqual(progress.next(context: initial, at: 0.02), .stop(.contextChanged))
        }
    }

    func testProgressBoundsElapsedTimeAndActualHostCallsNotPollCount() throws {
        let id = UUID()
        func context(_ before: String) -> KeyboardDeletionContext {
            .init(documentID: id, before: before, after: nil, selected: nil)
        }
        var progress = try XCTUnwrap(KeyboardDeletionProgress(context: context("a abc"), deleting: " abc", at: 0, maximumDeletions: 2))
        XCTAssertEqual(progress.next(context: context("a abc"), at: 0), .delete)
        XCTAssertEqual(progress.next(context: context("a abc"), at: 0.05), .wait)
        XCTAssertEqual(progress.next(context: context("a ab"), at: 0.06), .delete)
        XCTAssertEqual(progress.next(context: context("a a"), at: 0.07), .stop(.limitReached))
        var timed = try XCTUnwrap(KeyboardDeletionProgress(context: context("a abc"), deleting: " abc", at: 0))
        XCTAssertEqual(timed.next(context: context("a abc"), at: 0), .delete)
        XCTAssertEqual(timed.next(context: context("a abc"), at: 0.299), .wait)
        XCTAssertEqual(timed.next(context: context("a ab"), at: 0.30), .stop(.timedOut))
    }

    @MainActor
    func testAsyncHostAcknowledgementsCompleteWordPulseWithOnlyOnePendingCall() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 3)
        let session = host.makeSession()
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        XCTAssertEqual(host.text, "keep")
        XCTAssertEqual(host.deleteCalls, 11)
        XCTAssertEqual(host.overlappingCalls, 0)
        XCTAssertGreaterThan(host.waits, 11)
    }

    @MainActor
    func testResponsiveHostKeepsSynchronousFastPath() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 0)
        let session = host.makeSession()
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        XCTAssertEqual(host.text, "keep")
        XCTAssertEqual(host.deleteCalls, 11)
        XCTAssertEqual(host.waits, 0)
    }

    @MainActor
    func testSynchronousCancellationAfterFirstDeleteStopsResumedPulseAndCompletion() async {
        let documentID = UUID()
        var text = "keep first word"
        var deleteCalls = 0
        var completions = 0
        var afterDelete: (() -> Void)?
        let session = KeyboardWordDeletionSession(readContext: {
            .init(documentID: documentID, before: text, after: "", selected: nil)
        }, deleteBackward: {
            deleteCalls += 1
            text.removeLast()
            // A responsive host acknowledges immediately; cancellation occurs
            // before the pulse reaches its between-delete suspension point.
            afterDelete?()
        })
        afterDelete = { [weak session] in session?.cancel() }
        session.onCompletion = { _ in completions += 1 }

        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        // Let the cancelled task resume from its yield and run its defer.
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(deleteCalls, 1)
        XCTAssertEqual(text, "keep first wor")
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(completions, 0)
    }

    @MainActor
    func testAcknowledgedPulseRefreshesExactlyOnceAfterResponsiveHostMutation() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 0)
        let session = host.makeSession()
        var completed: [String] = []
        session.onCompletion = { documentID in
            XCTAssertEqual(documentID, host.documentID)
            XCTAssertFalse(session.isRunning)
            completed.append(host.text)
        }
        XCTAssertTrue(session.start(language: "en"))
        XCTAssertTrue(completed.isEmpty)
        await finish(session)
        XCTAssertEqual(completed, ["keep"])
    }

    @MainActor
    func testCancelledPulseCannotRefreshAfterLateAcknowledgement() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 3)
        let session = host.makeSession()
        var completions = 0
        session.onCompletion = { _ in completions += 1 }
        // Let the first delete be acknowledged, then cancel while a second is
        // pending. Even acknowledged partial work must not render after cancel.
        host.onWait = { if host.waits >= 4 { session.cancel() } }
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        host.acknowledge()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(host.deleteCalls, 2)
        XCTAssertEqual(completions, 0)
    }

    @MainActor
    func testChangedDocumentCannotReceiveOldPulseCompletion() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 3)
        let session = host.makeSession()
        var completions = 0
        session.onCompletion = { _ in completions += 1 }
        host.onWait = { if host.waits >= 4 { host.documentID = UUID() } }
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        XCTAssertEqual(host.deleteCalls, 2)
        XCTAssertEqual(completions, 0)
    }

    @MainActor
    func testCancelBeforeDelayedAcknowledgementNeverSendsAnotherHostCall() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 3)
        let session = host.makeSession()
        host.onWait = { session.cancel() }
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        host.acknowledge()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(host.deleteCalls, 1)
        XCTAssertEqual(host.text, "keep first wor")
        XCTAssertFalse(session.isRunning)
    }

    @MainActor
    func testFieldOrSelectionChangeDuringDelayedAckStopsThePulse() async {
        for changeField in [true, false] {
            let host = DeletionHostFixture(acknowledgeAfterWaits: 3)
            let session = host.makeSession()
            host.onWait = {
                if changeField { host.documentID = UUID() }
                else { host.selected = "selected" }
            }
            XCTAssertTrue(session.start(language: "en"))
            await finish(session)
            XCTAssertEqual(host.deleteCalls, 1)
            XCTAssertEqual(host.overlappingCalls, 0)
        }
    }

    @MainActor
    func testStalledHostTimesOutAndUsesCharacterFallbackUntilItsContextChanges() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: .max)
        let session = host.makeSession()
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        XCTAssertEqual(host.deleteCalls, 1)
        XCTAssertFalse(session.supportsWordDeletion)
        XCTAssertFalse(session.start(language: "en"))
        host.acknowledge()
        XCTAssertTrue(session.supportsWordDeletion)
        session.cancel(resetFallback: true)
    }

    @MainActor
    func testOverlappingRepeatPulseDoesNotQueueOrDuplicatePendingDeletion() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 3)
        let session = host.makeSession()
        host.onWait = { XCTAssertTrue(session.start(language: "en")) }
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        XCTAssertEqual(host.text, "keep")
        XCTAssertEqual(host.deleteCalls, 11)
        XCTAssertEqual(host.overlappingCalls, 0)
    }

#if DEBUG
    @MainActor
    func testDiagnosticsDistinguishWaitingFromRebasedContextWithoutPublishingText() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 3)
        let session = host.makeSession()
        var summaries: [String] = []
        session.onDiagnostic = { summaries.append($0) }
        host.onWait = { host.text = "revealed " + host.text.dropLast() }
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        XCTAssertEqual(host.deleteCalls, 1)
        XCTAssertTrue(session.diagnosticSummary.contains("wait=1"))
        XCTAssertTrue(session.diagnosticSummary.contains("beforeMismatch=1"))
        XCTAssertTrue(session.diagnosticSummary.contains("timeout=0"))
        XCTAssertTrue(summaries.allSatisfy { !$0.contains("keep") && !$0.contains("revealed") && !$0.contains(host.documentID.uuidString) })
        XCTAssertLessThanOrEqual(summaries.count, 3, "No callback per wait or issued deletion")
    }

    @MainActor
    func testDiagnosticsClassifyDocumentMismatchSeparatelyFromBeforeContext() async {
        let host = DeletionHostFixture(acknowledgeAfterWaits: 3)
        let session = host.makeSession()
        host.onWait = { host.documentID = UUID() }
        XCTAssertTrue(session.start(language: "en"))
        await finish(session)
        XCTAssertTrue(session.diagnosticSummary.contains("documentMismatch=1"))
        XCTAssertTrue(session.diagnosticSummary.contains("beforeMismatch=0"))
        XCTAssertTrue(session.diagnosticSummary.contains("missingContext=0"))
    }
#endif

    @MainActor
    private func finish(_ session: KeyboardWordDeletionSession) async {
        for _ in 0..<1_000 {
            if !session.isRunning { return }
            await Task.yield()
        }
        XCTFail("Bounded deletion pulse did not finish")
        session.cancel()
    }
}

@MainActor
private final class DeletionHostFixture {
    var documentID = UUID()
    var text = "keep first word"
    var after = ""
    var selected: String?
    var onWait: (() -> Void)?
    private(set) var deleteCalls = 0
    private(set) var overlappingCalls = 0
    private(set) var waits = 0
    private var time = 0.0
    private var pending = false
    private var pendingWaits = 0
    private let acknowledgeAfterWaits: Int

    init(acknowledgeAfterWaits: Int) { self.acknowledgeAfterWaits = acknowledgeAfterWaits }

    func makeSession() -> KeyboardWordDeletionSession {
        KeyboardWordDeletionSession(readContext: { [self] in
            .init(documentID: documentID, before: text, after: after, selected: selected)
        }, deleteBackward: { [self] in
            deleteCalls += 1
            if pending { overlappingCalls += 1 }
            pending = true
            pendingWaits = 0
            if acknowledgeAfterWaits == 0 { acknowledge() }
        }, now: { [self] in time }, waitForHost: { [self] in
            waits += 1
            pendingWaits += 1
            time += 0.004
            onWait?()
            await Task.yield()
            if pendingWaits >= acknowledgeAfterWaits { acknowledge() }
        })
    }

    func acknowledge() {
        guard pending, !text.isEmpty else { return }
        text.removeLast()
        pending = false
    }
}
