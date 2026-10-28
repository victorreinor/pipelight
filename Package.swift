// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Esteira",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EsteiraCore", swiftSettings: swift5),
        .executableTarget(name: "Esteira", dependencies: ["EsteiraCore"], swiftSettings: swift5),
        .testTarget(name: "EsteiraCoreTests", dependencies: ["EsteiraCore"], swiftSettings: swift5),
    ]
)
