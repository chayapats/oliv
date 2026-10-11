import Foundation
import MLX

/// Older mlx-whisper checkpoints use NPZ (a ZIP of NPY arrays). MLX Swift reads
/// NPY natively; macOS supplies unzip, so this path needs no Python or download.
enum WhisperWeights {
    static func load(directory: URL) throws -> [String: MLXArray] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let tensors = files.filter { $0.pathExtension == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !tensors.isEmpty {
            var weights = [String: MLXArray]()
            for url in tensors { weights.merge(try MLX.loadArrays(url: url)) { _, new in new } }
            return weights
        }
        let archive = directory.appendingPathComponent("weights.npz")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw RuntimeError.missingModel }
        let names = try runUnzip(["-Z", "-1", archive.path]).split(separator: "\n").map(String.init)
        guard !names.isEmpty, names.count <= 4_000, Set(names).count == names.count,
              names.allSatisfy({ name in
                  name.hasSuffix(".npy") && name.first?.isLetter == true && name.utf8.allSatisfy {
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 46
                  }
              }) else { throw RuntimeError.invalidModel }
        let summary = try runUnzip(["-Z", "-t", archive.path])
        let pattern = try NSRegularExpression(pattern: "([0-9]+) bytes uncompressed")
        guard let match = pattern.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)),
              let range = Range(match.range(at: 1), in: summary), let expanded = UInt64(summary[range]),
              expanded <= 8 * 1024 * 1024 * 1024 else { throw RuntimeError.invalidModel }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("oliv-npz-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try runUnzip(["-qq", archive.path, "-d", temporary.path])
        var weights = [String: MLXArray]()
        for name in names {
            let url = temporary.appendingPathComponent(name)
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw RuntimeError.invalidModel }
            let array = try MLX.loadArray(url: url)
            // Finish lazy file reads before the extraction directory is removed.
            eval(array)
            weights[String(name.dropLast(4))] = array
        }
        return weights
    }

    private static func runUnzip(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var output = Data()
        while true {
            let bytes = pipe.fileHandleForReading.availableData
            if bytes.isEmpty { break }
            guard output.count + bytes.count <= 1024 * 1024 else {
                process.terminate(); process.waitUntilExit(); throw RuntimeError.invalidModel
            }
            output.append(bytes)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else { throw RuntimeError.invalidModel }
        return text
    }
}
