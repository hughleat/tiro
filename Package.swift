// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Tiro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tiro", targets: ["Tiro"])
    ],
    targets: [
        .executableTarget(
            name: "Tiro",
            path: "Sources/Tiro"
        ),
        .testTarget(
            name: "TiroTests",
            dependencies: ["Tiro"],
            path: "Tests/TiroTests",
            exclude: [
                "ModifierEventStateTests.swift",
                "SnippetEditStateTests.swift",
            ],
            sources: [
                "WorkerAPITests.swift",
                "WorkerProcessTests.swift",
                "WorkerTransportTests.swift",
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
