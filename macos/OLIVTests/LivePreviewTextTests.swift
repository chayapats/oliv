import XCTest
@testable import OLIV

/// Settled and tentative words (#46), and the tail of a line.
final class LivePreviewLineTests: XCTestCase {
    func testWithNothingToAgreeWithEverythingIsTentative() {
        XCTAssertEqual(LivePreview.line(previous: nil, current: "สวัสดีครับ"),
                       LivePreviewLine(settled: "", tentative: "สวัสดีครับ"))
        XCTAssertEqual(LivePreview.line(previous: "", current: "hello"),
                       LivePreviewLine(settled: "", tentative: "hello"))
    }

    func testOnlyWholeWordsBothPreviewsAgreeOnSettle() {
        // Both start "deploy the new…": "new" is only half of "newest".
        XCTAssertEqual(LivePreview.line(previous: "deploy the new", current: "deploy the newest build"),
                       LivePreviewLine(settled: "deploy the", tentative: " newest build"))
        // Thai has no spaces: the word breaker still keeps "ครับ" whole.
        XCTAssertEqual(LivePreview.line(previous: "สวัสดีคะ", current: "สวัสดีครับ"),
                       LivePreviewLine(settled: "สวัสดี", tentative: "ครับ"))
    }

    func testAgreementToTheEndSettlesEverything() {
        XCTAssertEqual(LivePreview.line(previous: "ช่วย deploy ให้หน่อย", current: "ช่วย deploy"),
                       LivePreviewLine(settled: "ช่วย deploy", tentative: ""))
        XCTAssertEqual(LivePreview.line(previous: "same words", current: "same words"),
                       LivePreviewLine(settled: "same words", tentative: ""))
    }

    func testAChangedStartSettlesNothing() {
        XCTAssertEqual(LivePreview.line(previous: "พรุ่งนี้ประชุม", current: "วันนี้ประชุม"),
                       LivePreviewLine(settled: "", tentative: "วันนี้ประชุม"))
    }

    func testWhenTheWindowSlidTheAgreementStartsLaterInThePreviousPreview() {
        XCTAssertEqual(LivePreview.line(previous: "one two three four", current: "three four five"),
                       LivePreviewLine(settled: "three four", tentative: " five"))
    }

    func testTheTailOfALineKeepsWhatIsLeftOfEachPart() {
        let short = LivePreviewLine(settled: "  ช่วย deploy", tentative: " เวอร์ชันใหม่ \n")
        XCTAssertEqual(LivePreview.tail(short), LivePreviewLine(settled: "ช่วย deploy", tentative: " เวอร์ชันใหม่"))

        let words = (1...40).map { "word\($0)" }
        let settled = words.prefix(36).joined(separator: " "), tentative = " " + words.suffix(4).joined(separator: " ")
        let cut = LivePreview.tail(LivePreviewLine(settled: settled, tentative: tentative), limit: 40)
        XCTAssertTrue(cut.settled.hasPrefix("…"), "\(cut)")
        XCTAssertEqual(cut.tentative, tentative)
        XCTAssertLessThanOrEqual(cut.text.count, 40)
        XCTAssertEqual(cut.text, LivePreview.tail(settled + tentative, limit: 40), "the same cut as plain text")

        // The cut took every settled word: the ellipsis goes on the tentative part.
        let mostlyNew = LivePreview.tail(LivePreviewLine(settled: "old", tentative: " " + words.joined(separator: " ")),
                                         limit: 30)
        XCTAssertEqual(mostlyNew.settled, "")
        XCTAssertTrue(mostlyNew.tentative.hasPrefix("…"), "\(mostlyNew)")
    }

    func testThaiMarksNeverLoseTheirConsonantAtTheSettledEdge() {
        let settled = String(repeating: "กี่ญั้ฤๅปุ่ ", count: 10)
        let tentative = "ผู้ใหญ่ปู่ย่า"
        for limit in 5...40 {
            let cut = LivePreview.tail(LivePreviewLine(settled: settled, tentative: tentative), limit: limit)
            XCTAssertLessThanOrEqual(cut.text.count, limit)
            for part in [cut.settled, cut.tentative] where !part.isEmpty {
                let first = part.unicodeScalars.first!
                XCTAssertNotEqual(first.properties.generalCategory, .nonspacingMark, "limit \(limit): \(cut)")
            }
            XCTAssertTrue((settled + tentative).hasSuffix(cut.text.replacingOccurrences(of: "…", with: "")), "\(cut)")
        }
    }
}

