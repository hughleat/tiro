// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TiroCoreMLPrototype",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TiroCoreMLProbe", targets: ["TiroCoreMLProbe"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        )
    ],
    targets: [
        .target(
            name: "TiroRecognition",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .executableTarget(
            name: "TiroCoreMLProbe",
            dependencies: ["TiroRecognition"]
        ),
        .testTarget(
            name: "TiroRecognitionTests",
            dependencies: ["TiroRecognition"]
        )
    ],
    swiftLanguageModes: [.v5]
)
