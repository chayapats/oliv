import Foundation

public enum HistorySource: String, Codable, Sendable { case dictation, retry, cleanup }

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var source: HistorySource
    public var audioDuration: TimeInterval
    public var totalDuration: TimeInterval
    public var reply: DictationReply
    public var copied: Bool
    public var finalText: String { reply.finalText }
    public var raw: String { reply.raw }

    public init(id: UUID = UUID(), createdAt: Date = Date(), source: HistorySource = .dictation,
                audioDuration: TimeInterval, totalDuration: TimeInterval, reply: DictationReply, copied: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.audioDuration = audioDuration
        self.totalDuration = totalDuration
        self.reply = reply
        self.copied = copied
    }
}

/// One versioned atomic file prevents partial history entries after termination.
/// Callers must share a store instance for each directory; the app coordinates
/// extension requests through the app process rather than writing concurrently.
public final class HistoryStore: @unchecked Sendable {
    private struct Archive: Codable { var version = 1; var entries: [HistoryEntry] }
    private let file: URL
    private let retentionLimit: Int
    private let lock = NSLock()

    public init(directory: URL, retentionLimit: Int = 1_000) throws {
        guard retentionLimit > 0 else { throw OlivError.invalidOptions(String(localized: "Keep at least one history entry.", bundle: .main)) }
        try StoreIO.prepare(directory)
        file = directory.appendingPathComponent("history.json")
        self.retentionLimit = retentionLimit
    }

    /// Most recent first, with deterministic tie-breaking.
    public func entries() throws -> [HistoryEntry] {
        try lock.withLock { try read().entries.sorted(by: Self.newer) }
    }

    public func append(_ entry: HistoryEntry) throws {
        try lock.withLock {
            var archive = try read()
            archive.entries.removeAll { $0.id == entry.id }
            archive.entries.append(entry)
            archive.entries = Array(archive.entries.sorted(by: Self.newer).prefix(retentionLimit))
            try StoreIO.write(archive, to: file)
        }
    }

    public func markCopied(id: UUID) throws {
        try lock.withLock {
            var archive = try read()
            guard let index = archive.entries.firstIndex(where: { $0.id == id }) else { return }
            archive.entries[index].copied = true
            try StoreIO.write(archive, to: file)
        }
    }

    public func remove(id: UUID) throws {
        try lock.withLock {
            var archive = try read()
            archive.entries.removeAll { $0.id == id }
            try StoreIO.write(archive, to: file)
        }
    }

    public func removeAll() throws {
        try lock.withLock { try StoreIO.write(Archive(entries: []), to: file) }
    }

    private func read() throws -> Archive {
        guard FileManager.default.fileExists(atPath: file.path) else { return Archive(entries: []) }
        let archive: Archive = try StoreIO.read(from: file)
        guard archive.version == 1 else { throw OlivError.corruptedStore }
        return archive
    }

    private static func newer(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool {
        a.createdAt == b.createdAt ? a.id.uuidString > b.id.uuidString : a.createdAt > b.createdAt
    }
}

public struct PendingRecording: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let audioDuration: TimeInterval
    public let options: OlivOptions
    public internal(set) var attemptCount: Int
    public internal(set) var lastError: String?
}

/// Saves WAV + the original options as one directory transaction before upload.
/// Successful audio is removed explicitly, only after the history write succeeds.
public final class PendingRecordingStore: @unchecked Sendable {
    private struct Envelope: Codable { var version = 1; var recording: PendingRecording }
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        try StoreIO.prepare(directory)
        self.directory = directory
    }

    public func enqueue(wav: Data, options: OlivOptions, createdAt: Date = Date()) throws -> PendingRecording {
        try options.validate()
        let metadata = try WAVMetadata(data: wav)
        guard metadata.sampleRate == RecordingLimits.sampleRate, metadata.channelCount == 1,
              metadata.bitsPerSample == 16, metadata.duration > 0,
              metadata.duration <= RecordingLimits.maximumDuration else {
            throw OlivError.invalidAudio(String(localized: "Save 16 kHz mono PCM recordings of up to two minutes.", bundle: .main))
        }
        let recording = PendingRecording(id: UUID(), createdAt: createdAt, audioDuration: metadata.duration,
                                         options: options, attemptCount: 0, lastError: nil)
        return try lock.withLock {
            let staging = directory.appendingPathComponent(".staging-\(recording.id.uuidString)", isDirectory: true)
            try StoreIO.prepare(staging)
            do {
                try StoreIO.writeData(wav, to: staging.appendingPathComponent("audio.wav"))
                try StoreIO.write(Envelope(recording: recording), to: staging.appendingPathComponent("metadata.json"))
                try FileManager.default.moveItem(at: staging, to: folder(recording.id))
                return recording
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
    }

    /// Oldest first, matching the Linux retry queue.
    public func recordings() throws -> [PendingRecording] {
        try lock.withLock {
            let folders = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var recordings: [PendingRecording] = []
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                let envelope: Envelope = try StoreIO.read(from: folder.appendingPathComponent("metadata.json"))
                guard envelope.version == 1,
                      envelope.recording.id.uuidString == folder.lastPathComponent,
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path) else {
                    throw OlivError.corruptedStore
                }
                recordings.append(envelope.recording)
            }
            return recordings.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
        }
    }

    public func audio(for id: UUID) throws -> Data {
        try lock.withLock {
            let path = folder(id).appendingPathComponent("audio.wav")
            guard FileManager.default.fileExists(atPath: path.path) else { throw OlivError.missingRecording }
            return try Data(contentsOf: path)
        }
    }

    /// Supply a user-facing error, never a raw HTTP response or credential.
    public func recordAttempt(id: UUID, errorDescription: String?) throws {
        try lock.withLock {
            let path = folder(id).appendingPathComponent("metadata.json")
            guard FileManager.default.fileExists(atPath: path.path) else { throw OlivError.missingRecording }
            var envelope: Envelope = try StoreIO.read(from: path)
            guard envelope.version == 1, envelope.recording.id == id else { throw OlivError.corruptedStore }
            envelope.recording.attemptCount += 1
            envelope.recording.lastError = errorDescription
            try StoreIO.write(envelope, to: path)
        }
    }

    public func remove(id: UUID) throws {
        try lock.withLock {
            let target = folder(id)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }

    public func removeAll() throws {
        try lock.withLock {
            let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            // Remove only our recording/staging directories, never unrelated files.
            for item in contents where UUID(uuidString: item.lastPathComponent) != nil || item.lastPathComponent.hasPrefix(".staging-") {
                try FileManager.default.removeItem(at: item)
            }
        }
    }

    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
}

private enum StoreIO {
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try writeData(encoder.encode(value), to: url)
    }

    static func writeData(_ data: Data, to url: URL) throws {
        #if os(iOS)
        // Recording can finish while the device is locked. These stores close
        // and reopen files for synchronization, upload, and history updates, so
        // completeUnlessOpen would make the completed recording inaccessible.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Complete the durable write before network work begins.
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    static func read<T: Decodable>(from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(T.self, from: data) }
        catch { throw OlivError.corruptedStore }
    }
}
