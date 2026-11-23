// swift-tools-version: 6.0
import PackageDescription

// OpenAI 兼容 AI 学习服务提供层。
// 仅在 OpenAICompatibleClient.swift 中持有并调用 URLSession，
// 端点严格限制为 HTTPS 或本地回环地址 HTTP；API Key 仅读写系统钥匙串。
let package = Package(
    name: "ShinAIProvider",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShinAIProvider", targets: ["ShinAIProvider"])
    ],
    dependencies: [
        .package(path: "../ShinAppleKit")
    ],
    targets: [
        .target(
            name: "ShinAIProvider",
            dependencies: [.product(name: "ShinAppleKit", package: "ShinAppleKit")]
        ),
        .testTarget(
            name: "ShinAIProviderTests",
            dependencies: ["ShinAIProvider"]
        )
    ]
)
