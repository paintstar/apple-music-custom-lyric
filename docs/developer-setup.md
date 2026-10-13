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

可用 `--arch arm64`、`--arch x86_64` 或 `--arch universal` 指定构建架构，用 `--derived-data .build/其他目录` 隔离派生数据。省略这两个参数时保留原有 Xcode 构建行为，`ci-local.sh` 继续使用 `.build/xcode/`。

应用图标源图为 `Resources/AppIcon-source.png`，macOS 各尺寸位于 `App/Assets.xcassets/AppIcon.appiconset/`，由 `project.yml` 的 AppIcon 设置打包。替换为至少 1024 × 1024 像素的正方形源图后，运行 `bash scripts/generate-app-icon.sh` 更新全部尺寸；脚本只使用 macOS 自带的 `sips`，透明角会保留。

## 安装包

在仓库根目录运行：

```bash
bash scripts/package-release.sh
```

脚本默认构建 Apple Silicon 的未签名 Release App，再对分发副本签名，生成 DMG、ZIP 和发布说明，输出位于 `.build/release/`。DMG 中提供拖到 Applications 的安装入口；ZIP 中只有 App。包名从 App 的版本号及实际 Mach-O 架构生成，构建缓存位于 `.build/release-xcode/`。安装包包含项目及第三方许可证，不包含源码、构建日志、本机数据库或签名材料。

签名默认优先使用本机 `APPLE_SIGNING_IDENTITY`；没有配置时使用 ad-hoc 签名，不启用 Hardened Runtime。可通过 `--signing ad-hoc` 明确选择该模式。0.1.0 已构建 arm64 安装包；Intel 尚未提供，`--arch x86_64` 和 `--arch universal` 仅是其他架构的构建入口，需另行验收。

已有 Developer ID Application 证书的开发者，可在本机配置 `APPLE_SIGNING_IDENTITY` 后执行 `bash scripts/package-release.sh --signing developer-id`。脚本不导入证书，也不输出该配置值；此模式为临时分发副本启用 Hardened Runtime，并添加 `com.apple.security.automation.apple-events` entitlement，保留系统自动化授权。签名身份不是 Developer ID Application 时停止打包。

两种模式均不自动公证；Developer ID 签名也不代表公证成功。对外提供已公证版本时，需使用本机签名与公证配置另行完成 Apple 公证和 stapling，再生成对应分发包并检查。未经公证的安装包首次打开遇到系统提示时，遵循 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

重复打包同一构建可用 `--skip-build`；它会检查缓存 App 的版本、架构、用途说明和许可证，缓存与请求架构不符时停止。未知参数、缺失文件或签名失败不会产生新的最终安装包。脚本不提交代码、不创建或修改 tag、不上传 GitHub Release。发布前执行适用检查，确认发布 tag 对应当前版本的源码，再上传 `.build/release/` 中的 DMG 和 ZIP。

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
bash scripts/floating-lyrics-ui-check.sh
bash scripts/library-scroll-ui-check.sh
bash scripts/auto-fetch-check.sh
```

其他界面检查入口位于 `scripts/`，执行前阅读脚本的用法与范围。真实 Music 授权、实际播放和真实在线接口联测需要人工操作，不属于默认无人值守测试。仅安装 Command Line Tools 无法完成 App 构建，请使用完整 Xcode。

## 数据安全

测试使用隔离目录，不改写用户实际歌词库。真实数据默认位于当前用户 `Application Support/ShinApple/`，可在设置中更改。位置切换、备份与迁移见 [数据迁移](migration.md)。提交前检查 diff，确认无个人路径、真实歌词、音乐库信息、环境文件或凭据。
