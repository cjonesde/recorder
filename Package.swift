// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Recorder",
    platforms: [
        // macOS 15+: the Synchronization module's `Atomic` (used by the
        // realtime-safe ring buffer in the system-audio tap) requires it.
        .macOS("15")
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Recorder",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Recorder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
