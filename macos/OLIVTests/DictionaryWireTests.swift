// Dictionary wire tests.
//
// Local engines get the structured `dictionary` array (enabled entries as
// {word, correction?, starred}); the OLIV API applies its own synced copy, so
// its requests carry at most derived vocabulary/replacements (for servers
// without sync), truncated to the server caps. Hermetic body builders only.
import XCTest
@testable import OLIV

final class DictionaryWireTests: XCTestCase {
    // MARK: Local path (SidecarClient.dictateBody)

    func testLocalBodyContainsDictionaryArray() {
        let entries = [
            DictionaryEntry(word: "Grafana", correction: "grafannah", starred: true),
            DictionaryEntry(word: "OLIV"),
            DictionaryEntry(word: "Off", enabled: false),
        ]
        let body = SidecarClient.dictateBody(
            engine: SidecarClient.defaultEngine, pcmB64: "", cleanup: true,
            dictionary: entries)
        let wire = body["dictionary"] as? [[String: Any]]
        XCTAssertEqual(wire?.count, 2, "disabled entries are filtered from the passthrough")
        let pair = wire?.first(where: { ($0["word"] as? String) == "Grafana" })
        XCTAssertEqual(pair?["correction"] as? String, "grafannah")
        XCTAssertEqual(pair?["starred"] as? Bool, true)
        let vocabOnly = wire?.first(where: { ($0["word"] as? String) == "OLIV" })
        XCTAssertNotNil(vocabOnly)
        XCTAssertNil(vocabOnly?["correction"], "vocabulary-only entries omit the key, like Rust Option::None")
        XCTAssertEqual(vocabOnly?["starred"] as? Bool, false)
        XCTAssertNil(body["vocabulary"], "the bundled sidecar reads the dictionary directly")
        XCTAssertNil(body["replacements"])
    }

    func testLocalBodyOmitsDictionaryWhenEmpty() {
        let body = SidecarClient.dictateBody(
            engine: SidecarClient.defaultEngine, pcmB64: "", cleanup: true)
        XCTAssertNil(body["dictionary"], "defaults dictate stays byte-identical (omitted when empty)")
    }

    func testLocalBodyOmitsDictionaryWhenAllDisabled() {
        let body = SidecarClient.dictateBody(
            engine: SidecarClient.defaultEngine, pcmB64: "", cleanup: true,
            dictionary: [DictionaryEntry(word: "Off", enabled: false)])
        XCTAssertNil(body["dictionary"], "nothing enabled means nothing to send")
    }

    func testDictionaryWireEntriesFiltersDisabled() {
        let wire = SidecarClient.dictionaryWireEntries([
            DictionaryEntry(word: "On"),
            DictionaryEntry(word: "Off", enabled: false),
        ])
        XCTAssertEqual(wire.count, 1)
        XCTAssertEqual(wire.first?["word"] as? String, "On")
    }

    // MARK: Remote path (OLIVAPIClient.requestBody) — never `dictionary`

    func testRemoteBodyOmitsDictionary() throws {
        var options = DictationOptions(cleanup: true)
        options.dictionary = [DictionaryEntry(word: "Grafana", correction: "grafannah")]
        options.vocabulary = ["Grafana"]
        options.replacements = ["grafannah": "Grafana"]
        let data = try OLIVAPIClient.requestBody(samples: [0], options: options)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(body["dictionary"], "the server applies its own synced copy")
        XCTAssertEqual(Set(body.keys),
                       ["wav_b64", "cleanup", "remove_fillers", "thai_format", "vocabulary", "replacements"])
        XCTAssertEqual(body["vocabulary"] as? [String], ["Grafana"])
        XCTAssertEqual(body["replacements"] as? [String: String], ["grafannah": "Grafana"])
    }

    func testRemoteBodyCapsVocabularyEndToEnd() throws {
        var options = DictationOptions(cleanup: true)
        options.vocabulary = (0..<200).map { "term\($0)" }
        let data = try OLIVAPIClient.requestBody(samples: [0], options: options)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((body["vocabulary"] as? [String])?.count, OLIVAPIClient.maxRemoteVocabularyEntries)
        XCTAssertNil(body["dictionary"])
    }

