// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PodcastStripper",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "PodcastStripper", targets: ["PodcastStripper"]),
    ],
    targets: [
        .executableTarget(
            name: "PodcastStripper",
            path: "Sources/PodcastStripper"
        ),
    ]
)
