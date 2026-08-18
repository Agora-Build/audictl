// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "audictl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "audictl", targets: ["audictl"]),
        .library(name: "AudictlCore", targets: ["AudictlCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AudictlCore",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .executableTarget(
            name: "audictl",
            dependencies: [
                "AudictlCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AudictlCoreTests", dependencies: ["AudictlCore"]),
        .testTarget(name: "AudictlCLITests", dependencies: ["audictl"]),
        .testTarget(name: "IntegrationTests", dependencies: ["AudictlCore"]),
    ]
)
