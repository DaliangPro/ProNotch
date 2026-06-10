// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ProNotch",
            path: "Sources/ProNotch"
        )
    ]
)
