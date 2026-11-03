// Messages built in model code (not view literals) after they moved to
// String(localized:). The scheme runs tests in English, so these pin the
// English wording; LocalizationCatalogTests covers the Thai side.

import XCTest
@testable import OLIV

final class LocalizedMessagesTests: XCTestCase {
    func testCooldownIsWholeSecondsWithASingular() {
        XCTAssertEqual(OLIVAPIError.cooldown(0.2).errorDescription, "API cooldown — wait 1 second.")
        XCTAssertEqual(OLIVAPIError.cooldown(29.1).errorDescription, "API cooldown — wait 30 seconds.")
    }

    func testCooldownSurvivesAHugeRetryAfter() {
        // Retry-After: 18446744073709551615 must not trap converting to Int.
        let huge = OLIVAPIClient.retryAfter("18446744073709551615", now: Date())
        let message = OLIVAPIError.cooldown(huge).errorDescription ?? ""
        XCTAssertTrue(message.hasPrefix("API cooldown — wait 999") && message.hasSuffix("999 seconds."), message)
        XCTAssertNotNil(OLIVAPIError.cooldown(.infinity).errorDescription)
        // The free trial's own cooldown notice goes through the same clamp.
        let trial = CloudTrial.notice(for: OLIVAPIError.cooldown(huge)) ?? ""
        XCTAssertTrue(trial.hasPrefix("Free-trial limit — wait 999"), trial)
        XCTAssertEqual(CloudTrial.notice(for: OLIVAPIError.cooldown(41.2)),
                       "Free-trial limit — wait 42 s, or for the download")
    }

    func testMenuLineNamesTheEngine() {
        let stats = LastDictationStats(chars: 38, sttSeconds: 0.9, cleanupSeconds: 0.5, engineID: "typhoon-turbo-mlx")
        // The scheme pins the language, not the region: the decimal separator
        // follows the Mac's region ("1.4" or "1,4"), so expect the same format.
        let seconds = (0.9 + 0.5).formatted(.number.precision(.fractionLength(1)))
        XCTAssertEqual(stats.menuLine, "Last: On-device · Typhoon · \(seconds)s · 38 chars")
    }

    func testSupportReportStaysEnglish() {
        let info = RepoInfo(repo: RequiredModels.stt, present: false, bytes: 0)
        XCTAssertEqual(info.reportName, "Thai STT (Typhoon Whisper Turbo MLX)")
        XCTAssertEqual(info.reportSizeText, "Not downloaded")
        XCTAssertEqual(LastDictationStats(chars: 5, sttSeconds: 0.3, cleanupSeconds: 0.2).summary, "0.5s · 5 chars")
    }

    func testWrongResultReportNamesTheEngineInEnglish() {
        // The GitHub issue is read by maintainers: its engine field is English
        // on a Thai Mac too, while the menu's label has Thai.
        let th = Locale(identifier: "th")
        XCTAssertEqual(String(localized: LocalizedStringResource("Cloud · OLIV free trial", locale: th, bundle: .main)),
                       "คลาวด์ · ทดลองใช้ OLIV ฟรี")
        XCTAssertEqual(ResultReport.engineLabel(CloudTrial.engineID), "Cloud · OLIV free trial (oliv-trial)")
        XCTAssertEqual(ResultReport.engineLabel("typhoon-turbo-mlx"), "On-device · Typhoon (typhoon-turbo-mlx)")
        for execution in [DictationExecution.onDevice("Typhoon"), .olivAPI, .olivTrial, .groq, .unknown] {
            // Same words as the label in English, which the tests run in.
            XCTAssertEqual(execution.reportLabel, execution.label)
        }
    }

    func testModeBadgesAndVoiceEditNotices() {
        XCTAssertNil(DictationMode.dictate.hudLabel)
        XCTAssertEqual(DictationMode.translate.hudLabel, "Thai → English")
        XCTAssertEqual(DictationMode.command.hudLabel, "Command mode")
        XCTAssertEqual(DictationMode.translate.processingLabel, "Translating…")
        XCTAssertEqual(VoiceEditRunner.failedNotice("tooLong").text,
                       "That selection is too long — select up to \(2000.formatted()) characters")
        let th = Locale(identifier: "th")
        XCTAssertEqual(String(localized: LocalizedStringResource("Thai → English", locale: th, bundle: .main)),
                       "ไทย → อังกฤษ")
    }
}
