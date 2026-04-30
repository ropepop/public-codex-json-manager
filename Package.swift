// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexAuthRotator",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "CodexAuthRotator",
            targets: ["CodexAuthRotator"]
        ),
    ],
    targets: [
        .target(
            name: "CodexAuthRotatorCore",
            path: "Sources/CodexAuthRotatorCore"
        ),
        .executableTarget(
            name: "CodexAuthRotator",
            dependencies: ["CodexAuthRotatorCore"],
            path: "Sources/CodexAuthRotator"
        ),
        .testTarget(
            name: "CodexAuthRotatorCoreTests",
            dependencies: ["CodexAuthRotatorCore"],
            path: "Tests/CodexAuthRotatorCoreTests"
        ),
        .testTarget(
            name: "CodexAuthRotatorTests",
            dependencies: ["CodexAuthRotator", "CodexAuthRotatorCore"],
            path: "Tests/CodexAuthRotatorTests"
        ),
    ]
)
