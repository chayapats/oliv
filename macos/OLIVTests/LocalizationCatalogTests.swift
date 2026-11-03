// The Mac interface ships in English and Thai (OLIV/Localizable.xcstrings,
// OLIV/InfoPlist.xcstrings). These keep the catalog honest:
//
//   • every catalog entry is still used by the app's sources (no stale keys),
//     and strings added to the sources without a catalog entry are listed
//     (a failure with OLIV_REQUIRE_TRANSLATIONS=1, see below);
//   • every entry has a Thai translation with the same placeholders, unless it
//     is marked "don't translate" (product names, pure formats);
//   • the built app really carries the compiled Thai tables, and English
//     singulars still read "1 word", not "1 words".
//
// The extracted strings come from the .stringsdata files the compiler writes
// next to the app's object files (SWIFT_EMIT_LOC_STRINGS = YES in project.yml).

import XCTest
@testable import OLIV

final class LocalizationCatalogTests: XCTestCase {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("OLIV")

    private struct Entry {
        let key: String
        let json: [String: Any]
        var shouldTranslate: Bool { json["shouldTranslate"] as? Bool ?? true }
        var localizations: [String: Any] { json["localizations"] as? [String: Any] ?? [:] }
    }

    private func catalog(_ name: String) throws -> [Entry] {
        let url = Self.appSources.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        return strings.map { Entry(key: $0.key, json: $0.value) }
    }

    /// Thai values of an entry: one string, or every plural/device variant.
    private func thaiValues(_ entry: Entry) -> [String] {
        guard let th = entry.localizations["th"] as? [String: Any] else { return [] }
        var values: [String] = []
        func collect(_ node: [String: Any]) {
            if let unit = node["stringUnit"] as? [String: Any] {
                if unit["state"] as? String == "translated", let v = unit["value"] as? String, !v.isEmpty {
                    values.append(v)
                } else {
                    values.append("")   // present but untranslated: reported as empty
                }
            }
            for case let group as [String: Any] in (node["variations"] as? [String: Any])?.values.map({ $0 }) ?? [] {
                for case let variant as [String: Any] in group.values { collect(variant) }
            }
        }
        collect(th)
        return values
    }

