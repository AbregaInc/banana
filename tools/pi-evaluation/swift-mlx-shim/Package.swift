// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LocalModelProbe",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .executableTarget(name: "LocalModelProbe", dependencies: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ])
    ]
)
