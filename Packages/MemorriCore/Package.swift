// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MemorriCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MemorriCore", targets: ["MemorriCore"])
    ],
    targets: [
        .target(name: "MemorriCore"),
        .testTarget(name: "MemorriCoreTests", dependencies: ["MemorriCore"])
    ]
)
