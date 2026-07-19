// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Tiro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tiro", targets: ["Tiro"]),
        .library(name: "TiroRecognition", targets: ["TiroRecognition"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
    ],
    targets: [
        .target(
            name: "TiroRecognition",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/TiroRecognition"
        ),
        .executableTarget(
            name: "Tiro",
            dependencies: ["TiroRecognition"],
            path: "Sources/Tiro"
        ),
        .testTarget(
            name: "TiroTests",
            dependencies: ["Tiro"],
            path: "tests/TiroTests",
            exclude: [
                "ModifierEventStateTests.swift",
                "SnippetEditStateTests.swift",
                "SupportPromptPolicyAssertions.swift",
            ],
            sources: [
                "ErrorRecoveryTests.swift",
                "WorkerAPITests.swift",
                "WorkerProcessTests.swift",
                "WorkerTransportTests.swift",
                "SetupReadinessTests.swift",
                "SettingsConstructionTests.swift",
                "SupportPromptPolicyTests.swift",
            ]
        ),
        .testTarget(
            name: "TiroRecognitionTests",
            dependencies: [
                "TiroRecognition",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "tests/TiroRecognitionTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
