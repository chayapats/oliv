// Auto-learn CANDIDATE INBOX — proposal + approval only (Wispr-parity MVP).
//
// NOTHING is learned in the background: the pure `propose*` functions below
// only SUGGEST candidates (undo→redictate diffs, and near-misses of a newly
// added word in recent transcripts). Every candidate requires user approval in Settings ›
// Dictionary › Auto-learn inbox before it becomes a DictionaryEntry. Text-only
// (zero VRAM, zero new models), offline-first (no network, no keychain).

import Foundation

/// One unapproved auto-learn suggestion. Approximates a future DictionaryEntry:
/// `correction == nil` = vocabulary-only, otherwise a mishearing→word pair.
/// Persisted as JSON under `oliv.autoLearnCandidates` (see OLIVSettings).
struct AutoLearnCandidate: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    /// The spelling OLIV should produce.
    var word: String
    /// What STT misheard (undo→redictate) — nil for explicit word-only adds.
    var correction: String?
    var source: DictionarySource = .autoLearn
    /// Provenance: `reasonUndoRedictate` or `reasonAddWord`.
    var reason: String
    var createdAt: Date
    /// How many times this pair was observed (repeat sightings bump it).
    var baseCount: Int

    init(id: UUID = UUID(), word: String, correction: String? = nil,
         source: DictionarySource = .autoLearn, reason: String,
         createdAt: Date = Date(), baseCount: Int = 1) {
        self.id = id
        self.word = word
        self.correction = correction
        self.source = source
        self.reason = reason
        self.createdAt = createdAt
        self.baseCount = baseCount
    }

    static let reasonUndoRedictate = "undo-redictate"
    /// A word just added to the dictionary; scan recent transcripts for what
    /// STT actually produced so the user can approve a correction pair.
    static let reasonAddWord = "add-word"

    /// Full identity key — same scheme as DictionaryEntry so inbox candidates
    /// dedupe 1:1 against existing entries.
    func dedupeKey() -> String {
        DictionaryEntry(word: word, correction: correction).dedupeKey()
    }
}

enum AutoLearn {
    /// Whole-string pair fallback for spaceless scripts (Thai): only when BOTH
    /// sides are short — longer pairs are too noisy to suggest blindly.
    static let spacelessMaxLength = 40

    /// Token-diff the undone paste (`oldFinal`) against the re-dictated paste
    /// (`newFinal`); each differing segment becomes a correction→word candidate
    /// (word = what the user re-dictated). A pair is emitted ONLY when both
    /// sides pass DictionaryEntry validation AND neither side hits the
    /// skip-list. Returns [] (never nil) when there is nothing worth proposing.
    static func proposeFromUndoRedo(oldFinal: String, newFinal: String) -> [AutoLearnCandidate] {
        let old = oldFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, old != new else { return [] }

        let oldHasSpace = old.contains(where: \.isWhitespace)
        let newHasSpace = new.contains(where: \.isWhitespace)
        if !oldHasSpace, !newHasSpace {
            // Spaceless script (Thai, CJK): no token boundary exists, so the
            // whole-string pair is the only signal — and only when short.
            guard old.count <= spacelessMaxLength, new.count <= spacelessMaxLength else {
                return []
            }
            return makeCandidate(word: new, correction: old, reason: AutoLearnCandidate.reasonUndoRedictate)
                .map { [$0] } ?? []
        }
        // Mixed (one side spaced, the other not): unreliable alignment — emit nothing.
        guard oldHasSpace, newHasSpace else { return [] }

        let oldTokens = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let newTokens = new.split(whereSeparator: \.isWhitespace).map(String.init)
        if oldTokens.count == newTokens.count {
            // Aligned: one candidate per differing position.
            var out: [AutoLearnCandidate] = []
            var seen = Set<String>()
            for (o, n) in zip(oldTokens, newTokens) where o != n {
                guard let c = makeCandidate(word: n, correction: o,
                                            reason: AutoLearnCandidate.reasonUndoRedictate),
                      seen.insert(c.dedupeKey()).inserted else { continue }
                out.append(c)
            }
            return out
        }
        // Unaligned (insertion/deletion alongside the fix): strip the common
        // prefix/suffix and propose the differing middles as ONE pair, only
        // when both middles are non-empty.
        var prefix = 0
        while prefix < min(oldTokens.count, newTokens.count),
              oldTokens[prefix] == newTokens[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldTokens.count, newTokens.count) - prefix,
              oldTokens[oldTokens.count - 1 - suffix] == newTokens[newTokens.count - 1 - suffix] {
            suffix += 1
        }
        let oldMid = oldTokens[prefix..<(oldTokens.count - suffix)].joined(separator: " ")
        let newMid = newTokens[prefix..<(newTokens.count - suffix)].joined(separator: " ")
        guard !oldMid.isEmpty, !newMid.isEmpty else { return [] }
        return makeCandidate(word: newMid, correction: oldMid,
                             reason: AutoLearnCandidate.reasonUndoRedictate).map { [$0] } ?? []
    }

