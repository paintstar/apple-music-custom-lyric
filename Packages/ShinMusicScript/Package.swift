// swift-tools-version: 6.0
import PackageDescription

// 唯一 Music Apple Events 模块，使用公开脚本词典、ScriptingBridge 和 NSAppleScript。
// 将系统播放与资料库能力适配为本地 ShinAppleKit 协议。
let package = Package(
    name: "ShinMusicScript",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShinMusicScript", targets: ["ShinMusicScript"])
    ],
    dependencies: [
        .package(path: "../ShinAppleKit")
    ],
    targets: [
        // ObjC 工具目标：Swift 无法捕获 ObjC 异常，而 ScriptingBridge 事件
        // 失败可能以 NSException 抛出；全部 SB 调用经其包裹为 NSError。
        .target(name: "ShinMSObjC", publicHeadersPath: "include"),
        .target(
            name: "ShinMusicScript",
            dependencies: [
                "ShinMSObjC",
                .product(name: "ShinAppleKit", package: "ShinAppleKit")
            ]
        ),
        .testTarget(
            name: "ShinMusicScriptTests",
            dependencies: [
                "ShinMusicScript"
            ]
        )
    ]
)
