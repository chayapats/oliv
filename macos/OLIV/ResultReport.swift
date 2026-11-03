// "Report a Wrong Result…" (#21): turn one recent dictation into a prefilled,
// public GitHub issue (.github/ISSUE_TEMPLATE/wrong-result.yml).
//
// OLIV sends nothing itself. This builds a URL; the preview window shows the
// user what it holds and lets them edit it; only their browser talks to GitHub,
// and nothing is posted until they submit there. The report is built from the
// fields below and nothing else: no server URL, API key, audio, or provider
// error text (those can echo private words) can reach it.
//
// The iPhone app has a twin in ios/Sources/OlivCore/ResultReport.swift. Both
// share the template's field ids and the same fitting rules.

import Foundation

struct ResultReport: Equatable {
    /// Issue-form field ids. Must match wrong-result.yml (a test checks).
    enum Field: String, CaseIterable {
        case mode, source, instruction, typed, raw, meant, engine, cleanup
        case appVersion = "app-version"
        case osVersion = "os-version"
        case timing
    }

    /// Which kind of result is reported; it decides the preview's labels.
    enum Kind: Equatable { case dictation, command, translation }

    var title: String
    var kind: Kind = .dictation
    /// "Dictation", or the voice-editing mode and what came of it.
    var mode: String = ""
    /// Command mode: the selected text it rewrote. Translation: the Thai that
    /// was translated, after cleanup. Empty for dictation.
    var source: String = ""
    /// Command mode: the spoken instruction as heard, after cleanup.
    var instruction: String = ""
    /// What OLIV typed, exactly as pasted: the result of an edit.
    var typed: String
    /// Speech-to-text output before cleanup and formatting (of the instruction,
    /// in Command mode).
    var raw: String
    /// What the user meant to say; they write this in the preview.
    var meant: String = ""
    var engine: String
    var cleanup: String
    var appVersion: String
    var osVersion: String
    var timing: String

    static let newIssueURL = "https://github.com/chayapats/oliv/issues/new"
    static let template = "wrong-result.yml"
    /// GitHub refuses very long URLs; stay well under its limit.
    static let maxURLLength = 8_000
    /// Only these can be long; everything else is a short fixed label.
    static let longFields: [Field] = [.source, .instruction, .typed, .raw, .meant]

    func value(_ field: Field) -> String {
        switch field {
        case .mode: return mode
        case .source: return source
        case .instruction: return instruction
        case .typed: return typed
        case .raw: return raw
        case .meant: return meant
        case .engine: return engine
        case .cleanup: return cleanup
        case .appVersion: return appVersion
        case .osVersion: return osVersion
        case .timing: return timing
        }
    }

    /// The values that go into the link, with long text cut to fit and marked.
    struct Fitted: Equatable {
        var values: [Field: String]
        /// Fields whose end was cut.
        var truncated: Set<Field>
    }

    func fitted(limit: Int = ResultReport.maxURLLength) -> Fitted {
        var values = Dictionary(uniqueKeysWithValues: Field.allCases.map { ($0, value($0)) })
        if Self.url(title: title, values: values).absoluteString.count <= limit {
            return Fitted(values: values, truncated: [])
        }
        // Water-fill the room left after the fixed part: a short field keeps all
        // of its text, and the long ones share what remains equally.
        var fixed = values
        for field in Self.longFields { fixed[field] = "" }
        var budget = max(0, limit - Self.url(title: title, values: fixed, keepEmpty: true).absoluteString.count)
        let costs = Self.longFields
            .map { ($0, Self.encode(values[$0] ?? "").count) }
            .sorted { $0.1 < $1.1 }
        var truncated = Set<Field>()
        for (index, (field, cost)) in costs.enumerated() {
            let share = budget / (costs.count - index)
            if cost <= share {
                budget -= cost
                continue
            }
            let cut = Self.truncate(values[field] ?? "", toEncodedLength: share)
            values[field] = cut
            budget -= Self.encode(cut).count
            truncated.insert(field)
        }
        return Fitted(values: values, truncated: truncated)
    }

    /// The prefilled new-issue link. Opening it posts nothing.
    var url: URL { Self.url(title: title, values: fitted().values) }

    static func url(title: String, values: [Field: String], keepEmpty: Bool = false) -> URL {
        var query = "template=\(encode(template))&title=\(encode(title))"
        for field in Field.allCases {
            let value = values[field] ?? ""
            guard keepEmpty || !value.isEmpty else { continue }
            query += "&\(field.rawValue)=\(encode(value))"
        }
        // Every non-ASCII and reserved character is percent-encoded, so this
        // always parses.
        return URL(string: "\(newIssueURL)?\(query)")!
    }

