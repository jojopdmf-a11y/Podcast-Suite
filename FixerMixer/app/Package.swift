// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixerMixer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
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
        .executableTarget(
            name: "FixerMixer",
            dependencies: ["RecordCore"],
            path: "Sources/FixerMixer"
        ),
        .executableTarget(
            name: "RecordStress",
            dependencies: ["RecordCore"],
            path: "Sources/RecordStress"
        ),
    ]
)
