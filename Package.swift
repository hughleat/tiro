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
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "TiroRecognition",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
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
                "BuildFeaturesTests.swift",
                "DictationModelCatalogTests.swift",
                "ErrorRecoveryTests.swift",
                "NativeTextFinalizerTests.swift",
                "NativeTiroStoreTests.swift",
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
