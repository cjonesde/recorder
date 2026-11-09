// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASRBenchmark",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: [])
    ],
    targets: [
        .executableTarget(name: "ASRBenchmark", dependencies: [
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "FluidAudio", package: "FluidAudio")
        ])
    ]
)
