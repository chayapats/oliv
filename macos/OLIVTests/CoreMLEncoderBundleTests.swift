import Foundation
import XCTest

final class CoreMLEncoderBundleTests: XCTestCase {
    private var root: URL!
    private var component: URL { root.appendingPathComponent("component") }
    private var snapshot: URL { root.appendingPathComponent("snapshot") }
    private var home: URL { root.appendingPathComponent("home") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in [component.appendingPathComponent("AudioEncoder.mlmodelc/weights"), snapshot, home] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try Data("test compiled graph".utf8).write(to: component.appendingPathComponent("AudioEncoder.mlmodelc/model.mil"))
        try Data([1, 2, 3]).write(to: component.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin"))
        try Data("test configuration".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data([4, 5, 6]).write(to: snapshot.appendingPathComponent("weights.safetensors"))
        try writeManifest()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func writeManifest(version: Int = 1, repository: String = "chayapats/typhoon-whisper-turbo-mlx",
                               extraPath: String? = nil) throws {
        var files = try ["model.mil", "weights/weight.bin"].reduce(into: [String: String]()) { result, path in
            result[path] = try CoreMLEncoderBundle.fileSHA256(component.appendingPathComponent("AudioEncoder.mlmodelc/" + path))
        }
        if let extraPath { files[extraPath] = String(repeating: "0", count: 64) }
        let source = try ["config.json", "weights.safetensors"].reduce(into: [String: String]()) { result, path in
            result[path] = try CoreMLEncoderBundle.fileSHA256(snapshot.appendingPathComponent(path))
        }
        let manifest = CoreMLEncoderBundle.Manifest(version: version, sourceRepository: repository,
                                                   sourceFiles: source, modelFiles: files)
        try JSONEncoder().encode(manifest).write(to: component.appendingPathComponent("manifest.json"))
    }

    func testReadyReceiptRequiresMatchingModelCheckpointHostAndOS() throws {
        let bundle = try CoreMLEncoderBundle(directory: component)
        XCTAssertTrue(bundle.matchesCheckpoint(snapshot, repository: bundle.manifest.sourceRepository))
        XCTAssertFalse(bundle.matchesCheckpoint(snapshot, repository: "another/model"))
        XCTAssertFalse(bundle.isReady(modelsHome: home, host: "macA-osA"))
        try bundle.markReady(modelsHome: home, host: "macA-osA")
        XCTAssertTrue(bundle.isReady(modelsHome: home, host: "macA-osA"))
        XCTAssertFalse(bundle.isReady(modelsHome: home, host: "macA-osB"))
        XCTAssertFalse(bundle.isReady(modelsHome: home, host: "macB-osA"))
        try Data("changed checkpoint".utf8).write(to: snapshot.appendingPathComponent("weights.safetensors"))
        XCTAssertFalse(bundle.matchesCheckpoint(snapshot, repository: bundle.manifest.sourceRepository))
    }

    func testCorruptMissingExtraAndSymlinkFilesCannotBePrepared() throws {
        let bundle = try CoreMLEncoderBundle(directory: component)
        let graph = bundle.modelURL.appendingPathComponent("model.mil")
        let original = try Data(contentsOf: graph)
        try Data("corrupted".utf8).write(to: graph)
        XCTAssertThrowsError(try bundle.markReady(modelsHome: home, host: "test"))
        XCTAssertFalse(bundle.isReady(modelsHome: home, host: "test"))
        try FileManager.default.removeItem(at: graph)
        XCTAssertThrowsError(try bundle.verifyModel())
        try original.write(to: graph)
        let extra = bundle.modelURL.appendingPathComponent("unlisted.bin")
        try Data([0]).write(to: extra)
        XCTAssertThrowsError(try bundle.verifyModel())
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.removeItem(at: graph)
        try FileManager.default.createSymbolicLink(at: graph, withDestinationURL: snapshot.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try bundle.verifyModel())
    }

    func testRejectsUnknownVersionRepositoryAndUnsafeRelativePaths() throws {
        try writeManifest(version: 2)
        XCTAssertThrowsError(try CoreMLEncoderBundle(directory: component))
        try writeManifest(repository: "different/checkpoint")
        XCTAssertThrowsError(try CoreMLEncoderBundle(directory: component))
        for path in ["../outside", "/absolute", "weights//empty", "./model.mil"] {
            try writeManifest(extraPath: path)
            XCTAssertThrowsError(try CoreMLEncoderBundle(directory: component))
        }
    }

    func testArtifactChangeInvalidatesOldReceipt() throws {
        let before = try CoreMLEncoderBundle(directory: component)
        try before.markReady(modelsHome: home, host: "test")
        try Data([9, 8, 7]).write(to: before.modelURL.appendingPathComponent("weights/weight.bin"))
        try writeManifest()
        let after = try CoreMLEncoderBundle(directory: component)
        XCTAssertNotEqual(before.fingerprint, after.fingerprint)
        XCTAssertFalse(after.isReady(modelsHome: home, host: "test"))
        try after.markReady(modelsHome: home, host: "test")
        XCTAssertTrue(after.isReady(modelsHome: home, host: "test"))
    }
}
