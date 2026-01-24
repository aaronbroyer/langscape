// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "LLMKit",
            targets: ["LLMKit"]
        )
    ],
    dependencies: [
        .package(path: "../Utilities"),
        .package(url: "https://github.com/jkrukowski/swift-sentencepiece", branch: "main")
    ],
    targets: [
        .target(
            name: "LLMKit",
            dependencies: [
                "Utilities",
                .product(name: "SentencepieceTokenizer", package: "swift-sentencepiece")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LLMKitTests",
            dependencies: ["LLMKit"]
        )
    ]
)
