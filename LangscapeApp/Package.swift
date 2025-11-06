// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LangscapeApp",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "LangscapeApp",
            targets: ["LangscapeApp"]
        )
    ],
    dependencies: [
        .package(path: "../DesignSystem"),
        .package(path: "../UIComponents"),
        .package(path: "../Utilities"),
        .package(path: "../DetectionKit"),
        .package(path: "../GameKitLS"),
        .package(path: "../VocabStore"),
        .package(path: "../LLMKit")
    ],
    targets: [
        .target(
            name: "LangscapeApp",
            dependencies: [
                "DesignSystem",
                "UIComponents",
                "Utilities",
                "DetectionKit",
                "GameKitLS",
                "VocabStore",
                "LLMKit"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LangscapeAppTests",
            dependencies: ["LangscapeApp"]
        )
    ]
)
