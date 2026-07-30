// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "audiosearch",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "audiosearch", targets: ["audiosearch"])
    ],
    targets: [
        .executableTarget(
            name: "audiosearch",
            path: "Sources/audiosearch"
        ),
        .testTarget(
            name: "audiosearchTests",
            dependencies: ["audiosearch"]
        ),
    ]
)
