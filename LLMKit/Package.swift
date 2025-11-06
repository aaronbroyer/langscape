// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "LLMKit",
            targets: ["LLMKit"]
        )
    ],
    dependencies: [
        .package(path: "../Utilities")
    ],
    targets: [
        .target(
            name: "LLMKit",
            dependencies: [
                "Utilities"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LLMKitTests",
            dependencies: ["LLMKit"]
        )
    ]
)
