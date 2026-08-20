// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BilibiliClient",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "BilibiliClient",
            path: "Sources/BilibiliClient"
        )
    ],
    swiftLanguageModes: [.v5]
)
