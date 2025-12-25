// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "USDZSimplifier",
    platforms: [
        .iOS("18.0"), .macOS("15.0"), .visionOS("2.0")
    ],
    products: [
        // 库产品：供其他 Swift 项目使用
        .library(
            name: "USDZSimplifier",
            targets: ["USDZSimplifier"]),
        // 命令行工具产品
        .executable(
            name: "usdzutil",
            targets: ["usdzutil"])
    ],
    dependencies: [
        // ArgumentParser 用于命令行参数解析
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
        // meshoptimizer - 使用本地路径（如果存在）或 GitHub 版本
        .package(url: "https://github.com/cqj1558/meshoptimizer.git", branch: "master"),
    ],
    targets: [
        // 核心库
        .target(
            name: "USDZSimplifier",
            dependencies: [
                .product(name: "meshoptimizer", package: "meshoptimizer")
            ],
            path: "Sources/USDZSimplifier"),
        
        // 命令行工具
        .executableTarget(
            name: "usdzutil",
            dependencies: [
                "USDZSimplifier",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/usdzutil"),
        
        // 测试目标（可选，暂时注释掉）
        // .testTarget(
        //     name: "USDZSimplifierTests",
        //     dependencies: ["USDZSimplifier"]),
    ]
)

