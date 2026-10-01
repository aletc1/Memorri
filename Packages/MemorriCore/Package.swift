// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MemorriCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MemorriCore", targets: ["MemorriCore"]),
        .executable(name: "memorri-eval", targets: ["memorri-eval"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")
    ],
    targets: [
        .target(name: "MemorriCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // The eval tool is a thin front end over MemorriCore/Evaluation. A SwiftPM target cannot live outside the
        // package root, so it is here and not under Tools/ (ADR 0015).
        .executableTarget(name: "memorri-eval", dependencies: ["MemorriCore"]),
        .testTarget(name: "MemorriCoreTests", dependencies: ["MemorriCore"])
    ]
)
