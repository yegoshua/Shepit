// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shepit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Shepit",
            dependencies: [
                "ShepitCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .target(name: "ShepitCore"),
        .testTarget(name: "ShepitCoreTests", dependencies: ["ShepitCore"]),
    ],
    swiftLanguageModes: [.v5]
)
