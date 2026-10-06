// swift-tools-version: 6.0
import PackageDescription

// 纯时间轴查询与偏移引擎，只依赖本地领域模型。
let package = Package(
    name: "ShinLyricsEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShinLyricsEngine", targets: ["ShinLyricsEngine"])
    ],
    dependencies: [
        .package(path: "../ShinAppleKit")
    ],
    targets: [
        .target(name: "ShinLyricsEngine", dependencies: ["ShinAppleKit"]),
        .testTarget(name: "ShinLyricsEngineTests", dependencies: ["ShinLyricsEngine"])
    ]
)
