// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchHub",
            path: "Sources/NotchHub"
        )
    ]
)
