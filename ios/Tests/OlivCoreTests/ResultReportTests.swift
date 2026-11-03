import Foundation
import XCTest
@testable import OlivCore

/// "Report a wrong result" (#21): one History entry as a prefilled GitHub issue.
final class ResultReportTests: XCTestCase {
    private let reply = DictationReply(
        raw: "เอ่อ พรุ่งนี้ส่ง design ตอนเก้าโมง", finalText: "พรุ่งนี้ส่ง design ตอน 9 โมง",
        tSTT: 0.84, tCleanup: 0.61, llmRan: true, gateReason: "dict-hit", guardrailFlag: "ok")

    private func entry(_ reply: DictationReply? = nil, source: HistorySource = .dictation) -> HistoryEntry {
        HistoryEntry(source: source, audioDuration: 4.2, totalDuration: 1.93, reply: reply ?? self.reply)
    }

    private func report(_ entry: HistoryEntry? = nil, server: ResultReport.Server = .default) -> ResultReport {
        ResultReport.iPhone(entry: entry ?? self.entry(), appVersion: "0.1.0", build: "19",
                            systemVersion: "26.4", server: server)
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    // MARK: Fields

    func testFieldsComeFromTheHistoryEntry() {
        let report = report()
        XCTAssertEqual(report.typed, "พรุ่งนี้ส่ง design ตอน 9 โมง")
        XCTAssertEqual(report.raw, "เอ่อ พรุ่งนี้ส่ง design ตอนเก้าโมง")
        XCTAssertEqual(report.meant, "")
        XCTAssertEqual(report.engine, "OLIV API (default server)")
        XCTAssertEqual(report.cleanup, "Language model ran (dict-hit) · guardrail ok")
        XCTAssertEqual(report.appVersion, "OLIV 0.1.0 (build 19) · iPhone")
        XCTAssertEqual(report.osVersion, "iOS 26.4")
        XCTAssertEqual(report.timing, "4.2 s audio · speech-to-text 0.8 s · cleanup 0.6 s · total 1.9 s")
        XCTAssertEqual(report.title, "[Wrong result] iPhone · OLIV API")
    }

    func testCleanupAndSourceVariants() {
        XCTAssertEqual(ResultReport.cleanupLabel(DictationReply(gateReason: "clean-thai")),
                       "Language model skipped (clean-thai)")
        XCTAssertEqual(ResultReport.cleanupLabel(DictationReply()), "Off, or nothing to clean")
        XCTAssertEqual(ResultReport.cleanupLabel(DictationReply(noSpeech: true, gateReason: "no_speech")),
                       "No speech detected (no_speech)")
        // The server's error text can echo private words; only the fact is reported.
        let failed = DictationReply(llmRan: true, gateReason: "dict-hit", cleanupError: "timeout on ข้อความลับ")
        XCTAssertEqual(ResultReport.cleanupLabel(failed), "Language model failed, transcript kept (dict-hit)")
        XCTAssertFalse(report(entry(failed)).url.absoluteString.contains(ResultReport.encode("ข้อความลับ")))

        let cleanup = report(entry(source: .cleanup), server: .custom)
        XCTAssertEqual(cleanup.engine, "OLIV API, text cleanup (own server)")
        XCTAssertEqual(cleanup.timing, "cleanup 0.6 s · total 1.9 s")
        XCTAssertEqual(cleanup.title, "[Wrong result] iPhone · text cleanup")
    }

    func testNoSpeechResultReportsNothingTyped() {
        let report = report(entry(DictationReply(raw: "", finalText: "", noSpeech: true, gateReason: "no_speech")))
        XCTAssertEqual(report.typed, "")
        XCTAssertNil(query(report.url)["typed"])
    }

    func testTheOnlyAddressInTheLinkIsGitHubs() {
        let link = report(server: .custom).url.absoluteString
        XCTAssertTrue(link.hasPrefix("https://github.com/chayapats/oliv/issues/new?"))
        XCTAssertEqual(link.components(separatedBy: "http").count, 2)
    }

    /// The app fills only fields the issue form has, by the template's file name.
    func testTemplateHasEveryFieldTheAppFills() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let template = root.appendingPathComponent(".github/ISSUE_TEMPLATE/\(ResultReport.template)")
        let yaml = try String(contentsOf: template, encoding: .utf8)
        let ids = Set(yaml.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("id: ") else { return nil }
            return String(trimmed.dropFirst(4))
        })
        for field in ResultReport.Field.allCases {
            XCTAssertTrue(ids.contains(field.rawValue), "wrong-result.yml has no field \(field.rawValue)")
        }
    }

    // MARK: URL

    func testURLPrefillsTheTemplateAndRoundTripsThaiAndReservedCharacters() {
        let tricky = "C++ & ภาษาไทย = 100% #1\nบรรทัดที่สอง @someone"
        var report = report(entry(DictationReply(raw: tricky, finalText: tricky)))
        report.meant = "ไม่ใช่ + แบบนี้"
        let url = report.url
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/chayapats/oliv/issues/new")
        let values = query(url)
        XCTAssertEqual(values["template"], "wrong-result.yml")
        XCTAssertEqual(values["title"], report.title)
        XCTAssertEqual(values["typed"], tricky)
        XCTAssertEqual(values["raw"], tricky)
        XCTAssertEqual(values["meant"], "ไม่ใช่ + แบบนี้")
        XCTAssertEqual(values["os-version"], "iOS 26.4")
        // GitHub reads a bare + as a space and & as the next field.
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("typed=C%2B%2B%20%26%20%E0%B8%A0"), query)
        XCTAssertFalse(query.contains("+"))
    }

    func testShortReportIsNotTruncated() {
        let report = report()
        XCTAssertTrue(report.fitted().truncated.isEmpty)
        XCTAssertLessThan(report.url.absoluteString.count, ResultReport.maxURLLength)
    }

    func testLongThaiTextIsCutToFitTheLinkAndMarked() {
        let long = String(repeating: "ภาษาไทยยาวมาก ", count: 300)   // 4,200 characters, ~38 KB encoded
        var report = report(entry(DictationReply(raw: long, finalText: long)))
        report.meant = "สั้น ๆ"
        XCTAssertEqual(report.fitted().truncated, [.typed, .raw])
        let url = report.url
        XCTAssertLessThanOrEqual(url.absoluteString.count, ResultReport.maxURLLength)
        XCTAssertGreaterThan(url.absoluteString.count, ResultReport.maxURLLength - 200, "Unused room")
        let values = query(url)
        XCTAssertEqual(values["meant"], "สั้น ๆ", "A short field keeps all of its text")
        for field in ["typed", "raw"] {
            let value = values[field] ?? ""
            guard let marker = value.range(of: "… [truncated by OLIV: ") else { return XCTFail(field) }
            let kept = String(value[..<marker.lowerBound])
            XCTAssertTrue(long.hasPrefix(kept), field)
            XCTAssertTrue(value.hasSuffix(ResultReport.truncationMarker(omitted: long.count - kept.count)), field)
        }
    }

    func testCutNeverSplitsAThaiCharacterFromItsMarks() {
        // "กี่" is one character: a consonant, a vowel and a tone mark.
        let cut = ResultReport.truncate(String(repeating: "กี่", count: 100), toEncodedLength: 400)
        let kept = cut.components(separatedBy: "…").first ?? ""
        XCTAssertFalse(kept.isEmpty)
        XCTAssertEqual(kept.unicodeScalars.count % 3, 0)
        XCTAssertEqual(kept, String(repeating: "กี่", count: kept.count))
        XCTAssertLessThanOrEqual(ResultReport.encode(cut).count, 400)
    }
}
