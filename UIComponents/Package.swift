// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UIComponents",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "UIComponents",
            targets: ["UIComponents"]
        )
    ],
    dependencies: [
        .package(path: "../DesignSystem"),
        .package(path: "../Utilities")
    ],
    targets: [
        .target(
            name: "UIComponents",
            dependencies: [
                "DesignSystem",
                "Utilities"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "UIComponentsTests",
            dependencies: ["UIComponents"]
        )
    ]
)
