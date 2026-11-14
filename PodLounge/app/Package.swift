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
    dependencies: [
        // The package lives in LilLeveler/app. Depending on that folder directly
        // would name it "app", which collides with this package. The symlink
        // gives it its own name.
        .package(path: "../../LilLeveler/LilLevelerKit"),
        .package(path: "../../Podcast Stripper/PodStripperKit"),
        .package(path: "../../FixerMixer/PodProducerKit"),
    ],
    targets: [
        .target(
            name: "PodLoungeCore",
            path: "Sources/PodLoungeCore"
        ),
        .executableTarget(
            name: "PodLounge",
            dependencies: [
                "PodLoungeCore",
                .product(name: "LilLevelerKit", package: "LilLevelerKit"),
                .product(name: "PodStripperKit", package: "PodStripperKit"),
                .product(name: "PodProducerKit", package: "PodProducerKit"),
            ],
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
