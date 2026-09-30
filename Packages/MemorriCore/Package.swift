// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MemorriCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MemorriCore", targets: ["MemorriCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")
    ],
    targets: [
        .target(name: "MemorriCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "MemorriCoreTests", dependencies: ["MemorriCore"])
    ]
)
