// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipBoard",
            path: "Sources/ClipBoard"
        )
    ]
)
