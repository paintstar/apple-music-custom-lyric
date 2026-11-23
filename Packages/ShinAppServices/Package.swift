// swift-tools-version: 6.0
import PackageDescription

// 导入、关联、编辑、学习分析与播放歌词协调服务，复用本地领域、存储、时间轴与 AI 提供层。
// 不依赖 UI、播放系统，不直接执行网络请求。
let package = Package(
    name: "ShinAppServices",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShinAppServices", targets: ["ShinAppServices"])
    ],
    dependencies: [
        .package(path: "../ShinAppleKit"),
        .package(path: "../ShinAppleData"),
        .package(path: "../ShinLyricsEngine"),
        .package(path: "../ShinAIProvider")
    ],
    targets: [
        .target(name: "ShinAppServices", dependencies: [
            .product(name: "ShinAppleKit", package: "ShinAppleKit"),
            .product(name: "ShinAppleData", package: "ShinAppleData"),
            .product(name: "ShinLyricsEngine", package: "ShinLyricsEngine"),
            .product(name: "ShinAIProvider", package: "ShinAIProvider")
        ]),
        .testTarget(name: "ShinAppServicesTests", dependencies: ["ShinAppServices"])
    ]
)
