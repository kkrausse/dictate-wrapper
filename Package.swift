// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DictateNemotron",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(path: "vendor/speech-swift"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
    ],
    targets: [
        .executableTarget(
            name: "DictateNemotron",
            dependencies: [
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
    ]
)
