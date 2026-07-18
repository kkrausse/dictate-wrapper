// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DictateNemotron",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(path: "vendor/speech-swift"),
    ],
    targets: [
        .executableTarget(
            name: "DictateNemotron",
            dependencies: [
                .product(name: "ParakeetStreamingASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
            ]
        ),
        .testTarget(
            name: "DictateNemotronTests",
            dependencies: ["DictateNemotron"]
        ),
    ]
)
