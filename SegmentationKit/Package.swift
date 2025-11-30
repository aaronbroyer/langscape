// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SegmentationKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SegmentationKit",
            targets: ["SegmentationKit"]
        )
    ],
    dependencies: [
        .package(path: "../Utilities")
    ],
    targets: [
        .target(
            name: "SegmentationKit",
            dependencies: ["Utilities"],
            resources: [
                .copy("Resources/SAM2_1SmallImageEncoderFLOAT16.mlpackage"),
                .copy("Resources/SAM2_1SmallMaskDecoderFLOAT16.mlpackage"),
                .copy("Resources/SAM2_1SmallPromptEncoderFLOAT16.mlpackage")
            ]
        ),
        .testTarget(
            name: "SegmentationKitTests",
            dependencies: ["SegmentationKit"]
        )
    ]
)
