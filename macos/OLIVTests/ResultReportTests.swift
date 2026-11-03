// "Report a Wrong Result…" (#21): the report builder and its preview step.
// The builder is pure over the Recent entry; the preview's draft is the only
// place that can open the browser.

import Combine
import XCTest
@testable import OLIV

@MainActor
final class ResultReportTests: XCTestCase {
    private let details = TranscriptLog.Details(
        raw: "เอ่อ ส่ง design ตอนเก้าโมง", engineID: "typhoon-turbo-mlx", cleanup: true,
        llmRan: true, gateReason: "dict-hit", guardrailFlag: "ok",
        sttSeconds: 0.84, cleanupSeconds: 0.61, audioSeconds: 4.2)

    private func report(text: String = "ส่ง design ตอน 9 โมง",
                        details: TranscriptLog.Details? = nil) -> ResultReport {
        ResultReport.mac(entry: TranscriptLog.Entry(text: text, details: details ?? self.details),
                         appVersion: "0.2.2", build: "19",
                         macOSVersion: "Version 15.6 (Build 24G84)")
    }

    /// Query values as GitHub will read them back.
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    // MARK: Fields

    func testFieldsComeFromTheEntry() {
        let report = report()
        XCTAssertEqual(report.typed, "ส่ง design ตอน 9 โมง")
        XCTAssertEqual(report.raw, "เอ่อ ส่ง design ตอนเก้าโมง")
        XCTAssertEqual(report.meant, "")
        XCTAssertEqual(report.engine, "On-device · Typhoon (typhoon-turbo-mlx)")
        XCTAssertEqual(report.cleanup, "On · language model ran (dict-hit) · guardrail ok")
        XCTAssertEqual(report.appVersion, "OLIV 0.2.2 (build 19) · Mac")
        XCTAssertEqual(report.osVersion, "macOS 15.6 (Build 24G84)")
        XCTAssertEqual(report.timing, "4.2 s audio · speech-to-text 0.8 s · cleanup 0.6 s")
        XCTAssertEqual(report.title, "[Wrong result] Mac · On-device · Typhoon (typhoon-turbo-mlx)")
        XCTAssertEqual(report.kind, .dictation)
        XCTAssertEqual(report.mode, "Dictation")
        XCTAssertEqual(report.source, "")
        XCTAssertEqual(report.instruction, "")
    }

    // MARK: Command mode and translation

    /// A Command mode result: the instruction's transcript is not "what was
    /// said" and the edit is not a dictation, so each part has its own field.
    func testCommandModeReportSeparatesSelectionInstructionAndResult() {
        var edit = details
        edit.raw = "เอ่อ ทำให้สุภาพขึ้น"
        edit.voiceEdit = TranscriptLog.VoiceEdit(mode: .command, heard: "ทำให้สุภาพขึ้น",
                                                 selection: "ส่งไฟล์ deck มาด่วน", applied: true, flag: "ok")
        let report = report(text: "รบกวนส่งไฟล์ deck มาให้หน่อยครับ", details: edit)
        XCTAssertEqual(report.kind, .command)
        XCTAssertEqual(report.mode, "Command mode · edit applied")
        XCTAssertEqual(report.source, "ส่งไฟล์ deck มาด่วน")
        XCTAssertEqual(report.instruction, "ทำให้สุภาพขึ้น")
        XCTAssertEqual(report.typed, "รบกวนส่งไฟล์ deck มาให้หน่อยครับ")
        XCTAssertEqual(report.raw, "เอ่อ ทำให้สุภาพขึ้น")
        XCTAssertEqual(report.cleanup, "Instruction: On · language model ran (dict-hit) · guardrail ok")
        XCTAssertEqual(report.title, "[Wrong result] Mac · Command mode · On-device · Typhoon (typhoon-turbo-mlx)")
        let values = query(report.url)
        XCTAssertEqual(values["mode"], "Command mode · edit applied")
        XCTAssertEqual(values["source"], "ส่งไฟล์ deck มาด่วน")
        XCTAssertEqual(values["instruction"], "ทำให้สุภาพขึ้น")
        XCTAssertEqual(values["typed"], "รบกวนส่งไฟล์ deck มาให้หน่อยครับ")
    }

