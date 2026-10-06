// swift-tools-version: 6.0
import PackageDescription

// 网易云歌曲信息与歌词文本获取层，全项目唯一 HTTP 模块。
// 访问 music.163.com 与 interface3.music.163.com，不依赖存储或 UI。
let package = Package(
    name: "ShinLyricsProvider",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShinLyricsProvider", targets: ["ShinLyricsProvider"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ShinLyricsProvider"),
        .testTarget(name: "ShinLyricsProviderTests", dependencies: ["ShinLyricsProvider"])
    ]
)
