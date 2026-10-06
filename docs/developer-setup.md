# 开发者配置

工程包含一个 macOS App 和六个本地 Swift 包，部署目标为 macOS 14.0。需要完整 Xcode 26 及以上与 Swift 6；安全审计还需要 Python 3，确保 `python3` 命令可用。优先使用当前机器已配置的工具链。XcodeGen 和 SwiftLint 可通过 Homebrew 安装：

```bash
brew install xcodegen swiftlint
```

## 构建与运行

在仓库根目录运行：

```bash
bash scripts/build.sh Debug --unsigned
open .build/xcode/Build/Products/Debug/ShinApple.app
```

构建 Release 使用 `bash scripts/build.sh Release --unsigned`，输出位于 `.build/xcode/Build/Products/Release/ShinApple.app`。省略 `--unsigned` 时沿用本机 Xcode 签名配置；在 Xcode「Signing & Capabilities」中选择自己的团队，不把团队标识或签名材料写入共享配置。开发构建与对外分发的签名、公证分别处理。

构建脚本先执行 `xcodegen generate`；`project.yml` 是工程配置来源，生成的 `ShinApple.xcodeproj` 不进版本控制。项目使用 Xcode 26 的 Approachable Concurrency 设置，不能将旧 Xcode 工具链等同于当前构建环境。

## Music 权限

官方「音乐」App 负责登录、订阅与音频播放；ShinApple 通过公开脚本访问可用资料库和播放状态。首次访问按 macOS 提示允许自动化控制。权限设置位于「系统设置 → 隐私与安全性 → 自动化」。

当前 App 未启用 App Sandbox，配置在 `App/ShinApple.entitlements`，用途说明在 `App/Info.plist`。拒绝权限时真实资料库与播放不可用，本地歌词功能仍可使用。终端 osascript 与 App 的授权分别由系统处理，应分别验证；签名、Hardened Runtime 和公证配置变化后重新检查 App 授权与控制行为。

## Mock 与检查

```bash
open -n .build/xcode/Build/Products/Debug/ShinApple.app --args --mock
bash scripts/ci-local.sh
```

Mock 使用原创虚构数据和每次新建的临时数据库，不播放音频、不控制 Music、不访问网络。`ci-local.sh` 执行六包测试、App typecheck、SwiftLint、密钥检查、出站审计、工程生成与未签名 Release 构建。

界面改动按范围运行以下检查。GUI 检查应串行执行，避免窗口焦点冲突；首次执行省略 `--skip-build`，之后可复用已构建的依赖，包装脚本仍会编译检查程序：

```bash
bash scripts/library-ui-check.sh
bash scripts/player-ui-check.sh
bash scripts/library-scroll-ui-check.sh
bash scripts/auto-fetch-check.sh
```

其他界面检查入口位于 `scripts/`，执行前阅读脚本的用法与范围。真实 Music 授权、实际播放和真实在线接口联测需要人工操作，不属于默认无人值守测试。仅安装 Command Line Tools 无法完成 App 构建，请使用完整 Xcode。

## 数据安全

测试使用隔离目录，不改写用户实际歌词库。真实数据默认位于当前用户 `Application Support/ShinApple/`，可在设置中更改。位置切换、备份与迁移见 [数据迁移](migration.md)。提交前检查 diff，确认无个人路径、真实歌词、音乐库信息、环境文件或凭据。
