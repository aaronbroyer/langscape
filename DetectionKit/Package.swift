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
                // YOLO model (OVD student)
                .copy("Resources/YOLOv8-ovd.mlpackage"),
                // MobileCLIP models (VLM for open-vocabulary detection)
                .copy("Resources/mobileclip_s2_text.mlpackage"),
                .copy("Resources/mobileclip_s2_image.mlpackage"),
                .copy("Resources/mobileclip_s0_text.mlpackage"),
                .copy("Resources/mobileclip_s0_image.mlpackage"),
                // Label banks and vocabularies
                .copy("Resources/labelbank_en.txt"),
                .copy("Resources/labelbank_en_curated.txt"),
                .copy("Resources/labelbank_en_large.txt"),
                .copy("Resources/clip-vocab.json"),
                .copy("Resources/clip-merges.txt")
            ]
        ),
        .testTarget(
            name: "DetectionKitTests",
            dependencies: ["DetectionKit"]
        )
    ]
)
