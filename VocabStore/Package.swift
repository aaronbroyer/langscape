// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VocabStore",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "VocabStore",
            targets: ["VocabStore"]
        )
    ],
    dependencies: [
        .package(path: "../Utilities")
    ],
    targets: [
        .target(
            name: "VocabStore",
            dependencies: [
                "Utilities"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "VocabStoreTests",
            dependencies: ["VocabStore"]
        )
    ]
)
