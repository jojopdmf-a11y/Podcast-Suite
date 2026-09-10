// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LilLeveler",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "LilLeveler", targets: ["LilLeveler"]),
    ],
    targets: [
        .executableTarget(
            name: "LilLeveler",
            path: "Sources/LilLeveler"
        ),
    ]
)
