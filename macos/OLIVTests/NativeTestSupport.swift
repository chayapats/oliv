import Foundation

enum NativeTestSupport {
    static func executable() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["OLIV_TEST_WORKER"]
            ?? root.appendingPathComponent("build/native-tools/oliv-test-worker").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw NSError(domain: "NativeTestSupport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Build native test fixtures first: bash scripts/build_dev.sh --tests-only"
            ])
        }
        return path
    }

    /// The real Rust worker from `scripts/build_native.sh`.
    static func sidecar() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("build/native-runtime/oliv-sidecar").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw NSError(domain: "NativeTestSupport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Build the native runtime first: bash scripts/build_native.sh"
            ])
        }
        return path
    }
}
