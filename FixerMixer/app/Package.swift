// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixerMixer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PodProducerKit", targets: ["PodProducerKit"]),
        .executable(name: "FixerMixer", targets: ["FixerMixer"]),
        .executable(name: "RecordStress", targets: ["RecordStress"]),
    ],
    targets: [
        .target(
            name: "PPAtomics",
            path: "Sources/PPAtomics",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RecordCore",
            dependencies: ["PPAtomics"],
            path: "Sources/RecordCore"
        ),
        .target(
            name: "PodProducerKit",
            dependencies: ["RecordCore"],
            path: "Sources/PodProducerKit"
        ),
        .executableTarget(
            name: "FixerMixer",
            dependencies: ["PodProducerKit"],
            path: "Sources/FixerMixer"
        ),
        .executableTarget(
            name: "RecordStress",
            dependencies: ["RecordCore"],
            path: "Sources/RecordStress"
        ),
        .testTarget(
            name: "PodProducerKitTests",
            dependencies: ["PodProducerKit"],
            path: "Tests/PodProducerKitTests"
        ),
    ]
)
