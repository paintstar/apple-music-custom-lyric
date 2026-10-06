// swift-tools-version: 6.0
import PackageDescription

// 导入、关联、编辑与播放歌词协调服务，复用本地领域、存储和时间轴包。
// 不依赖 UI、播放系统或网络。
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
        .package(path: "../ShinLyricsEngine")
    ],
    targets: [
        .target(name: "ShinAppServices", dependencies: [
            .product(name: "ShinAppleKit", package: "ShinAppleKit"),
            .product(name: "ShinAppleData", package: "ShinAppleData"),
            .product(name: "ShinLyricsEngine", package: "ShinLyricsEngine")
        ]),
        .testTarget(name: "ShinAppServicesTests", dependencies: ["ShinAppServices"])
    ]
)
