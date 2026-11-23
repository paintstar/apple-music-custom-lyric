# 依赖与许可证

## 第三方代码

当前唯一远程代码依赖是 [GRDB.swift 7.7.0](https://github.com/groue/GRDB.swift/tree/v7.7.0)，由 `Packages/ShinAppleData/Package.swift` 精确锁定，使用 [MIT License](https://github.com/groue/GRDB.swift/blob/v7.7.0/LICENSE)。它提供本机 SQLite 存储，不承担网络服务。依赖锁文件纳入版本控制；升级须显式修改版本并验证存储、迁移和备份兼容性。

七个本地 Swift 包为 `ShinAppleKit`、`ShinLyricsEngine`、`ShinAppleData`、`ShinAppServices`、`ShinMusicScript`、`ShinLyricsProvider` 和 `ShinAIProvider`，职责见 [架构](architecture.md)。App 与各包使用系统 SwiftUI、AppKit、Foundation、Security（系统钥匙串）、CoreServices（`DictionaryServices` 本机词典）和 NaturalLanguage（语种识别与词元/词性分析）；播放适配使用系统 ScriptingBridge，歌词请求协议编码使用系统 CryptoKit 与 CommonCrypto。

项目未打包真实歌曲、歌词或日语词典。外部获取的歌词与翻译属于第三方内容，不受本项目 MIT 许可证覆盖。

构建会将 [第三方许可声明](../App/Resources/ThirdPartyNotices.txt) 一同放入 App 资源，保留 GRDB 的版权与许可文本。

## 开发工具

Swift Package manifests 使用 `swift-tools-version: 6.0`，App 部署目标为 macOS 14.0。工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成，代码风格由 [SwiftLint](https://github.com/realm/SwiftLint) 检查，安全审计使用 Python 3（`python3`）；这些是开发工具，不作为第三方源码复制进 App。环境配置见 [开发者配置](developer-setup.md)。

## 外部服务与安全

官方「音乐」App 自行处理账号和音频服务，ShinApple 不访问其音频流。`ShinMusicScript` 是唯一发送 Music Apple Events 的模块；`ShinLyricsProvider` 是唯一访问网易云音乐的 HTTP 获取模块，只查询歌曲信息和歌词文本，不读存登录凭据（网易云歌词端点并非官方公开 API，不能保证长期可用）；`ShinAIProvider` 是唯一访问用户配置 OpenAI 兼容学习服务端的 HTTP 模块（仅 `OpenAICompatibleClient.swift` 持有 `URLSession`，强制 HTTPS 或本地回环地址 HTTP），用户自备 API Key 仅保存于系统钥匙串（`com.shinapple.ai-credentials`），不进入数据库、偏好设置、日志或导出备份。

歌词、注音、学习笔记和译文按纯文本渲染，网络结果复用导入校验；应用不提供 HTML 或脚本执行入口。`scripts/audit-outbound.sh` 审计 `ShinMusicScript`、`ShinLyricsProvider`、`ShinAIProvider` 与 `AudioLinkImportService.swift` 的出站及子进程边界，`scripts/check-secrets.sh` 检查危险文件与凭据形态，`scripts/ci-local.sh` 统一执行七包单元测试、纯播放脚本分支检查、App typecheck、`swiftlint lint --strict --quiet`、密钥检查、出站审计与未签名 Release 构建。固定协议常量不是账号凭据，但也不能用白名单绕过真实用户密钥检查。

当前应用无遥测或日志上报。调试日志限于固定阶段和错误码，不应记录原始脚本、歌词、音乐库清单或服务凭据。
