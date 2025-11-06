// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameKitLS",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "GameKitLS",
            targets: ["GameKitLS"]
        )
    ],
    dependencies: [
        .package(path: "../Utilities"),
        .package(path: "../DetectionKit")
    ],
    targets: [
        .target(
            name: "GameKitLS",
            dependencies: [
                "Utilities",
                "DetectionKit"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "GameKitLSTests",
            dependencies: ["GameKitLS"]
        )
    ]
)
