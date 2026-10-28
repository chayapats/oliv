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
}
