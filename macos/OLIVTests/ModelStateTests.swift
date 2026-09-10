// ModelState.diskInfo regression tests — hermetic (temp dirs, no real cache).
//
// The load-bearing case is the SYMLINKED repo dir: a shared HF cache linked
// into the app's models home read as "Not downloaded" forever, because
// FileManager.enumerator(at:) yields nothing for a symlink root. diskInfo now
// resolves the root first; these tests pin both the plain and linked layouts.

import XCTest
@testable import OLIV

final class ModelStateTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oliv-modelstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Build a minimal HF-shaped repo dir: blobs/<data> + snapshots/<rev>/ with
    /// the given entries symlinked into blobs, exactly like huggingface_hub.
    /// Defaults to a COMPLETE repo (config.json + weights): the readiness rule
    /// requires both before a repo counts as present.
    private func makeRepoDir(
        named name: String, payloadBytes: Int,
        files: [String] = ["config.json", "weights.safetensors"]
    ) throws -> URL {
        let fm = FileManager.default
        let repo = tmp.appendingPathComponent(name)
        let blobs = repo.appendingPathComponent("blobs")
        let snap = repo.appendingPathComponent("snapshots/abc123")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("deadbeef")
        try Data(repeating: 0x57, count: payloadBytes).write(to: blob)
        for file in files {
            try fm.createSymbolicLink(
                at: snap.appendingPathComponent(file),
                withDestinationURL: blob)
        }
        return repo
    }

    func testPlainRepoDirIsPresentAndCountsBlobBytesOnce() throws {
        let repo = try makeRepoDir(named: "models--x--plain", payloadBytes: 1234)
        let (present, bytes) = ModelState.diskInfo(atDir: repo.path)
        XCTAssertTrue(present)
        // Blob counted once; the snapshot symlink must NOT double it.
        XCTAssertEqual(bytes, 1234)
    }

    /// The regression: a repo dir that is ITSELF a symlink (shared cache) must
    /// read identically to the real dir it points at.
    func testSymlinkedRepoDirIsPresentWithSameBytes() throws {
        let real = try makeRepoDir(named: "models--x--real", payloadBytes: 4096)
        let link = tmp.appendingPathComponent("models--x--linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let direct = ModelState.diskInfo(atDir: real.path)
        let viaLink = ModelState.diskInfo(atDir: link.path)
        XCTAssertTrue(viaLink.present, "symlinked repo dir must count as present")
        XCTAssertEqual(viaLink.bytes, direct.bytes)
    }

    func testMissingDirNotPresent() {
        let (present, bytes) = ModelState.diskInfo(atDir: tmp.appendingPathComponent("nope").path)
        XCTAssertFalse(present)
        XCTAssertEqual(bytes, 0)
    }

    func testDirWithoutSnapshotNotPresent() throws {
        // blobs exist but no materialized snapshot (interrupted download shape).
        let repo = tmp.appendingPathComponent("models--x--nosnap")
        let blobs = repo.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: blobs.appendingPathComponent("b"))
        let (present, _) = ModelState.diskInfo(atDir: repo.path)
        XCTAssertFalse(present)
    }

    // 0.1.5 strictness: HF materializes each snapshot entry only AFTER that file
    // fully downloads, so an interrupted repo has a snapshot dir but lacks
    // config.json and/or the weights entry. Those shapes must read as absent.

    func testSnapshotMissingWeightsNotPresent() throws {
        let repo = try makeRepoDir(named: "models--x--noweights", payloadBytes: 10,
                                   files: ["config.json"])
        XCTAssertFalse(ModelState.diskInfo(atDir: repo.path).present)
    }

    func testSnapshotMissingConfigNotPresent() throws {
        let repo = try makeRepoDir(named: "models--x--noconfig", payloadBytes: 10,
                                   files: ["weights.safetensors"])
        XCTAssertFalse(ModelState.diskInfo(atDir: repo.path).present)
    }

    func testNpzWeightsSatisfyReadiness() throws {
        // whisper-large-v3 ships weights.npz, not safetensors.
        let repo = try makeRepoDir(named: "models--x--npz", payloadBytes: 10,
                                   files: ["config.json", "weights.npz"])
        XCTAssertTrue(ModelState.diskInfo(atDir: repo.path).present)
    }

    func testCompleteRepoWithZeroBytesNotPresent() throws {
        let repo = try makeRepoDir(named: "models--x--zero", payloadBytes: 0)
        XCTAssertFalse(ModelState.diskInfo(atDir: repo.path).present)
    }

    // Review hardening: completeness must hold within ONE snapshot. Two
    // differently-incomplete revisions (config in A, weights in B) do not make
    // a loadable model, and neither do name matches outside snapshots/
    // (huggingface_hub's .no_exist markers are empty files named after probed
    // files that 404'd on the hub).

    func testTwoComplementaryHalfSnapshotsNotPresent() throws {
        let fm = FileManager.default
        let repo = tmp.appendingPathComponent("models--x--split")
        let blobs = repo.appendingPathComponent("blobs")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("deadbeef")
        try Data(repeating: 0x57, count: 100).write(to: blob)
        for (rev, file) in [("aaa111", "config.json"), ("bbb222", "weights.safetensors")] {
            let snap = repo.appendingPathComponent("snapshots/\(rev)")
            try fm.createDirectory(at: snap, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: snap.appendingPathComponent(file),
                                      withDestinationURL: blob)
        }
        XCTAssertFalse(ModelState.diskInfo(atDir: repo.path).present)
    }

    func testNoExistMarkersDoNotSatisfyReadiness() throws {
        // Snapshot holds only config.json; .no_exist records a weights probe
        // that 404'd. The marker must not count as weights.
        let fm = FileManager.default
        let repo = try makeRepoDir(named: "models--x--noexist", payloadBytes: 100,
                                   files: ["config.json"])
        let noExist = repo.appendingPathComponent(".no_exist/abc123")
        try fm.createDirectory(at: noExist, withIntermediateDirectories: true)
        try Data().write(to: noExist.appendingPathComponent("weights.safetensors"))
        XCTAssertFalse(ModelState.diskInfo(atDir: repo.path).present)
    }

    func testDanglingWeightsSymlinkNotPresent() throws {
        // A cache cleaner deleted the multi-GB weights blob; the snapshot's
        // symlink dangles. config.json's small blob survives (total > 0), but
        // the repo is not loadable and must read absent.
        let fm = FileManager.default
        let repo = tmp.appendingPathComponent("models--x--dangling")
        let blobs = repo.appendingPathComponent("blobs")
        let snap = repo.appendingPathComponent("snapshots/abc123")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        let cfgBlob = blobs.appendingPathComponent("cfg")
        try Data(repeating: 1, count: 50).write(to: cfgBlob)
        try fm.createSymbolicLink(at: snap.appendingPathComponent("config.json"),
                                  withDestinationURL: cfgBlob)
        try fm.createSymbolicLink(at: snap.appendingPathComponent("weights.safetensors"),
                                  withDestinationURL: blobs.appendingPathComponent("gone"))
        XCTAssertFalse(ModelState.diskInfo(atDir: repo.path).present)
    }

    // Review hardening: an absent-but-partial repo must SAY it holds bytes —
    // "Not downloaded" while gigabytes of blobs sit on disk misleads both the
    // Models tab and the diagnostics report.
    func testSizeTextDistinguishesPartialFromEmpty() {
        let empty = RepoInfo(repo: "x", present: false, bytes: 0)
        XCTAssertEqual(empty.sizeText, "Not downloaded")
        let partial = RepoInfo(repo: "x", present: false, bytes: 2_300_000_000)
        XCTAssertTrue(partial.sizeText.hasPrefix("Incomplete ("),
                      "partial repo must surface its on-disk bytes, got: \(partial.sizeText)")
        let present = RepoInfo(repo: "x", present: true, bytes: 1_000_000)
        XCTAssertFalse(present.sizeText.contains("Incomplete"))
    }
}
