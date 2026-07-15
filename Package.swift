// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ParakeetDictation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tiro", targets: ["Tiro"])
    ],
    targets: [
        .executableTarget(
            name: "Tiro",
            path: "Sources/Tiro"
        )
    ],
    swiftLanguageModes: [.v5]
)
