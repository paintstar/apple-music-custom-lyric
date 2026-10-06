// swift-tools-version: 6.0
import PackageDescription

// 领域模型、解析、协议与 Mock，不依赖 UI、播放系统、网络或数据库。
let package = Package(
    name: "ShinAppleKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShinAppleKit", targets: ["ShinAppleKit"])
    ],
    targets: [
        .target(name: "ShinAppleKit"),
        .testTarget(name: "ShinAppleKitTests", dependencies: ["ShinAppleKit"])
    ]
)
