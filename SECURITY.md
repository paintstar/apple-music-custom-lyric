# 安全策略

当前支持版本为 **0.1.0**；后续安全修复以最新版本为准。

## 私下报告

请优先使用仓库安全页面「Security / Security and quality → Report a vulnerability」的 [私下报告入口](https://github.com/paintstar/apple-music-custom-lyric/security/advisories/new)。该功能仅在公开仓库且维护者启用私密漏洞报告后可用；入口不可用时，可创建只请求私下联系的 issue，不提供漏洞细节、复现样本或个人数据，待维护者提供私下渠道后再发送报告。操作说明见 [GitHub 私下报告漏洞指南](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately)。

报告应包含影响、复现步骤、涉及版本和最小示例。请移除歌词、音乐库清单、个人路径、凭据及其他私人数据；在修复可用前避免公开可利用的细节。

## 安全边界

- 学习资料和获取结果保存在本机，应用没有遥测、歌词上传或自建服务端。可选在线获取会向网易云音乐发送搜索词和曲目编号，这是其明确功能范围。
- Music Apple Events 由 `ShinMusicScript` 集中发送，使用公开脚本接口和受验证参数；HTTP 由 `ShinLyricsProvider` 集中发送，访问 `music.163.com` 和 `interface3.music.163.com`，不使用账号凭据。
- 歌词和译文按纯文本渲染，不执行输入中的 HTML 或脚本。
- 非法或不支持的备份在写入前拒绝；数据库打开、迁移及导入失败不得清库或删除用户文件。
- 私钥、服务凭据、环境文件和签名材料不得进入仓库、构建产物、备份或日志。

本地数据库未加密，不用于防御已经取得当前用户文件访问权或管理员权限的攻击者。默认位置、自定义目录及恢复方法见 [README](README.md) 和 [数据迁移](docs/migration.md)。

Apple 系统组件和第三方服务自身的问题应向相应供应商报告。GRDB 上游见 [GRDB.swift](https://github.com/groue/GRDB.swift)。