    /// RFC 3986 unreserved characters only. `+`, `&`, `=`, `#` and `%` are all
    /// escaped: GitHub reads a bare `+` as a space and `&` as the next field.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func truncationMarker(omitted: Int) -> String {
        "… [truncated by OLIV: \(omitted) more characters]"
    }

    /// The longest prefix, in whole characters (a Thai vowel or tone mark stays
    /// with its consonant), that fits `limit` encoded bytes with the marker.
    static func truncate(_ text: String, toEncodedLength limit: Int) -> String {
        let total = text.count
        // The marker for "all of it" has the most digits, so it bounds the rest.
        let markerCost = encode(truncationMarker(omitted: total)).count
        guard limit >= markerCost else { return "" }
        var kept = ""
        var used = markerCost
        for character in text {
            let cost = encode(String(character)).count
            guard used + cost <= limit else { break }
            kept.append(character)
            used += cost
        }
        return kept + truncationMarker(omitted: total - kept.count)
    }
}

// MARK: - From a Mac dictation

extension ResultReport {
    /// Build from one Recent entry. Takes the app and OS strings rather than
    /// reading them, so tests are hermetic; nothing else is read.
    static func mac(entry: TranscriptLog.Entry, appVersion: String, build: String,
                    macOSVersion: String) -> ResultReport {
        let details = entry.details
        let edit = details?.voiceEdit
        let engine = details?.engineID.map(engineLabel) ?? ""
        let kind: Kind = switch edit?.mode {
        case nil: .dictation
        case .command: .command
        case .translation: .translation
        }
        // Cleanup ran on the instruction, or on the Thai before translating.
        let cleanupOf = switch kind {
        case .dictation: ""
        case .command: "Instruction: "
        case .translation: "Thai transcript: "
        }
        let titleMode = switch kind {
        case .dictation: ""
        case .command: " · Command mode"
        case .translation: " · Translation"
        }
        return ResultReport(
            title: "[Wrong result] Mac\(titleMode)" + (engine.isEmpty ? "" : " · \(engine)"),
            kind: kind,
            mode: details.map { modeLabel($0.voiceEdit) } ?? "",
            source: edit?.selection ?? (kind == .translation ? edit?.heard ?? "" : ""),
            instruction: kind == .command ? edit?.heard ?? "" : "",
            typed: entry.text,
            raw: details?.raw ?? "",
            engine: engine,
            cleanup: details.map { cleanupOf + cleanupLabel($0) } ?? "",
            appVersion: "OLIV \(appVersion) (build \(build)) · Mac",
            osVersion: "macOS " + macOSVersion.replacingOccurrences(of: "Version ", with: ""),
            timing: details.map(timingLabel) ?? "")
    }

    /// "Dictation", "Command mode · edit applied", "Translation (Thai →
    /// English) · not translated (termLost), the transcript was pasted".
    static func modeLabel(_ edit: TranscriptLog.VoiceEdit?) -> String {
        guard let edit else { return "Dictation" }
        let reason = edit.flag.isEmpty || edit.flag == "ok" ? "" : " (\(edit.flag))"
        switch edit.mode {
        case .command:
            return edit.applied ? "Command mode · edit applied\(reason)" : "Command mode · not applied\(reason)"
        case .translation:
            return "Translation (Thai → English) · "
                + (edit.applied ? "translated\(reason)" : "not translated\(reason), the transcript was pasted")
        }
    }

    /// "On-device · Typhoon (typhoon-turbo-mlx)": the menu's label plus the id.
    /// The OLIV API is named, never its address.
    static func engineLabel(_ engineID: String) -> String {
        "\(DictationExecution(engineID: engineID).label) (\(engineID))"
    }

    static func cleanupLabel(_ details: TranscriptLog.Details) -> String {
        guard details.cleanup else { return "Off for this dictation" }
        let gate = details.gateReason.isEmpty ? "" : " (\(details.gateReason))"
        if details.cleanupFailed { return "On · language model failed, transcript kept\(gate)" }
        guard details.llmRan else { return "On · language model skipped\(gate)" }
        let guardrail = details.guardrailFlag.isEmpty ? "" : " · guardrail \(details.guardrailFlag)"
        return "On · language model ran\(gate)\(guardrail)"
    }

    static func timingLabel(_ details: TranscriptLog.Details) -> String {
        String(format: "%.1f s audio · speech-to-text %.1f s · cleanup %.1f s",
               details.audioSeconds, details.sttSeconds, details.cleanupSeconds)
    }
}
