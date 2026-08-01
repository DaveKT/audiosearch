// swift-tools-version: 5.10
import PackageDescription

// Tools version 5.10 is deliberate: declaring 6.0 turns on strict concurrency
// checking across the whole target, which conflicts with non-Sendable framework
// types (AVAudioFile) and GRDB's model before the tool works. Swift 6 migration
// is an M5 task, per-file via upcoming feature flags (plan Section 5.2, Risk 10).
let package = Package(
    name: "audiosearch",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "audiosearch", targets: ["audiosearch"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // The Resources/Info.plist linker section described in plan Section 5.2 is
        // deliberately absent: M0 confirmed SpeechAnalyzer needs no authorization
        // prompt from a bundle-less CLI (Section 10.3, Risk 1). Omitting the
        // .unsafeFlags also keeps the package consumable as a dependency (Risk 8).
        // Reinstate it only if a macOS point release starts prompting.
        .executableTarget(
            name: "audiosearch",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/audiosearch"
        ),
        .testTarget(
            name: "audiosearchTests",
            dependencies: ["audiosearch"]
        ),
    ]
)
