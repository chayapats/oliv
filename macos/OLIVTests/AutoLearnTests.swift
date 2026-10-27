// Auto-learn candidate inbox tests: pure proposers, skip-list, inbox dedupe,
// cap, toggle/history gating, approve/dismiss, and the controller seam.
// Hermetic (throwaway UserDefaults suite; no network, no keychain, no models).

import XCTest
@testable import OLIV

@MainActor
final class AutoLearnTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "oliv.tests.autolearn.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSettings() -> OLIVSettings {
        OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
    }

    // MARK: Undo→redictate diff

    func testUndoReditateDiffProposesValidPair() {
        let out = AutoLearn.proposeFromUndoRedo(oldFinal: "call grafannah tomorrow",
                                                newFinal: "call Grafana tomorrow")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].word, "Grafana")
        XCTAssertEqual(out[0].correction, "grafannah")
        XCTAssertEqual(out[0].source, .autoLearn)
        XCTAssertEqual(out[0].reason, AutoLearnCandidate.reasonUndoRedictate)
    }

    func testUndoReditateIdenticalOrBlankEmitsNothing() {
        XCTAssertTrue(AutoLearn.proposeFromUndoRedo(oldFinal: "same text",
                                                    newFinal: "same text").isEmpty)
        XCTAssertTrue(AutoLearn.proposeFromUndoRedo(oldFinal: "", newFinal: "hello").isEmpty)
        XCTAssertTrue(AutoLearn.proposeFromUndoRedo(oldFinal: "hello", newFinal: "   ").isEmpty)
    }

    func testUndoReditateUnalignedMiddleBecomesOnePair() {
        // Insertion alongside the fix: common affix stripped, middles paired.
        let out = AutoLearn.proposeFromUndoRedo(oldFinal: "call grafannah please tomorrow",
                                                newFinal: "call Grafana tomorrow")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].word, "Grafana")
        XCTAssertEqual(out[0].correction, "grafannah please")
    }

    func testUndoReditatePureInsertionEmitsNothing() {
        // No old side to pair against — not a correction pair.
        XCTAssertTrue(AutoLearn.proposeFromUndoRedo(oldFinal: "call tomorrow",
                                                    newFinal: "call Grafana tomorrow").isEmpty)
    }

    // MARK: Thai no-space fallback

    func testThaiShortPairProposesWholeString() {
        let out = AutoLearn.proposeFromUndoRedo(oldFinal: "สวัสดีครับ", newFinal: "สวัสดีค่ะ")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].word, "สวัสดีค่ะ")
        XCTAssertEqual(out[0].correction, "สวัสดีครับ")
    }

    func testThaiLongPairEmitsNothing() {
        let old = String(repeating: "ก", count: 41)
        let new = String(repeating: "ข", count: 41)
        XCTAssertTrue(AutoLearn.proposeFromUndoRedo(oldFinal: old, newFinal: new).isEmpty)
        // Boundary: exactly 40 chars still proposes.
        XCTAssertEqual(AutoLearn.proposeFromUndoRedo(
            oldFinal: String(repeating: "ก", count: 40),
            newFinal: String(repeating: "ข", count: 40)).count, 1)
    }

    func testMixedSpacedSpacelessEmitsNothing() {
        XCTAssertTrue(AutoLearn.proposeFromUndoRedo(oldFinal: "สวัสดีครับ",
                                                    newFinal: "hello world").isEmpty)
    }

    // MARK: Skip-list

    func testSkipListRejectsEmailsURLsHashesNumbersSecrets() {
        XCTAssertTrue(AutoLearn.isSkipped("me@example.com"))
        XCTAssertTrue(AutoLearn.isSkipped("https://example.com/x"))
        XCTAssertTrue(AutoLearn.isSkipped("www.example.com"))
        XCTAssertTrue(AutoLearn.isSkipped("example.com"))
        XCTAssertTrue(AutoLearn.isSkipped("d41d8cd98f00b204e9800998ecf8427e")) // md5 hex
        XCTAssertTrue(AutoLearn.isSkipped("550e8400-e29b-41d4-a716-446655440000")) // UUID
        XCTAssertTrue(AutoLearn.isSkipped("abc123XYZ789")) // machine ID
        XCTAssertTrue(AutoLearn.isSkipped("12345"))
        XCTAssertTrue(AutoLearn.isSkipped("2024-01-15"))
        XCTAssertTrue(AutoLearn.isSkipped("12:30"))
        XCTAssertTrue(AutoLearn.isSkipped("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(AutoLearn.isSkipped("sk-proj-abcdefghijklmnopqrst"))
        XCTAssertTrue(AutoLearn.isSkipped("ghp_abcdefghijklmnopqrstuv"))
        // Real words pass.
        XCTAssertFalse(AutoLearn.isSkipped("Grafana"))
        XCTAssertFalse(AutoLearn.isSkipped("ชยพัฒน์"))
        XCTAssertFalse(AutoLearn.isSkipped("k8s"))
    }

    func testSkipListVetoesPairs() {
        XCTAssertTrue(AutoLearn.proposeFromUndoRedo(
            oldFinal: "call 12345 now", newFinal: "call 67890 now").isEmpty)
        XCTAssertTrue(AutoLearn.proposeFromUndoRedo(
            oldFinal: "mail me@example.com today",
            newFinal: "mail you@example.com today").isEmpty)
        XCTAssertNil(AutoLearn.makeCandidate(word: "me@example.com", correction: nil,
                                             reason: AutoLearnCandidate.reasonAddWord))
    }

    // MARK: Inbox gating / dedupe / cap (settings level)

    func testProposalsReportOnlyNewSuggestions() {
        let s = makeSettings()
        s.dictionaryAutoLearn = true
        let first = s.proposeAutoLearnCandidates(AutoLearn.proposeFromUndoRedo(
            oldFinal: "call grafannah tomorrow", newFinal: "call Grafana tomorrow"))
        XCTAssertEqual(first.map(\.word), ["Grafana"])
        let repeated = s.proposeAutoLearnCandidates(AutoLearn.proposeFromUndoRedo(
            oldFinal: "call grafannah tomorrow", newFinal: "call Grafana tomorrow"))
        XCTAssertTrue(repeated.isEmpty, "a repeat sighting is not announced again")
        XCTAssertEqual(s.autoLearnCandidates.first?.baseCount, 2)
    }

    func testSuggestionNoticeNamesTheChange() {
        let c = AutoLearnCandidate(word: "Grafana", correction: "grafannah",
                                   reason: AutoLearnCandidate.reasonUndoRedictate)
        XCTAssertEqual(DictationController.suggestionNotice(c),
                       "Dictionary suggestion: “grafannah” → “Grafana” · review it in the OLIV menu")
    }

    func testToggleOffBlocksBackgroundProposals() {
        let s = makeSettings()
        XCTAssertFalse(s.dictionaryAutoLearn, "default OFF")
        s.proposeAutoLearnCandidates(AutoLearn.proposeFromUndoRedo(
            oldFinal: "call grafannah tomorrow", newFinal: "call Grafana tomorrow"))
        XCTAssertTrue(s.autoLearnCandidates.isEmpty)
    }

    func testHistoryOffBlocksBackgroundProposals() {
        let s = makeSettings()
        s.dictionaryAutoLearn = true
        s.historyEnabled = false
        s.proposeAutoLearnCandidates(AutoLearn.proposeFromUndoRedo(
            oldFinal: "call grafannah tomorrow", newFinal: "call Grafana tomorrow"))
        XCTAssertTrue(s.autoLearnCandidates.isEmpty, "no retention → no background candidates")
    }

    func testExplicitAddWordSuggestionAlwaysAllowed() {
        for autoLearn in [false, true] {
            for history in [false, true] {
                let s = makeSettings()
                s.dictionaryAutoLearn = autoLearn
                s.historyEnabled = history
                let c = AutoLearnCandidate(word: "Grafana", correction: "grafannah",
                                           reason: AutoLearnCandidate.reasonAddWord)
                s.proposeAutoLearnCandidates([c], explicit: true)
                XCTAssertEqual(s.autoLearnCandidates.count, 1,
                               "explicit add works (autoLearn=\(autoLearn) history=\(history))")
            }
        }
    }

    func testDedupeVsExistingEntriesAndWithinInbox() {
        let s = makeSettings()
        s.dictionaryAutoLearn = true
        s.addDictionaryEntry(word: "Grafana", correction: "grafannah")
        // Same pair as the entry → dropped.
        s.proposeAutoLearnCandidates(AutoLearn.proposeFromUndoRedo(
            oldFinal: "call grafannah tomorrow", newFinal: "call Grafana tomorrow"))
        XCTAssertTrue(s.autoLearnCandidates.isEmpty)
        // Fresh pair stages once; a repeat sighting bumps baseCount, not rows.
        let fresh = AutoLearn.proposeFromUndoRedo(oldFinal: "use koobernetes now",
                                                  newFinal: "use Kubernetes now")
        XCTAssertEqual(fresh.count, 1)
        s.proposeAutoLearnCandidates(fresh)
        s.proposeAutoLearnCandidates(fresh)
        XCTAssertEqual(s.autoLearnCandidates.count, 1)
        XCTAssertEqual(s.autoLearnCandidates[0].baseCount, 2)
    }

    func testInboxCapsAt50DroppingOldest() {
        let s = makeSettings()
        s.dictionaryAutoLearn = true
        var batch: [AutoLearnCandidate] = []
        for i in 0..<60 {
            batch.append(AutoLearnCandidate(word: "Word\(i)", reason: "test"))
        }
        s.proposeAutoLearnCandidates(batch)
        XCTAssertEqual(s.autoLearnCandidates.count, 50)
        XCTAssertEqual(s.autoLearnCandidates[0].word, "Word59", "newest first")
        XCTAssertFalse(s.autoLearnCandidates.contains { $0.word == "Word0" }, "oldest dropped")
        // Persisted across reload.
        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.autoLearnCandidates.count, 50)
        XCTAssertEqual(reloaded.autoLearnCandidates[0].word, "Word59")
    }

    func testApproveAddsEntryAndDismissForgets() {
        let s = makeSettings()
        s.dictionaryAutoLearn = true
        s.proposeAutoLearnCandidates(AutoLearn.proposeFromUndoRedo(
            oldFinal: "call grafannah tomorrow", newFinal: "call Grafana tomorrow"))
        XCTAssertEqual(s.autoLearnCandidates.count, 1)
        let id = s.autoLearnCandidates[0].id
        let entry = s.approveCandidate(id)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.word, "Grafana")
        XCTAssertEqual(entry?.correction, "grafannah")
        XCTAssertEqual(entry?.source, .autoLearn)
        XCTAssertTrue(s.autoLearnCandidates.isEmpty)
        XCTAssertEqual(s.dictionaryEntries.count, 1)
        // Unknown id → nil, no crash.
        XCTAssertNil(s.approveCandidate(UUID()))
        // Dismiss path.
        s.proposeAutoLearnCandidates([AutoLearnCandidate(word: "Kubernetes",
                                                         reason: AutoLearnCandidate.reasonAddWord)],
                                     explicit: true)
        XCTAssertEqual(s.autoLearnCandidates.count, 1)
        s.dismissCandidate(s.autoLearnCandidates[0].id)
        XCTAssertTrue(s.autoLearnCandidates.isEmpty)
        s.clearCandidates() // no-op, never crashes
    }

    // MARK: Controller seam

    func testControllerNoteUndoThenRedictateStagesProposal() {
        let s = makeSettings()
        s.dictionaryAutoLearn = true
        let controller = DictationController(appState: AppState())
        controller.autoLearnSettings = s
        controller.lastUndoneForLearn = ("call grafannah tomorrow", Date())
        controller.noteUndoThenRedictate(old: "call grafannah tomorrow",
                                        new: "call Grafana tomorrow")
        XCTAssertEqual(s.autoLearnCandidates.count, 1)
        XCTAssertEqual(s.autoLearnCandidates[0].word, "Grafana")
        // One-shot: the marker is consumed.
        XCTAssertNil(controller.lastUndoneForLearn)
        controller.noteUndoThenRedictate(old: "call grafannah tomorrow",
                                        new: "call Grafana tomorrow")
        XCTAssertEqual(s.autoLearnCandidates.count, 1, "consumed marker → no second proposal")
    }

    func testControllerSeamRespectsWindowAndMissingStore() {
        let s = makeSettings()
        s.dictionaryAutoLearn = true
        let controller = DictationController(appState: AppState())
        controller.autoLearnSettings = s
        // Stale undo (beyond the window) → no-op.
        controller.autoLearnWindowSeconds = 30
        controller.lastUndoneForLearn = ("call grafannah tomorrow",
                                        Date(timeIntervalSinceNow: -31))
        controller.noteUndoThenRedictate(old: "call grafannah tomorrow",
                                        new: "call Grafana tomorrow")
        XCTAssertTrue(s.autoLearnCandidates.isEmpty)
        // No store wired → no-op, never crashes.
        let bare = DictationController(appState: AppState())
        bare.lastUndoneForLearn = ("call grafannah tomorrow", Date())
        bare.noteUndoThenRedictate(old: "call grafannah tomorrow",
                                   new: "call Grafana tomorrow")
    }

    // MARK: Add-word scan (word-only add → near-miss in recent transcripts)

    func testAddWordFindsNearMissInRecentTranscript() {
        let c = AutoLearn.proposeCorrectionForNewWord(
            word: "Grafana",
            recentTexts: ["call grafannah tomorrow"])
        XCTAssertEqual(c?.word, "Grafana")
        XCTAssertEqual(c?.correction, "grafannah")
        XCTAssertEqual(c?.reason, AutoLearnCandidate.reasonAddWord)
        XCTAssertEqual(c?.source, .autoLearn)
    }

    func testAddWordAlreadyCorrectEmitsNothing() {
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(
            word: "Grafana", recentTexts: ["I love Grafana"]))
    }

    func testAddWordPrefersClosestThenNewest() {
        // Strictly closer wins regardless of order.
        let closer = AutoLearn.proposeCorrectionForNewWord(
            word: "Grafana",
            recentTexts: ["old grafannah x", "new grafanah y"])
        XCTAssertEqual(closer?.correction, "grafanah")
        // Tie on distance → the newest transcript wins.
        let tied = AutoLearn.proposeCorrectionForNewWord(
            word: "Grafana",
            recentTexts: ["new grafannay y", "old grafannah x"])
        XCTAssertEqual(tied?.correction, "grafannay")
    }

    func testAddWordThaiShortNearMiss() {
        let c = AutoLearn.proposeCorrectionForNewWord(
            word: "เจนจิรา", recentTexts: ["เจนจิลา"])
        XCTAssertEqual(c?.word, "เจนจิรา")
        XCTAssertEqual(c?.correction, "เจนจิลา")
    }

    func testAddWordCrossScriptEmitsNothing() {
        // Thai mishearing → English word cannot match by edit distance;
        // those still need a manual correction or the undo→redictate flow.
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(
            word: "Pathumma", recentTexts: ["ใช้ปธมากับเจมมา"]))
    }

    func testAddWordRejectsBadInput() {
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(word: "   ", recentTexts: ["hello"]))
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(word: "Grafana", recentTexts: []))
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(word: "Grafana", recentTexts: ["   "]))
        // Multi-word entries have no token alignment in v1.
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(
            word: "work from home", recentTexts: ["work from hom yesterday"]))
    }

    func testAddWordSkipListVetoesHashLikePair() {
        // Near-miss by distance, but both sides are hex-hash-like → vetoed.
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(
            word: "deadbeefcafe1234", recentTexts: ["run deadbeefcafe1235 now"]))
    }

    func testLevenshteinSanity() {
        XCTAssertEqual(AutoLearn.levenshtein("", "abc"), 3)
        XCTAssertEqual(AutoLearn.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(AutoLearn.levenshtein("เจนจิลา", "เจนจิรา"), 1)
    }

    // MARK: Alphanumeric-term mapping ("SHA สองห้าหก → SHA256")

    func testAlphaNumericParts() {
        let sha = AutoLearn.alphaNumericParts("SHA256")
        XCTAssertEqual(sha?.prefix, "SHA")
        XCTAssertEqual(sha?.digits, "256")
        XCTAssertNotNil(AutoLearn.alphaNumericParts("GPT4"))
        XCTAssertNotNil(AutoLearn.alphaNumericParts("H100"), "single-letter prefix allowed")
        XCTAssertNil(AutoLearn.alphaNumericParts("Grafana"), "no digits")
        XCTAssertNil(AutoLearn.alphaNumericParts("H"), "single letter, no digits")
        XCTAssertNil(AutoLearn.alphaNumericParts("work from home"), "spaces")
    }

    func testSegmentThaiNumerals() {
        XCTAssertEqual(AutoLearn.segmentThaiNumerals("สองห้าหก"), ["สอง", "ห้า", "หก"])
        XCTAssertEqual(AutoLearn.segmentThaiNumerals("สิบสอง"), ["สิบ", "สอง"])
        XCTAssertNil(AutoLearn.segmentThaiNumerals("ครับ"))
        XCTAssertNil(AutoLearn.segmentThaiNumerals("สองห้าครับ"), "partial is not a number phrase")
        XCTAssertNil(AutoLearn.segmentThaiNumerals(""))
    }

    func testAddWordFindsSpokenNumeralPhrase() {
        let c = AutoLearn.proposeCorrectionForNewWord(
            word: "SHA256", recentTexts: ["รหัส SHA สองห้าหก ครับ"])
        XCTAssertEqual(c?.word, "SHA256")
        XCTAssertEqual(c?.correction, "SHA สองห้าหก")
        XCTAssertEqual(c?.reason, AutoLearnCandidate.reasonAddWord)
    }

    func testAddWordFindsGluedNumeralPhrase() {
        let c = AutoLearn.proposeCorrectionForNewWord(
            word: "SHA256", recentTexts: ["รหัสSHAสองห้าหกครับ"])
        XCTAssertEqual(c?.correction, "SHAสองห้าหก")
    }

    func testAddWordNumeralRuleNeedsTheWordsOwnDigits() {
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(
            word: "SHA256", recentTexts: ["use SHA สอง now"]))
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(
            word: "SHA256", recentTexts: ["รหัสSHAสองห้าครับ"]))
        XCTAssertEqual(AutoLearn.proposeCorrectionForNewWord(
            word: "SHA256", recentTexts: ["ใช้ SHA สองร้อยห้าสิบหก"])?.correction, "SHA สองร้อยห้าสิบหก")
        XCTAssertEqual(AutoLearn.proposeCorrectionForNewWord(
            word: "H100", recentTexts: ["การ์ด H หนึ่งศูนย์ศูนย์"])?.correction, "H หนึ่งศูนย์ศูนย์")
    }

    func testThaiNumeralReadings() {
        XCTAssertEqual(AutoLearn.thaiNumeralReadings("สองห้าหก"), ["256"])
        XCTAssertEqual(AutoLearn.thaiNumeralReadings("สองร้อยห้าสิบหก"), ["256"])
        XCTAssertEqual(AutoLearn.thaiNumeralReadings("ยี่สิบเอ็ด"), ["21"])
        XCTAssertEqual(AutoLearn.thaiNumeralReadings("สองล้านห้าแสน"), ["2500000"])
        XCTAssertEqual(AutoLearn.thaiNumeralReadings("สองจุดห้า"), [])
        XCTAssertEqual(AutoLearn.thaiNumeralReadings(String(repeating: "ล้าน", count: 12)), [],
                       "overflow is not a number, not a crash")
    }

    func testAddWordNumeralRuleNeedsNumeralsAfterPrefix() {
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(
            word: "SHA256", recentTexts: ["SHA อย่างดี"]))
        XCTAssertNil(AutoLearn.proposeCorrectionForNewWord(
            word: "SHA256", recentTexts: ["ใช้ SHA256 อยู่"]),
            "exact word present, no spoken phrase to map")
    }
}
