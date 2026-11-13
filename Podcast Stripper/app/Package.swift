// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PodcastStripper",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PodStripperKit", targets: ["PodStripperKit"]),
        .executable(name: "PodcastStripper", targets: ["PodcastStripper"]),
    ],
    targets: [
        .target(
            name: "PodStripperKit",
            path: "Sources/PodStripperKit"
        ),
        .executableTarget(
            name: "PodcastStripper",
            dependencies: ["PodStripperKit"],
            path: "Sources/PodcastStripper"
        ),
        .testTarget(
            name: "PodStripperKitTests",
            dependencies: ["PodStripperKit"],
            path: "Tests/PodStripperKitTests"
        ),
        .testTarget(
            name: "PodcastStripperTests",
            path: "Tests/PodcastStripperTests"
        ),
    ]
)
