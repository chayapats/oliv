// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "oliv-apple-cleanup",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "oliv-apple-cleanup")]
)
