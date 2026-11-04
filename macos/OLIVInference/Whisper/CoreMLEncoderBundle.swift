import CryptoKit
import Darwin
import Foundation

/// A versioned encoder component supplied by the app build, never inferred
/// from a tensor shape or an arbitrary model-cache directory.
struct CoreMLEncoderBundle {
    struct Manifest: Codable {
        let version: Int
        let sourceRepository: String
        let sourceFiles: [String: String]
        let modelFiles: [String: String]
    }
    struct Receipt: Codable {
        let version: Int
        let fingerprint: String
        let host: String
    }
    enum Failure: Error { case invalidManifest, invalidFiles, unavailableHost }

    let directory: URL
    let manifest: Manifest
    let fingerprint: String
    var modelURL: URL { directory.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true) }

    init(directory: URL) throws {
        let file = try FileHandle(forReadingFrom: directory.appendingPathComponent("manifest.json"))
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 65_537), data.count <= 65_536 else { throw Failure.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1,
              manifest.sourceRepository == "chayapats/typhoon-whisper-turbo-mlx",
              Set(manifest.sourceFiles.keys) == ["config.json", "weights.safetensors"],
              !manifest.modelFiles.isEmpty, manifest.modelFiles.count <= 32,
              manifest.modelFiles.keys.allSatisfy(Self.safeRelativePath),
              (Array(manifest.sourceFiles.values) + Array(manifest.modelFiles.values)).allSatisfy(Self.isSHA256)
        else { throw Failure.invalidManifest }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.directory = directory
        self.manifest = manifest
        self.fingerprint = Self.digest(try encoder.encode(manifest))
    }

    static func bundled(beside helper: URL) -> CoreMLEncoderBundle? {
        let directory = helper.deletingLastPathComponent()
            .appendingPathComponent("../models/typhoon-encoder", isDirectory: true).standardizedFileURL
        return try? Self(directory: directory)
    }

    func verifyModel() throws {
        let fm = FileManager.default
        let root = try modelURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw Failure.invalidFiles }
        // Directory enumeration resolves ancestor symlinks (e.g. /var on macOS).
        // Resolve the base too before computing relative file names.
        guard let resolved = realpath(modelURL.path, nil) else { throw Failure.invalidFiles }
        defer { free(resolved) }
        let basePath = String(cString: resolved)
        let base = URL(fileURLWithPath: basePath, isDirectory: true)
        guard let files = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw Failure.invalidFiles
        }
        var found = Set<String>()
        for case let url as URL in files {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw Failure.invalidFiles }
            guard properties.isRegularFile == true else { continue }
            guard url.path.hasPrefix(basePath + "/") else { throw Failure.invalidFiles }
            let relative = String(url.path.dropFirst(basePath.count + 1))
            guard let expected = manifest.modelFiles[relative], try Self.fileSHA256(url) == expected else { throw Failure.invalidFiles }
            found.insert(relative)
        }
        guard found == Set(manifest.modelFiles.keys) else { throw Failure.invalidFiles }
    }

    func matchesCheckpoint(_ snapshot: URL, repository: String) -> Bool {
        guard repository == manifest.sourceRepository else { return false }
        return manifest.sourceFiles.allSatisfy { name, expected in
            (try? Self.fileSHA256(snapshot.appendingPathComponent(name))) == expected
        }
    }

    func receiptURL(modelsHome: URL, host: String) -> URL {
        modelsHome.appendingPathComponent("oliv-encoder-ready", isDirectory: true)
            .appendingPathComponent(fingerprint + "-" + Self.digest(Data(host.utf8)) + ".json")
    }

    func isReady(modelsHome: URL, host: String? = Self.hostSignature()) -> Bool {
        guard let host,
              let data = try? Data(contentsOf: receiptURL(modelsHome: modelsHome, host: host)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data)
        else { return false }
        return receipt.version == 1 && receipt.fingerprint == fingerprint && receipt.host == host
    }

    func markReady(modelsHome: URL, host: String? = Self.hostSignature()) throws {
        guard let host else { throw Failure.unavailableHost }
        try verifyModel()
        let url = receiptURL(modelsHome: modelsHome, host: host)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let receipt = Receipt(version: 1, fingerprint: fingerprint, host: host)
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
    }

    /// Local compilation cache identity. The host identifier is hashed, kept
    /// only in a local receipt, and never sent to a service or a model.
    static func hostSignature() -> String? {
        var host = UUID().uuid
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&host, &timeout) == 0 else { return nil }
        let data = withUnsafeBytes(of: host) { Data($0) }
        return digest(data + Data(ProcessInfo.processInfo.operatingSystemVersionString.utf8))
    }

    static func fileSHA256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func isSHA256(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
