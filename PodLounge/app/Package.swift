// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PodLounge",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PodLoungeCore", targets: ["PodLoungeCore"]),
        .executable(name: "PodLounge", targets: ["PodLounge"]),
    ],
    targets: [
        .target(
            name: "PodLoungeCore",
            path: "Sources/PodLoungeCore"
        ),
        .executableTarget(
            name: "PodLounge",
            dependencies: ["PodLoungeCore"],
            path: "Sources/PodLounge",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "PodLoungeTests",
            dependencies: ["PodLoungeCore"],
            path: "Tests/PodLoungeTests"
        ),
    ]
)