/// The `preview` request and reply (#46).
final class LivePreviewRequestTests: XCTestCase {
    func testThePreviewCarriesTheDictationsCleanupOptionsButNoScreenNames() {
        var options = DictationOptions(cleanup: true, removeFillers: true, thaiFormat: true,
                                       dictionary: [DictionaryEntry(word: "Grafana", correction: "กราฟาน่า")])
        options.screenText = ["on screen"]
        let body = SidecarClient.previewBody(engine: "typhoon-turbo-mlx", pcmB64: "AAAA", seq: 7, cleanup: options)
        XCTAssertEqual(body["cmd"] as? String, "preview")
        XCTAssertEqual(body["preview_seq"] as? Int, 7)
        XCTAssertEqual(body["pcm_b64"] as? String, "AAAA")
        XCTAssertEqual(body["light_cleanup"] as? Bool, true)
        XCTAssertEqual(body["cleanup"] as? Bool, true)
        XCTAssertEqual(body["thai_format"] as? Bool, true)
        XCTAssertEqual(body["remove_fillers"] as? Bool, true)
        XCTAssertEqual((body["dictionary"] as? [[String: Any]])?.first?["word"] as? String, "Grafana")
        XCTAssertNil(body["screen_text"])

        let raw = SidecarClient.previewBody(engine: "typhoon-turbo-mlx", pcmB64: "AAAA", seq: 8, cleanup: nil)
        XCTAssertEqual(Set(raw.keys), ["cmd", "engine", "pcm_b64", "preview_seq"])
    }

    func testTheReplysTimingsAndRawTextAreRead() {
        let result = SidecarClient.previewResult([
            "ok": true, "text": "deploy เสร็จ", "raw": "ดีพลอย เสร็จ", "t_sidecar": 0.2, "t_stt": 0.19, "t_clean": 0.001,
            "timings": ["mel": 0.002, "encode": 0.08, "decode": 0.1, "frames": 800],
        ])
        XCTAssertEqual(result.text, "deploy เสร็จ")
        XCTAssertEqual(result.raw, "ดีพลอย เสร็จ")
        XCTAssertNil(result.skipped)
        XCTAssertEqual(result.timings["sidecar"], 0.2)
        XCTAssertEqual(result.timings["encode"], 0.08)
        XCTAssertEqual(result.timings["frames"], 800)
        let skipped = SidecarClient.previewResult(["ok": true, "text": "", "skipped": "cancelled"])
        XCTAssertEqual(skipped.skipped, "cancelled")
        XCTAssertEqual(skipped.timings, [:])
    }
}

/// The inference helper's preview-only encode length and decode guards
/// (OLIVInference/Whisper/PreviewDecodeGuard.swift, compiled into the tests).
final class PreviewDecodeGuardTests: XCTestCase {
    func testTheEncoderRunsOnTheAudioThereIsNotThe30SecondWindow() {
        // A floor of 30 s is the full window, whatever the audio.
        for content in [1, 300, 2999, 3000] {
            XCTAssertEqual(PreviewDecodeGuard.encoderFrames(content: content, floorSeconds: 30, tailSeconds: 0), 3000)
        }
        // max(audio + tail, floor), in whole half seconds, at most 30 s.
        XCTAssertEqual(PreviewDecodeGuard.encoderFrames(content: 300, floorSeconds: 8, tailSeconds: 1), 800)
        XCTAssertEqual(PreviewDecodeGuard.encoderFrames(content: 750, floorSeconds: 8, tailSeconds: 1), 850)
        XCTAssertEqual(PreviewDecodeGuard.encoderFrames(content: 301, floorSeconds: 0, tailSeconds: 0), 350)
        XCTAssertEqual(PreviewDecodeGuard.encoderFrames(content: 2950, floorSeconds: 8, tailSeconds: 1), 3000)
        XCTAssertEqual(PreviewDecodeGuard.encoderFrames(content: 0, floorSeconds: 0, tailSeconds: 0), 50)
    }

    func testTheTokenLimitGrowsWithTheAudio() {
        XCTAssertEqual(PreviewDecodeGuard.tokenLimit(audioFrames: 100), 49)    // 1 s
        XCTAssertEqual(PreviewDecodeGuard.tokenLimit(audioFrames: 1200), 324)  // 12 s
    }

    func testASentenceSaidAgainIsCutWhereTheRepeatStarts() {
        let ts = 50_000                      // timestamps from here up
        let sentence = Array(100..<112)      // 12 text tokens
        let tokens = [ts] + sentence + [ts + 50, ts + 50] + sentence.prefix(10)
        XCTAssertEqual(PreviewDecodeGuard.repeatStart(tokens, timestampBegin: ts, span: 10), 15)
        // Fewer than `span` tokens again, or text that never repeats: go on.
        XCTAssertNil(PreviewDecodeGuard.repeatStart([ts] + sentence + [ts + 50, ts + 50] + sentence.prefix(9),
                                                    timestampBegin: ts, span: 10))
        XCTAssertNil(PreviewDecodeGuard.repeatStart([ts] + Array(100..<140), timestampBegin: ts, span: 10))
        // Only checked when a text token was just added.
        XCTAssertNil(PreviewDecodeGuard.repeatStart(tokens + [ts + 60], timestampBegin: ts, span: 10))
    }
}
