// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LilLeveler",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LilLevelerKit", targets: ["LilLevelerKit"]),
        .executable(name: "LilLeveler", targets: ["LilLeveler"]),
    ],
    targets: [
        .target(
            name: "LilLevelerKit",
            path: "Sources/LilLevelerKit"
        ),
        .executableTarget(
            name: "LilLeveler",
            dependencies: ["LilLevelerKit"],
            path: "Sources/LilLeveler"
        ),
        .testTarget(
            name: "LilLevelerTests",
            dependencies: ["LilLevelerKit"],
            path: "Tests/LilLevelerTests"
        ),
    ]
)
