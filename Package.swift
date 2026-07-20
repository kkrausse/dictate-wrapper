// swift-tools-version: 6.0
import PackageDescription

// Tools version 6.0 is required so `swift test` can use the Swift Testing
// library that ships with Command Line Tools (XCTest requires full Xcode).
// The language mode stays at 5 until the targets adopt Swift 6 concurrency.
let package = Package(
    name: "DictateNemotron",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(path: "vendor/FluidAudio"),
        .package(path: "vendor/speech-swift"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
    ],
    targets: [
        .executableTarget(
            name: "DictateNemotron",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "NemotronStreamingASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .testTarget(
            name: "DictateNemotronTests",
            dependencies: ["DictateNemotron"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
