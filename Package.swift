// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoiceType",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceType",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/VoiceType"
        ),
    ]
)
