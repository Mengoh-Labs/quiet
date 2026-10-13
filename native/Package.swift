// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Quiet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "quiet", targets: ["QuietCLI"]), .executable(name: "QuietApp", targets: ["QuietApp"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5")
    ],
    targets: [
        .target(name: "QuietCore"),
        .target(name: "QuietSilicon", dependencies: ["QuietCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "Tokenizers", package: "swift-transformers")]),
        .executableTarget(name: "QuietApp", dependencies: ["QuietCore", "QuietSilicon"]),
        .executableTarget(name: "QuietCLI", dependencies: ["QuietCore", "QuietSilicon"]),
        .testTarget(name: "QuietCoreTests", dependencies: ["QuietCore", "QuietSilicon"], exclude: ["README.md"])
    ]
)
