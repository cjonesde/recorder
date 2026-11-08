// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Recorder",
    platforms: [
        // Apple SpeechAnalyzer provides incremental on-device transcription.
        .macOS("26")
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "Recorder",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Recorder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "RecorderTests",
            dependencies: ["Recorder"],
            path: "Tests/RecorderTests"
        )
    ]
)