    func testTranslationReportSaysWhatWasTranslatedAndHowItWent() {
        let thai = "เดี๋ยวผม deploy ตัว hotfix ตอนห้าโมง"
        var translated = details
        translated.voiceEdit = TranscriptLog.VoiceEdit(mode: .translation, heard: thai, selection: nil,
                                                       applied: true, flag: "ok")
        var report = report(text: "I'll deploy the hotfix at 5 p.m.", details: translated)
        XCTAssertEqual(report.kind, .translation)
        XCTAssertEqual(report.mode, "Translation (Thai → English) · translated")
        XCTAssertEqual(report.source, thai)
        XCTAssertEqual(report.instruction, "")
        XCTAssertEqual(report.cleanup, "Thai transcript: On · language model ran (dict-hit) · guardrail ok")
        XCTAssertEqual(report.title, "[Wrong result] Mac · Translation · On-device · Typhoon (typhoon-turbo-mlx)")
        XCTAssertNil(query(report.url)["instruction"], "Command mode only")
        // Cut off at the token limit: the transcript was pasted instead.
        translated.voiceEdit?.applied = false
        translated.voiceEdit?.flag = "unfinished"
        report = self.report(text: thai, details: translated)
        XCTAssertEqual(report.mode, "Translation (Thai → English) · not translated (unfinished), the transcript was pasted")
        XCTAssertEqual(ResultReport.modeLabel(TranscriptLog.VoiceEdit(
            mode: .command, heard: "สั้นลง", selection: "x", applied: false, flag: "unfinished")),
            "Command mode · not applied (unfinished)")
    }

    func testEditsInThePreviewReachTheLink() {
        var edit = details
        edit.voiceEdit = TranscriptLog.VoiceEdit(mode: .command, heard: "สั้นลง",
                                                 selection: "พรุ่งนี้นัดคุณสมชายที่บ้าน", applied: true, flag: "ok")
        var opened: [URL] = []
        let draft = ResultReportDraft(report: report(details: edit), open: { opened.append($0) })
        draft.source = "พรุ่งนี้นัด [ลบชื่อแล้ว]"
        draft.instruction = "สั้นลงหน่อย"
        draft.submit()
        let values = query(opened[0])
        XCTAssertEqual(values["source"], "พรุ่งนี้นัด [ลบชื่อแล้ว]", "the user can take private text out of the selection")
        XCTAssertEqual(values["instruction"], "สั้นลงหน่อย")
    }

    func testALongSelectionIsCutToFitWithTheResult() {
        let long = String(repeating: "ภาษาไทยยาวมาก ", count: 140)   // 1,960 characters
        var edit = details
        edit.voiceEdit = TranscriptLog.VoiceEdit(mode: .command, heard: "สรุปเป็น bullet",
                                                 selection: long, applied: true, flag: "ok")
        let report = report(text: long, details: edit)
        XCTAssertEqual(report.fitted().truncated, [.source, .typed])
        let url = report.url
        XCTAssertLessThanOrEqual(url.absoluteString.count, ResultReport.maxURLLength)
        let values = query(url)
        XCTAssertEqual(values["instruction"], "สรุปเป็น bullet", "a short field keeps all of its text")
        XCTAssertEqual(values["mode"], "Command mode · edit applied")
        XCTAssertTrue(values["source"]?.contains("… [truncated by OLIV: ") == true)
    }

    func testCleanupDescribesWhatHappened() {
        var off = details
        off.cleanup = false
        XCTAssertEqual(ResultReport.cleanupLabel(off), "Off for this dictation")
        var skipped = details
        skipped.llmRan = false
        skipped.gateReason = "clean-thai"
        XCTAssertEqual(ResultReport.cleanupLabel(skipped), "On · language model skipped (clean-thai)")
        var failed = details
        failed.cleanupFailed = true
        XCTAssertEqual(ResultReport.cleanupLabel(failed), "On · language model failed, transcript kept (dict-hit)")
    }

    func testRemoteEnginesAreNamedNotAddressed() {
        var api = details
        api.engineID = OLIVAPIClient.engineID
        let report = report(details: api)
        XCTAssertEqual(report.engine, "Cloud · OLIV API (oliv-api)")
        // The only address in the link is GitHub's.
        let link = report.url.absoluteString
        XCTAssertTrue(link.hasPrefix("https://github.com/chayapats/oliv/issues/new?"))
        XCTAssertEqual(link.components(separatedBy: "http").count, 2)
    }

    func testEntryWithoutPipelineDetailsSendsOnlyWhatIsKnown() {
        let entry = TranscriptLog.Entry(text: "hello")
        let report = ResultReport.mac(entry: entry, appVersion: "0.2.2", build: "19", macOSVersion: "Version 15.6")
        let values = query(report.url)
        XCTAssertEqual(values["typed"], "hello")
        XCTAssertNil(values["raw"])
        XCTAssertNil(values["engine"])
        XCTAssertNil(values["timing"])
        XCTAssertEqual(report.title, "[Wrong result] Mac")
    }

