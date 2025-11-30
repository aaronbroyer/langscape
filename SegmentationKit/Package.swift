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
            dependencies: ["Utilities"]
        ),
        .testTarget(
            name: "SegmentationKitTests",
            dependencies: ["SegmentationKit"]
        )
    ]
)