    /// A word the user JUST added (word-only): scan recent transcripts for
    /// what STT actually produced so the user can approve a correction pair
    /// with one tap instead of typing both sides. Returns nil when there is
    /// nothing worth proposing: the word already appears correctly, no
    /// near-miss span exists, or everything near is skip-listed.
    ///
    /// Matching is intentionally conservative (same-script near-miss only):
    /// lowercased Levenshtein distance within threshold AND equal first
    /// characters. Cross-script pairs (Thai mishearing → English word) cannot
    /// match by edit distance — those still need a manual correction or the
    /// undo→redictate flow, which sees both sides explicitly.
    static func proposeCorrectionForNewWord(word: String,
                                            recentTexts: [String]) -> AutoLearnCandidate? {
        guard let pair = DictionaryEntry.normalized(word: word, correction: nil),
              !pair.word.contains(where: \.isWhitespace) else { return nil }
        let target = pair.word
        let folded = target.lowercased()
        guard !recentTexts.isEmpty else { return nil }
        var best: (token: String, dist: Int)?
        for rawText in recentTexts {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let tokens: [String] = text.contains(where: \.isWhitespace)
                ? text.split(whereSeparator: \.isWhitespace).map(String.init)
                : [text]
            for token in tokens {
                // Already correct here — skip this token, keep scanning:
                // STT is inconsistent, so a mishearing elsewhere is still
                // worth mapping.
                if tokenForCompare(token) == folded { continue }
                guard isNearMiss(token: token, targetFolded: folded) else { continue }
                guard !isSkipped(token) else { continue }
                let d = levenshtein(tokenForCompare(token), folded)
                if best == nil || d < best!.dist { best = (token, d) }
            }
        }
        guard let hit = best else {
            // No same-script near-miss — but an alphanumeric term
            // (SHA256, GPT4) is often spoken as letters + Thai numerals.
            if let parts = alphaNumericParts(target),
               let phrase = findSpokenNumeralPhrase(prefix: parts.prefix, digits: parts.digits,
                                                    recentTexts: recentTexts) {
                return makeCandidate(word: target, correction: phrase,
                                     reason: AutoLearnCandidate.reasonAddWord)
            }
            return nil
        }
        return makeCandidate(word: target, correction: hit.token,
                             reason: AutoLearnCandidate.reasonAddWord)
    }

    /// Lowercased comparison form (Thai/CJK have no case; Latin folds).
    private static func tokenForCompare(_ s: String) -> String { s.lowercased() }

    // MARK: Alphanumeric-term mapping (the "SHA สองห้าหก → SHA256" class)

    /// Thai number words for the alphanumeric-term rule below.
    static let thaiNumeralWords: Set<String> = [
        "ศูนย์", "หนึ่ง", "เอ็ด", "สอง", "สาม", "สี่", "ห้า", "หก", "เจ็ด",
        "แปด", "เก้า", "สิบ", "ยี่", "ร้อย", "พัน", "หมื่น", "แสน", "ล้าน", "จุด",
    ]