    /// The app fills only fields the issue form has, by the template's file name.
    func testTemplateHasEveryFieldTheAppFills() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
        // ...and the Mac fills every field but the user's own notes.
        XCTAssertEqual(ids.subtracting(ResultReport.Field.allCases.map(\.rawValue)), ["extra"])
    }

    // MARK: URL

    func testURLPrefillsTheTemplateAndRoundTripsThaiAndReservedCharacters() {
        let tricky = "C++ & ภาษาไทย = 100% #1\nบรรทัดที่สอง @someone"
        var report = report(text: tricky)
        report.meant = "ไม่ใช่ + แบบนี้"
        let url = report.url
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/chayapats/oliv/issues/new")
        let values = query(url)
        XCTAssertEqual(values["template"], "wrong-result.yml")
        XCTAssertEqual(values["title"], report.title)
        XCTAssertEqual(values["typed"], tricky)
        XCTAssertEqual(values["meant"], "ไม่ใช่ + แบบนี้")
        XCTAssertEqual(values["raw"], report.raw)
        XCTAssertEqual(values["app-version"], "OLIV 0.2.2 (build 19) · Mac")
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
        var report = report(text: long, details: TranscriptLog.Details(raw: long, engineID: "typhoon-turbo-mlx", cleanup: false))
        report.meant = "สั้น ๆ"
        let fitted = report.fitted()
        XCTAssertEqual(fitted.truncated, [.typed, .raw])
        let url = report.url
        XCTAssertLessThanOrEqual(url.absoluteString.count, ResultReport.maxURLLength)
        XCTAssertGreaterThan(url.absoluteString.count, ResultReport.maxURLLength - 200, "Unused room")
        let values = query(url)
        XCTAssertEqual(values["meant"], "สั้น ๆ", "A short field keeps all of its text")
        for field in ["typed", "raw"] {
            let value = values[field] ?? ""
            let marker = value.range(of: "… [truncated by OLIV: ")
            XCTAssertNotNil(marker, field)
            let kept = String(value[..<marker!.lowerBound])
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

    // MARK: Preview step

    func testNothingOpensUntilThePreviewIsSubmitted() {
        var opened: [URL] = []
        let draft = ResultReportDraft(report: report(), open: { opened.append($0) })
        draft.meant = "ส่ง design ตอน 9 โมงเช้า"
        draft.typed = "ส่ง design ตอน 9 โมง (แก้แล้ว)"
        XCTAssertTrue(opened.isEmpty, "Building or editing a report must not open anything")
        draft.submit()
        XCTAssertEqual(opened.count, 1)
        let values = query(opened[0])
        XCTAssertEqual(values["meant"], "ส่ง design ตอน 9 โมงเช้า")
        XCTAssertEqual(values["typed"], "ส่ง design ตอน 9 โมง (แก้แล้ว)")
        XCTAssertEqual(values["engine"], "On-device · Typhoon (typhoon-turbo-mlx)")
    }

    /// A release through the native test worker keeps the pipeline's details
    /// with the Recent entry. Hermetic: fake capture, a private pasteboard and
    /// a stubbed ⌘V, so no microphone, model or real key press is involved.
    func testDictationKeepsReportDetailsWithTheRecentEntry() async throws {
        let executable = try NativeTestSupport.executable()
        let started = expectation(description: "capture started")
        let worker = CaptureWorker(start: { _, _ in started.fulfill() },
                                   stop: { CapturedAudio(samples: Array(repeating: 0.1, count: 8_000), stats: nil) },
                                   close: {}, isDeviceLive: { true })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.oliv.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let injector = TextInjector(pasteboard: pasteboard)
        injector.postAccessCheck = { true }
        injector.secureInputCheck = { false }
        injector.cmdVPoster = { true }
        let state = AppState()
        let controller = DictationController(appState: state, injector: injector, captureWorker: worker)
        let sidecar = SidecarClient(command: [executable, "sidecar"])
        defer { sidecar.close() }
        controller.sidecar = sidecar
        controller.sttEngine = "typhoon-turbo-mlx"
        controller.cleanupEnabled = true
        controller.historyEnabled = true
        let idle = expectation(description: "release finished")
        let observation = state.$status.dropFirst().sink { if $0 == .idle { idle.fulfill() } }

        controller.handlePress()
        await fulfillment(of: [started], timeout: 2)
        // The worker marks the capture started right after the start closure.
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.handleRelease()
        await fulfillment(of: [idle], timeout: 10)
        withExtendedLifetime(observation) {}
        controller.stop()

        let entry = try XCTUnwrap(state.transcripts.entries.first)
        XCTAssertEqual(entry.text, "Hello world.")
        let details = try XCTUnwrap(entry.details)
        XCTAssertEqual(details.raw, "hello world")
        XCTAssertEqual(details.engineID, "typhoon-turbo-mlx")
        XCTAssertTrue(details.cleanup)
        XCTAssertTrue(details.llmRan)
        XCTAssertEqual(details.gateReason, "dict-hit")
        XCTAssertEqual(details.guardrailFlag, "ok")
        XCTAssertFalse(details.cleanupFailed)
        XCTAssertEqual(details.sttSeconds, 0.012, accuracy: 1e-9)
        XCTAssertEqual(details.cleanupSeconds, 0.003, accuracy: 1e-9)
        XCTAssertEqual(details.audioSeconds, 0.5, accuracy: 1e-9)
    }

    func testRecentEntriesKeepTheirDetails() {
        var log = TranscriptLog()
        log.add("หนึ่ง", details: details)
        XCTAssertEqual(log.entries.first?.details, details)
    }
}
