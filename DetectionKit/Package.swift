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
                .copy("Resources/clip-merges.txt"),
                // YOLO-World context-specific models
                .copy("Resources/YOLOWorldContexts/yolo_world_kitchen.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_living_room.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_bedroom.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_bathroom.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_office.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_classroom.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_gym.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_park.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_supermarket.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_cafe.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_restaurant.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_street.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_bus_station.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_train_station.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_airport.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_hospital.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_library.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_clothing_store.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_bakery.mlpackage"),
                .copy("Resources/YOLOWorldContexts/yolo_world_pharmacy.mlpackage")
            ]
        ),
        .testTarget(
            name: "DetectionKitTests",
            dependencies: ["DetectionKit"]
        )
    ]
)
