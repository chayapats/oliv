// swift-tools-version: 6.2
import PackageDescription

// Benchmark harness for Apple's on-device DictationTranscriber (issue #47).
// A developer tool, never part of the app; it needs macOS 26+ at run time.
let package = Package(
    name: "OLIVAppleDictation",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(
        name: "oliv-apple-dictation",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )]
)
