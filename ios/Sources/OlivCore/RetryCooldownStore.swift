import Foundation

/// A conservative app-wide API cooldown survives restarts and credential/URL
/// changes. The file contains only an expiry date, never a credential or request.
/// This store never sleeps, polls, or retries network requests.
public final class RetryCooldownStore: @unchecked Sendable {
    private struct Entry: Codable { let until: Date }
    private let file: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        file = directory.appendingPathComponent("retry-cooldown.json")
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
        var folder = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
    }

    /// Call immediately before each explicit inference operation.
    public func check(now: Date = Date()) throws {
        if let date = try until(now: now) { throw OlivError.rateLimited(retryAfter: date) }
    }

    /// An expired record stays harmlessly on disk; no idle cleanup work occurs.
    public func until(now: Date = Date()) throws -> Date? {
        guard now.timeIntervalSince1970.isFinite else { throw OlivError.corruptedStore }
        return try lock.withLock {
            guard let date = try read(), date > now else { return nil }
            return date
        }
    }

    /// A later denial may extend the cooldown, but cannot shorten an existing one.
    public func record(until date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw OlivError.corruptedStore }
        try lock.withLock {
            if let existing = try read(), existing >= date { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(Entry(until: date))
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }

    private func read() throws -> Date? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_024 else { throw OlivError.corruptedStore }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_024 else { throw OlivError.corruptedStore }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let entry = try? decoder.decode(Entry.self, from: data),
              entry.until.timeIntervalSince1970.isFinite else { throw OlivError.corruptedStore }
        return entry.until
    }
}
