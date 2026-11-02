// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DowasureCore",
    defaultLocalization: "ja",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DowasureCore", targets: ["DowasureCore"]),
    ],
    targets: [
        .target(name: "DowasureCore"),
        .executableTarget(name: "DowasureEval", dependencies: ["DowasureCore"]),
        .testTarget(name: "DowasureCoreTests", dependencies: ["DowasureCore"]),
    ]
)