    /// Format placeholders in argument order: "%1$@ %2$lld" and "%@ %lld" both
    /// give ["@", "lld"]. "%%" is a literal percent sign, not a placeholder.
    static func placeholders(_ s: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?(lld|llu|ld|lu|d|u|@|f|\.\d+f)|%%"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var sequential = 0
        var found: [(Int, String)] = []
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let typeRange = Range(m.range(at: 2), in: s) else { continue }   // %%
            let index: Int
            if let r = Range(m.range(at: 1), in: s), let n = Int(s[r]) {
                index = n
            } else {
                sequential += 1
                index = sequential
            }
            found.append((index, String(s[typeRange])))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func testPlaceholderParsing() {
        XCTAssertEqual(Self.placeholders("Last: %@ · %@s · %lld chars"), ["@", "@", "lld"])
        XCTAssertEqual(Self.placeholders("ดาวน์โหลด %2$@ ไม่สำเร็จ: %1$lld"), ["lld", "@"])
        XCTAssertEqual(Self.placeholders("100%% done"), [])
    }

    func testEveryStringHasAThaiTranslationWithTheSamePlaceholders() throws {
        let entries = try catalog("Localizable.xcstrings")
        XCTAssertGreaterThan(entries.count, 300, "the Mac interface has a few hundred strings")
        var untranslated: [String] = []
        for entry in entries where entry.shouldTranslate {
            let values = thaiValues(entry)
            if values.isEmpty || values.contains(where: \.isEmpty) {
                untranslated.append(entry.key)
                continue
            }
            for value in values {
                XCTAssertEqual(Self.placeholders(value), Self.placeholders(entry.key),
                               "Thai “\(value)” must keep the placeholders of “\(entry.key)”")
            }
        }
        XCTAssertEqual(untranslated, [], "translate these into Thai in macos/OLIV/Localizable.xcstrings")
    }

    func testNoStaleCatalogEntries() throws {
        let extracted = try extractedKeys()
        let entries = try catalog("Localizable.xcstrings")
        let manual = Set(entries.filter { $0.json["extractionState"] as? String == "manual" }.map(\.key))
        let stale = entries.filter { $0.json["extractionState"] as? String == "stale" }.map(\.key)
        XCTAssertEqual(stale, [], "remove stale entries from macos/OLIV/Localizable.xcstrings")
        let inCatalog = Set(entries.map(\.key))
        XCTAssertEqual(inCatalog.subtracting(extracted).subtracting(manual).sorted(), [],
                       "no longer used in the app's sources: remove them from macos/OLIV/Localizable.xcstrings")
    }

    /// New interface strings show in English until they get a catalog entry
    /// with Thai. Listed in the test log; with OLIV_REQUIRE_TRANSLATIONS=1
    /// (TEST_RUNNER_OLIV_REQUIRE_TRANSLATIONS=1 for xcodebuild) they fail.
    /// Not a failure by default so that changes in flight can land first and
    /// be translated together afterwards.
    func testEveryInterfaceStringIsInTheCatalog() throws {
        let inCatalog = Set(try catalog("Localizable.xcstrings").map(\.key))
        let missing = try extractedKeys().subtracting(inCatalog).sorted()
        guard !missing.isEmpty else { return }
        let message = "English-only interface strings, add them with Thai to macos/OLIV/Localizable.xcstrings: "
            + missing.map { "“\($0)”" }.joined(separator: ", ")
        if ProcessInfo.processInfo.environment["OLIV_REQUIRE_TRANSLATIONS"] == "1" {
            XCTFail(message)
        } else {
            print("warning: \(message)")
        }
    }

    /// Keys of the "Localizable" table in the .stringsdata the compiler wrote
    /// for the OLIV app target, skipping leftovers of deleted source files.
    private func extractedKeys() throws -> Set<String> {
        // Bundle.main is the test host: <Derived>/Build/Products/<Config>/OLIV.app
        let products = Bundle.main.bundleURL.deletingLastPathComponent()
        let configuration = products.lastPathComponent
        let objects = products.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/OLIV.build/\(configuration)/OLIV.build/Objects-normal")
        let files = (FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "stringsdata" }
        XCTAssertFalse(files.isEmpty, "no .stringsdata under \(objects.path); is SWIFT_EMIT_LOC_STRINGS on?")
        var keys = Set<String>()
        for file in files {
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            if let source = root["source"] as? String, !FileManager.default.fileExists(atPath: source) { continue }
            let tables = root["tables"] as? [String: [[String: Any]]] ?? [:]
            for item in tables["Localizable"] ?? [] {
                if let key = item["key"] as? String { keys.insert(key) }
            }
        }
        return keys
    }

    func testThaiSearchKeywordsKeepTheEnglishOnes() throws {
        // Settings search matches the localized keywords; English words must
        // keep working on a Thai Mac.
        let keywords = try catalog("Localizable.xcstrings").filter {
            ($0.json["comment"] as? String)?.hasPrefix("Settings search keywords") == true
        }
        XCTAssertEqual(keywords.count, SettingsPage.allCases.count)
        for entry in keywords {
            let thai = Set(thaiValues(entry).joined(separator: " ").split(separator: " "))
            for word in entry.key.split(separator: " ") {
                XCTAssertTrue(thai.contains(word), "Thai search keywords for “\(entry.key)” lost “\(word)”")
            }
        }
    }

    func testBuiltAppCarriesTheThaiTable() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                subdirectory: nil, localization: "th"),
                                "OLIV.app has no th.lproj/Localizable.strings")
        let compiled = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        for entry in try catalog("Localizable.xcstrings") where entry.shouldTranslate {
            let th = entry.localizations["th"] as? [String: Any]
            guard let value = (th?["stringUnit"] as? [String: Any])?["value"] as? String else { continue }
            XCTAssertEqual(compiled[entry.key], value, "compiled Thai for “\(entry.key)”")
        }
        XCTAssertEqual(Bundle.main.localizations.contains("th"), true)
    }

    func testEnglishPluralsKeepTheirSingular() throws {
        let en = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        func format(_ key: String, _ args: CVarArg...) -> String {
            String(format: en.localizedString(forKey: key, value: nil, table: nil),
                   locale: Locale(identifier: "en_US"), arguments: args)
        }
        XCTAssertEqual(format("Imported %lld words.", 1), "Imported 1 word.")
        XCTAssertEqual(format("Imported %lld words.", 3), "Imported 3 words.")
        XCTAssertEqual(format("Imported %lld words; %lld rows were skipped (invalid or duplicate).", 1, 2),
                       "Imported 1 word; 2 rows were skipped (invalid or duplicate).")
        XCTAssertEqual(format("Imported %lld words; %lld rows were skipped (invalid or duplicate).", 4, 1),
                       "Imported 4 words; 1 row was skipped (invalid or duplicate).")
        XCTAssertEqual(format("No new words — %lld rows were skipped (invalid or already in your dictionary).", 1),
                       "No new words — 1 row was skipped (invalid or already in your dictionary).")
        XCTAssertEqual(format("API cooldown — wait %lld seconds.", 1), "API cooldown — wait 1 second.")
    }

    func testThaiResolvesForModelStrings() {
        // String(localized:) in model code resolves in the app's language; a
        // Thai lookup of the same resources must give Thai.
        let th = Locale(identifier: "th")
        XCTAssertEqual(String(localized: LocalizedStringResource("Transcribing…", locale: th, bundle: .main)),
                       "กำลังถอดเสียง…")
        XCTAssertEqual(String(localized: LocalizedStringResource("Imported \(2) words.", locale: th, bundle: .main)),
                       "นำเข้าแล้ว 2 คำ")
    }

    func testMicrophonePromptIsTranslatedAndMatchesInfoPlist() throws {
        let entry = try XCTUnwrap(try catalog("InfoPlist.xcstrings").first { $0.key == "NSMicrophoneUsageDescription" })
        let en = ((entry.localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        XCTAssertEqual(en, Bundle.main.infoDictionary?["NSMicrophoneUsageDescription"] as? String,
                       "InfoPlist.xcstrings' English must match NSMicrophoneUsageDescription in project.yml")
        XCTAssertFalse(thaiValues(entry).isEmpty)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "InfoPlist", withExtension: "strings",
                                                subdirectory: nil, localization: "th"))
        let compiled = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        XCTAssertEqual(compiled["NSMicrophoneUsageDescription"], thaiValues(entry).first)
    }
}
