// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmartScreenshot",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "smart-screenshot", targets: ["smart-screenshot"]),
    ],
    targets: [
        // OCR, naming providers, filename policy, and orchestration. No third-party dependencies.
        .target(name: "SmartScreenshotCore"),
        // Thin command-line entry point.
        .executableTarget(name: "smart-screenshot", dependencies: ["SmartScreenshotCore"]),
        .testTarget(name: "SmartScreenshotCoreTests", dependencies: ["SmartScreenshotCore"]),
    ]
)