    // MARK: Remote caps (OLIVAPIClient.cappedRemoteParams)

    func testRemoteCapsVocabularyTo128PreservingOrder() {
        let vocab = (0..<200).map { "term\($0)" }
        let capped = OLIVAPIClient.cappedRemoteParams(vocabulary: vocab, replacements: [:])
        XCTAssertEqual(capped.vocabulary.count, 128)
        XCTAssertEqual(capped.droppedVocabulary, 72)
        XCTAssertEqual(capped.vocabulary.first, "term0", "starred-first input order is preserved")
        XCTAssertEqual(capped.vocabulary.last, "term127")
        XCTAssertEqual(capped.droppedReplacements, 0)
    }

    func testRemoteDrops300ByteThaiWord() {
        // Thai runs 3 bytes/char in UTF-8: a 100-char word is ~300 bytes and
        // MUST be dropped for remote (documented server cap: 256 bytes/entry).
        let thai100 = String(repeating: "ก", count: 100)
        XCTAssertEqual(thai100.utf8.count, 300)
        let capped = OLIVAPIClient.cappedRemoteParams(vocabulary: [thai100, "ok"], replacements: [:])
        XCTAssertEqual(capped.vocabulary, ["ok"])
        XCTAssertEqual(capped.droppedVocabulary, 1)
    }

    func testRemoteDropsOverlongReplacement() {
        let long = String(repeating: "x", count: 300)
        let capped = OLIVAPIClient.cappedRemoteParams(vocabulary: [], replacements: [
            "ok": "fine",
            "bad-key": long,
            "loooong-" + String(repeating: "k", count: 300): "v",
            "": "v",
            "k": "",
        ])
        XCTAssertEqual(capped.replacements, ["ok": "fine"])
        XCTAssertEqual(capped.droppedReplacements, 4,
                       "overlong value, overlong key, empty key, empty value")
    }

    func testRemoteCapsReplacementsTo128Pairs() {
        var table: [String: String] = [:]
        for i in 0..<129 { table["k\(i)"] = "v\(i)" }
        let capped = OLIVAPIClient.cappedRemoteParams(vocabulary: [], replacements: table)
        XCTAssertEqual(capped.replacements.count, 128)
        XCTAssertEqual(capped.droppedReplacements, 1)
        XCTAssertEqual(capped.droppedVocabulary, 0)
    }

    func testByteCountUsesUTF8() {
        // "ก" (U+0E01) is 3 bytes in UTF-8: 85 chars = 255 bytes (kept),
        // 86 chars = 258 bytes (dropped). A char-count cap would keep both.
        let keep = String(repeating: "ก", count: 85)
        let drop = String(repeating: "ก", count: 86)
        XCTAssertEqual(keep.utf8.count, 255)
        XCTAssertEqual(drop.utf8.count, 258)
        let capped = OLIVAPIClient.cappedRemoteParams(vocabulary: [keep, drop], replacements: [:])
        XCTAssertEqual(capped.vocabulary, [keep])
        XCTAssertEqual(capped.droppedVocabulary, 1)
        // ASCII boundary: exactly 256 UTF-8 bytes kept, 257 dropped.
        let ascii256 = String(repeating: "a", count: 256)
        let ascii257 = String(repeating: "a", count: 257)
        let ascii = OLIVAPIClient.cappedRemoteParams(vocabulary: [ascii256, ascii257], replacements: [:])
        XCTAssertEqual(ascii.vocabulary, [ascii256])
        XCTAssertEqual(ascii.droppedVocabulary, 1)
    }

    func testStarredFirstSurvivesTruncation() {
        var entries = [DictionaryEntry(word: "star", starred: true)]
        entries += (0..<200).map { DictionaryEntry(word: "term\($0)") }
        let vocab = DictionaryEntry.vocabulary(from: entries)
        XCTAssertEqual(vocab.first, "star", "derivation is starred-first")
        let capped = OLIVAPIClient.cappedRemoteParams(vocabulary: vocab, replacements: [:])
        XCTAssertEqual(capped.vocabulary.count, 128)
        XCTAssertEqual(capped.vocabulary.first, "star", "the starred term survives truncation")
        XCTAssertEqual(capped.droppedVocabulary, vocab.count - 128)
    }
}
