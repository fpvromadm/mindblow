// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MindBlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MindBlow",
            path: "Sources/MindBlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MindBlowTests",
            dependencies: ["MindBlow"],
            path: "Tests/MindBlowTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