    /// Words like SHA256/GPT4/H100: Latin letters followed by digits. For
    /// these, speakers typically say the letter part in English and the
    /// digits in Thai ("SHA สองห้าหก") — which edit distance can never match
    /// cross-script, so this rule looks for the letter prefix glued to Thai
    /// numeral words instead.
    static func alphaNumericParts(_ word: String) -> (prefix: String, digits: String)? {
        let t = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return nil }
        let letters = t.prefix(while: { $0.isASCII && $0.isLetter })
        let rest = t.dropFirst(letters.count)
        guard letters.count >= 1, !rest.isEmpty,
              rest.allSatisfy({ $0.isNumber }) else { return nil }
        return (String(letters), String(rest))
    }

    /// Greedy longest-first segmentation of a spaceless string into Thai
    /// numeral words ("สองห้าหก" → ["สอง","ห้า","หก"]). Nil unless the WHOLE
    /// string segments — a partial match is not a number phrase.
    static func segmentThaiNumerals(_ s: String) -> [String]? {
        guard !s.isEmpty else { return nil }
        let ordered = thaiNumeralWords.sorted { $0.count > $1.count }
        var out: [String] = []
        var rest = s
        while !rest.isEmpty {
            guard let w = ordered.first(where: { rest.hasPrefix($0) }) else { return nil }
            out.append(w)
            rest = String(rest.dropFirst(w.count))
        }
        return out
    }

    /// What a run of Thai numeral words can mean as digits: read digit by
    /// digit ("สองห้าหก" → 256, "หนึ่งศูนย์ศูนย์" → 100) and as a positional
    /// number ("สองร้อยห้าสิบหก" → 256, "ยี่สิบเอ็ด" → 21). Empty when the
    /// run is not a number (or uses จุด, which an integer suffix cannot match).
    static func thaiNumeralReadings(_ s: String) -> Set<String> {
        guard let words = segmentThaiNumerals(s), !words.contains("จุด") else { return [] }
        let digit: [String: Int] = ["ศูนย์": 0, "หนึ่ง": 1, "เอ็ด": 1, "สอง": 2, "ยี่": 2, "สาม": 3,
                                    "สี่": 4, "ห้า": 5, "หก": 6, "เจ็ด": 7, "แปด": 8, "เก้า": 9]
        let unit: [String: Int] = ["สิบ": 10, "ร้อย": 100, "พัน": 1_000, "หมื่น": 10_000, "แสน": 100_000]
        var readings = Set<String>()
        if words.allSatisfy({ digit[$0] != nil && $0 != "เอ็ด" && $0 != "ยี่" }) {
            readings.insert(words.map { String(digit[$0]!) }.joined())
        }
        var total = 0, block = 0, pending: Int?
        var valid = true
        // Bounded far below Int.max, so no sum or product below can overflow;
        // no word's digit suffix is that long a number anyway.
        let ceiling = 1_000_000_000_000_000
        for w in words {
            guard total <= ceiling, block <= ceiling else { valid = false; break }
            if let d = digit[w] {
                if pending != nil { valid = false; break }
                pending = d
            } else if let u = unit[w] {
                block += (pending ?? 1) * u
                pending = nil
            } else if w == "ล้าน" {
                let (scaled, overflow) = (total + block + (pending ?? (block == 0 ? 1 : 0)))
                    .multipliedReportingOverflow(by: 1_000_000)
                if overflow { valid = false; break }  // "ล้านล้านล้าน…": no digits of ours
                total = scaled
                block = 0
                pending = nil
            }
        }
        if valid, total <= ceiling, block <= ceiling,
           words.contains(where: { unit[$0] != nil || $0 == "ล้าน" }) {
            readings.insert(String(total + block + (pending ?? 0)))
        }
        return readings
    }

    /// Find "<letter-prefix> + Thai numerals" in recent transcripts for an
    /// alphanumeric word: spaced ("SHA สองห้าหก") or glued ("SHAสองห้าหก").
    /// The numerals must say the word's own digits (SHA256 never maps "SHA
    /// สอง"). Returns the exact spoken span to map, or nil.
    static func findSpokenNumeralPhrase(prefix: String, digits: String,
                                       recentTexts: [String]) -> String? {
        let says = { (run: String) in thaiNumeralReadings(run).contains(digits) }
        let p = prefix.lowercased()
        for rawText in recentTexts {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.contains(where: \.isWhitespace) {
                let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
                for (i, token) in tokens.enumerated() {
                    guard token.lowercased() == p,
                          i + 1 < tokens.count,
                          says(tokens[i + 1]) else { continue }
                    return token + " " + tokens[i + 1]
                }
            } else {
                // Spaceless: find the prefix, then take the longest following
                // run that fully segments into Thai numerals.
                // Search the original text case-insensitively: indices from a
                // lowercased copy do not belong to it ("İ" lowercases to two
                // scalars).
                var search = text.startIndex
                while let r = text.range(of: prefix, options: .caseInsensitive, range: search..<text.endIndex) {
                    let after = String(text[r.upperBound...])
                    var best: String?
                    var probe = ""
                    for ch in after {
                        probe.append(ch)
                        // No early break: "สองห" fails but "สองห้า"
                        // matches — keep the longest fully-segmenting run.
                        if says(probe) {
                            best = probe
                        }
                    }
                    if let hit = best {
                        return String(text[r]) + hit
                    }
                    search = r.upperBound
                }
            }
        }
        return nil
    }

    /// Same-script near-miss gate: equal first characters and a small edit
    /// distance that scales with length. Cross-script tokens fail the
    /// first-character check (or land far above threshold) by construction.
    private static func isNearMiss(token: String, targetFolded: String) -> Bool {
        let t = tokenForCompare(token)
        guard !t.isEmpty, !targetFolded.isEmpty,
              t.first == targetFolded.first else { return false }
        let shortest = min(t.count, targetFolded.count)
        guard shortest >= 3 else { return false }
        // Short tokens get 1 edit; longer ones get 2. Real mishearings
        // (grafannah→Grafana) usually differ by 1–2 characters.
        let allowed = shortest <= 5 ? 1 : 2
        return levenshtein(t, targetFolded) <= allowed
    }

    /// Classic two-row Levenshtein over Characters (transcripts are short;
    /// recent-token scans stay tiny).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                             prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: Candidate construction + skip-list (pure, unit-tested)

    /// Validate + skip-list a word/correction pair, or nil when unproposable.
    /// Either side hitting the skip-list vetoes the whole pair.
    static func makeCandidate(word: String, correction: String?,
                              reason: String) -> AutoLearnCandidate? {
        guard let pair = DictionaryEntry.normalized(word: word, correction: correction) else {
            return nil
        }
        guard !isSkipped(pair.word) else { return nil }
        if let c = pair.correction, isSkipped(c) { return nil }
        // Case-only diffs (grafana→Grafana) dedupe to the same Latin key as an
        // existing entry — still propose; the inbox dedupe drops true dups.
        return AutoLearnCandidate(word: pair.word, correction: pair.correction, reason: reason)
    }

    /// True when a string must NEVER become a candidate: emails, URLs, code
    /// hashes/IDs, pure numbers/dates, secrets patterns.
    static func isSkipped(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        let lower = t.lowercased()
        // Emails: anything with @ flanked by non-space (keeps "a @ b" safe).
        if t.contains("@") {
            let parts = t.split(separator: "@")
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
               !parts[0].contains(where: \.isWhitespace), !parts[1].contains(where: \.isWhitespace) {
                return true
            }
        }
        // URLs.
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        if !t.contains(where: \.isWhitespace), t.contains("."),
           Self.bareDomainPattern.firstMatch(in: t) != nil { return true }
        // Pure numbers/dates/times: digits + separators only, at least one digit.
        let hasLetter = t.contains { $0.isLetter }
        if !hasLetter, t.contains(where: \.isNumber) { return true }
        // Code hashes / IDs.
        if Self.isHashLike(t) { return true }
        // Secrets patterns.
        for pattern in Self.secretPatterns {
            if pattern.firstMatch(in: t) != nil { return true }
        }
        return false
    }

    // MARK: Skip-list patterns (compiled once)

    /// Bare domain without scheme: "example.com", "site.co.th/path".
    private static let bareDomainPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^[A-Za-z0-9][\w\-]*\.(com|net|org|io|dev|app|co|th|ai|me|so|ly)([/.?:]|$)"#,
                                 options: .caseInsensitive)
    }()

    /// API keys / tokens: AWS, GitHub, Slack, OpenAI/Google prefixes, plus a
    /// generic long-alphanumeric-secret tail.
    private static let secretPatterns: [NSRegularExpression] = {
        let raw = [
            #"AKIA[0-9A-Z]{16}"#,                 // AWS access key id
            #"gh[pousr]_[A-Za-z0-9]{16,}"#,       // GitHub tokens
            #"github_pat_[A-Za-z0-9_]{16,}"#,     // GitHub fine-grained PAT
            #"xox[bposa]-[A-Za-z0-9\-]{8,}"#,     // Slack tokens
            #"sk-(proj-)?[A-Za-z0-9_\-]{16,}"#,   // OpenAI-style keys
            #"AIza[0-9A-Za-z_\-]{20,}"#,          // Google API keys
            #"(?i)api[_\-]?key\s*[:=]\s*\S+"#,     // "api_key=…" / "api-key: …"
            #"(?i)secret\s*[:=]\s*\S+"#,          // "secret=…"
        ]
        // swiftlint:disable:next force_try
        return raw.map { try! NSRegularExpression(pattern: $0) }
    }()

    /// Hex digests (md5/sha…), UUIDs, and long mixed letter+digit tokens that
    /// read as machine IDs rather than words. Plain words (letters only) and
    /// short tags ("k8s", "GPT4") never match.
    private static func isHashLike(_ t: String) -> Bool {
        // No spaces by construction here (callers pass single tokens or short
        // phrases; phrases with spaces are never hash-like).
        guard !t.contains(where: \.isWhitespace) else { return false }
        let hex = t.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || // 0-9
            ($0.value >= 65 && $0.value <= 70) || // A-F
            ($0.value >= 97 && $0.value <= 102)   // a-f
        }
        if hex, t.count >= 8 { return true }
        // UUID.
        if UUID(uuidString: t) != nil { return true }
        // Long alphanumeric token with BOTH letters and digits (k8s is 3 chars).
        let alnum = t.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            || t.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
            }
        if alnum, t.count >= 10 {
            let hasDigit = t.contains { $0.isNumber }
            let hasLetter = t.contains { $0.isLetter }
            if hasDigit, hasLetter { return true }
        }
        return false
    }
}

private extension NSRegularExpression {
    func firstMatch(in s: String) -> NSTextCheckingResult? {
        firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }
}
