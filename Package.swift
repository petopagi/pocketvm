// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PocketVM",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "PocketVM",
            path: "Sources/PocketVM",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
