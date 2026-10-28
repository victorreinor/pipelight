// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Pipelight",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PipelightCore", swiftSettings: swift5),
        .executableTarget(name: "Pipelight", dependencies: ["PipelightCore"], swiftSettings: swift5),
        .testTarget(name: "PipelightCoreTests", dependencies: ["PipelightCore"], swiftSettings: swift5),
    ]
)
