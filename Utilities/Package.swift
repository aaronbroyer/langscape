// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Utilities",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Utilities",
            targets: ["Utilities"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Utilities",
            dependencies: [],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "UtilitiesTests",
            dependencies: ["Utilities"]
        )
    ]
)
