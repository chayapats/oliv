import Foundation

/// "Report a wrong result" (#21): one History entry as a prefilled, public
/// GitHub issue (.github/ISSUE_TEMPLATE/wrong-result.yml).
///
/// OLIV sends nothing itself. This builds a link; the app shows the user what
/// it holds and lets them edit it first; Safari then opens GitHub, where nothing
/// is posted until the user submits. The report holds only the fields below:
/// the server address, API key, audio and server error text never reach it.
///
/// The Mac app has a twin in macos/OLIV/ResultReport.swift with the same field
/// ids and fitting rules.
public struct ResultReport: Equatable, Sendable {
    /// Issue-form field ids. Must match wrong-result.yml (a test checks).
    public enum Field: String, CaseIterable, Sendable {
        case typed, raw, meant, engine, cleanup
        case appVersion = "app-version"
        case osVersion = "os-version"
        case timing
    }

    public var title: String
    /// What OLIV produced, exactly.
    public var typed: String
    /// What speech-to-text heard (or the submitted text), before cleanup.
    public var raw: String
    /// What the user meant to say; they write this in the preview.
    public var meant: String
    public var engine: String
    public var cleanup: String
    public var appVersion: String
    public var osVersion: String
    public var timing: String

    public init(title: String, typed: String, raw: String, meant: String = "", engine: String,
                cleanup: String, appVersion: String, osVersion: String, timing: String) {
        self.title = title
        self.typed = typed
        self.raw = raw
        self.meant = meant
        self.engine = engine
        self.cleanup = cleanup
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.timing = timing
    }

    public static let newIssueURL = "https://github.com/chayapats/oliv/issues/new"
    public static let template = "wrong-result.yml"
    /// GitHub refuses very long URLs; stay well under its limit.
    public static let maxURLLength = 8_000
    /// Only these can be long; everything else is a short fixed label.
    public static let longFields: [Field] = [.typed, .raw, .meant]

    public func value(_ field: Field) -> String {
        switch field {
        case .typed: typed
        case .raw: raw
        case .meant: meant
        case .engine: engine
        case .cleanup: cleanup
        case .appVersion: appVersion
        case .osVersion: osVersion
        case .timing: timing
        }
    }

    /// The values that go into the link, with long text cut to fit and marked.
    public struct Fitted: Equatable, Sendable {
        public var values: [Field: String]
        /// Fields whose end was cut.
        public var truncated: Set<Field>
    }

    public func fitted(limit: Int = ResultReport.maxURLLength) -> Fitted {
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
    public var url: URL { Self.url(title: title, values: fitted().values) }

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
    public static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func truncationMarker(omitted: Int) -> String {
        "… [truncated by OLIV: \(omitted) more characters]"
    }

    /// The longest prefix, in whole characters (a Thai vowel or tone mark stays
    /// with its consonant), that fits `limit` encoded bytes with the marker.
    public static func truncate(_ text: String, toEncodedLength limit: Int) -> String {
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

// MARK: - From an iPhone History entry

extension ResultReport {
    /// Which server answered, without its address.
    public enum Server: Sendable {
        /// The server this build ships with.
        case `default`
        /// One the user entered.
        case custom
    }

    /// Build from one History entry. App, OS and server kind are passed in so
    /// this stays pure; nothing else is read.
    public static func iPhone(entry: HistoryEntry, appVersion: String, build: String,
                              systemVersion: String, server: Server) -> ResultReport {
        let reply = entry.reply
        let serverName = server == .default ? "default server" : "own server"
        let engine = entry.source == .cleanup
            ? "OLIV API, text cleanup (\(serverName))"
            : "OLIV API (\(serverName))"
        return ResultReport(
            title: "[Wrong result] iPhone · " + (entry.source == .cleanup ? "text cleanup" : "OLIV API"),
            typed: reply.hasText ? reply.finalText : "",
            raw: reply.raw,
            engine: engine,
            cleanup: cleanupLabel(reply),
            appVersion: "OLIV \(appVersion) (build \(build)) · iPhone",
            osVersion: "iOS \(systemVersion)",
            timing: timingLabel(entry))
    }

    /// The server's fixed codes only, never its error text.
    public static func cleanupLabel(_ reply: DictationReply) -> String {
        let gate = reply.gateReason.isEmpty ? "" : " (\(reply.gateReason))"
        if reply.noSpeech { return "No speech detected\(gate)" }
        if reply.cleanupError != nil { return "Language model failed, transcript kept\(gate)" }
        if reply.llmRan {
            let guardrail = reply.guardrailFlag.isEmpty ? "" : " · guardrail \(reply.guardrailFlag)"
            return "Language model ran\(gate)\(guardrail)"
        }
        return reply.gateReason.isEmpty ? "Off, or nothing to clean" : "Language model skipped\(gate)"
    }

    public static func timingLabel(_ entry: HistoryEntry) -> String {
        let reply = entry.reply
        if entry.source == .cleanup {
            return String(format: "cleanup %.1f s · total %.1f s", reply.tCleanup, entry.totalDuration)
        }
        return String(format: "%.1f s audio · speech-to-text %.1f s · cleanup %.1f s · total %.1f s",
                      entry.audioDuration, reply.tSTT, reply.tCleanup, entry.totalDuration)
    }
}
