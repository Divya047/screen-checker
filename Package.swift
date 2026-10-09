// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenChecker",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ScreenCheckerCore",
            path: "Sources/ScreenCheckerCore"
        ),
        .executableTarget(
            name: "ScreenChecker",
            dependencies: ["ScreenCheckerCore"],
            path: "Sources/ScreenChecker"
        ),
        .testTarget(
            name: "ScreenCheckerCoreTests",
            dependencies: ["ScreenCheckerCore"],
            path: "Tests/ScreenCheckerCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
