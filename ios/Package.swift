// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OlivCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OlivCore", targets: ["OlivCore"])],
    targets: [
        .target(name: "OlivCore"),
        .testTarget(name: "OlivCoreTests", dependencies: ["OlivCore"])
    ]
)
