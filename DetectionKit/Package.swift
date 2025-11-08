// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DetectionKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DetectionKit",
            targets: ["DetectionKit"]
        )
    ],
    dependencies: [
        .package(path: "../Utilities")
    ],
    targets: [
        .target(
            name: "DetectionKit",
            dependencies: [
                "Utilities"
            ],
            resources: [
                .copy("Resources/MockYOLO.mlmodelc")
            ]
        ),
        .testTarget(
            name: "DetectionKitTests",
            dependencies: ["DetectionKit"]
        )
    ]
)
