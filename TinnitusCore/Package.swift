// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TinnitusCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TinnitusCore", targets: ["TinnitusCore"]),
    ],
    targets: [
        .target(name: "TinnitusCore"),
        .testTarget(name: "TinnitusCoreTests", dependencies: ["TinnitusCore"]),
    ]
)
