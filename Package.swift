// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PicReel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PicReel",
            path: "Sources/PicReel"
        )
    ]
)
