// swift-tools-version: 6.0
import PackageDescription

// 本地 SQLite 存储、事务、迁移与完整备份，不依赖播放系统或网络。
let package = Package(
    name: "ShinAppleData",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShinAppleData", targets: ["ShinAppleData"])
    ],
    dependencies: [
        .package(path: "../ShinAppleKit"),
        // 精确锁定存储引擎，升级需验证迁移与备份兼容性。
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.7.0"
        )
    ],
    targets: [
        .target(name: "ShinAppleData", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "ShinAppleKit", package: "ShinAppleKit")
        ]),
        .testTarget(
            name: "ShinAppleDataTests",
            dependencies: [
                "ShinAppleData",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
