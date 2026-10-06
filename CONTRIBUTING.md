# 贡献指南

开始前请阅读 [README](README.md)、[架构](docs/architecture.md) 和 [AGENTS.md](AGENTS.md)，了解播放、网络与本机数据边界。开发环境和构建方式见 [开发者配置](docs/developer-setup.md)。

## 开发原则

- 工程结构由 `project.yml` 声明，修改后运行 `xcodegen generate`；不手工编辑生成的 `ShinApple.xcodeproj`。
- 先完成当前任务的最小可用改动，为关键规则、已知故障和数据安全补充有实际价值的测试；避免提前增加层、接口或依赖。
- Music 自动化只在 `ShinMusicScript` 中使用公开脚本接口，HTTP 只在 `ShinLyricsProvider` 中发送。领域模型和歌词引擎不依赖 UI、播放系统、数据库或网络。
- 数据修改遵守 [迁移规则](docs/migration.md)，事务失败、打开失败和迁移失败均不得清空或重建用户数据库。
- 测试、截图和示例使用原创虚构内容，不提交真实歌词、音乐库清单、环境文件、凭据或签名材料。
- 第三方依赖升级须说明理由并更新 [依赖清单](docs/dependencies.md)；GRDB 当前精确锁定 7.7.0。

## 提交前检查

```bash
bash scripts/ci-local.sh
```

该命令执行六包测试、App typecheck、SwiftLint、密钥检查、出站审计、工程生成与未签名 Release 构建。涉及界面交互时运行对应 GUI 检查，详见开发者配置。

提交前检查完整 diff，确认无用户数据、密钥、本机绝对路径或构建产物。提交信息应简明描述最终变化，例如 `fix(App): 修正歌词滚动位置`。

## Pull Request

说明改动解决的问题、用户可见结果和实际完成的验证。涉及数据模型、存储、安全边界或外部接口时同步更新相关文档。真实「音乐」App 的授权、播放和在线接口联测需要人工进行；将自动化检查与真实环境验证分开说明，未执行的项目如实注明。

报告缺陷时提供系统和工具版本、复现步骤及脱敏后的错误信息。安全问题遵循 [SECURITY.md](SECURITY.md)，不要在公开 issue 中提交漏洞细节。
