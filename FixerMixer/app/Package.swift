// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixerMixer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "FixerMixer", targets: ["FixerMixer"]),
    ],
    targets: [
        .executableTarget(
            name: "FixerMixer",
            path: "Sources/FixerMixer"
        ),
    ]
)
