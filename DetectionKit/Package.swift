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
                // Mock models
                .copy("Resources/MockYOLO.mlmodelc"),
                // YOLO models (Phase 1: high-recall detection)
                .process("Resources/YOLOv8l.mlpackage"),
                .process("Resources/YOLOv8m.mlpackage"),
                // MobileCLIP models (VLM for open-vocabulary detection)
                .process("Resources/mobileclip_s2_text.mlpackage"),
                .process("Resources/mobileclip_s2_image.mlpackage"),
                .process("Resources/mobileclip_s0_text.mlpackage"),
                .process("Resources/mobileclip_s0_image.mlpackage"),
                // Label banks and vocabularies
                .copy("Resources/labelbank_en.txt"),
                .copy("Resources/clip-merges.txt")
            ]
        ),
        .testTarget(
            name: "DetectionKitTests",
            dependencies: ["DetectionKit"]
        )
    ]
)
