import SwiftUI

// 设置页：播放权限、显示偏好、本地数据位置与自动获取。
// - 播放来源与授权状态（含「打开自动化权限设置」出口，语义同原状态区）；
// - 显示偏好：「显示译文」（与歌词面板同一 @AppStorage 键，状态互通）；
// - 减少动态效果：跟随系统辅助功能设置（动效实现处均已遵守），只读呈现；
// - 本地数据：歌词库位置说明与备份提示；真实模式提供「更改保存位置」
//   （选目录 → 在线备份搬数据 → 立即生效，不要求重启）；
// - 开发者调试：原始快照（DisclosureGroup 默认收起，不再是常驻元素）。

struct SettingsPageView: View {
    @EnvironmentObject private var model: AppModel
    var bottomContentInset: CGFloat = 100
    /// 与歌词面板共享同一键（LyricsPanelView.translationsSettingKey）。
    @AppStorage(LyricsPanelView.translationsSettingKey)
    private var showTranslations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDebugExpanded = false
    /// 待确认切换的目标目录（NSOpenPanel 结果；nil = 无待确认操作）。
    @State private var pendingSwitchDirectory: URL?
    @State private var isRestoreDefaultConfirmVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceSection
                autoFetchSection
                displaySection
                dataSection
                debugSection
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            // 底部留出悬浮播放条空间。
            .padding(.bottom, bottomContentInset)
        }
        .task {
            await model.autoFetch?.reloadState()
        }
    }

    // MARK: - 播放来源与授权

    private var sourceSection: some View {
        section(title: "播放来源") {
            switch model.setup {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在初始化……")
                }
            case .automationDenied:
                VStack(alignment: .leading, spacing: 8) {
                    Text("尚未授权自动化：需要允许 ShinApple 控制「音乐」App 以同步歌词。")
                    Button("打开自动化权限设置") {
                        model.openAutomationSettings()
                    }
                    .help("在系统设置 → 隐私与安全性 → 自动化 中允许 ShinApple 控制「音乐」。")
                }
            case .ready:
                Text(model.isMock ? "已就绪（模拟模式：非真实 Apple Music 播放）。" : "已连接「音乐」App 播放。")
            case .failed(let message):
                Text("失败：\(message)")
                    .foregroundStyle(.red)
            }
            if let code = model.snapshot.errorCode {
                Text("最近错误码：\(code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 歌词自动获取

    /// 自动获取区：总开关 + 播放列表勾选 + 待确认队列 + 审计摘要。
    @ViewBuilder
    private var autoFetchSection: some View {
        section(title: "歌词自动获取（网易云音乐）") {
            if let autoFetch = model.autoFetch {
                AutoFetchSettingsContent(model: autoFetch)
            } else {
                Text("歌词库初始化失败，自动获取不可用。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 显示

    private var displaySection: some View {
        section(title: "显示") {
            Toggle("显示简体中文译文", isOn: $showTranslations)
                .help("开启后，在歌词下方显示简体中文译文；「待复核」标记原文修改后尚未核对的译文")
            Text("减少动态效果：跟随系统辅助功能设置（当前 \(reduceMotion ? "已开启：歌词滚动与高亮不做动画" : "未开启：歌词平滑滚动")）。")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 本地数据（含保存位置切换）

    private var dataSection: some View {
        section(title: "本地数据") {
            Text("歌词库位置：\(model.lyricsDatabaseNote)")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.isMock {
                storageLocationControls
            }
            Text("学习资料只保存在本机；JSON 备份是本地文件导出，不上传。数据目录在应用外的普通文件夹中，删除 App 不会自动删除数据，请定期导出完整备份。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开学习歌曲页（歌词库 / 备份 / 导出 LRC）") {
                NotificationCenter.default.post(name: .shinSelectLibraryPage, object: nil)
            }
            .help("歌词库管理：编辑、重新关联、删除、备份与 LRC 导出")
        }
    }

    /// 保存位置控件：位置对照、更改/恢复入口、切换进度与结果（真实模式）。
    @ViewBuilder
    private var storageLocationControls: some View {
        let override = LyricsDatabase.storedOverrideDirectory()
        if override != nil {
            Text("默认位置：\(Self.defaultDirectoryText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 12) {
            Button("更改保存位置…") {
                chooseStorageDirectory()
            }
            .disabled(model.isSwitchingStorage)
            .help("选择一个文件夹存放歌词数据库；现有数据会自动复制过去并立即生效")
            if override != nil {
                Button("恢复默认位置") {
                    isRestoreDefaultConfirmVisible = true
                }
                .disabled(model.isSwitchingStorage)
                .help("把歌词数据库移回默认位置（Application Support/ShinApple）")
            }
        }
        if model.isSwitchingStorage {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在切换保存位置……")
                    .foregroundStyle(.secondary)
            }
        }
        if let message = model.storageSwitchMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        Text("切换立即生效（不需要重启）：数据会以一致性快照复制到新位置，旧位置文件保留作安全副本；切换会关闭未完成的导入/编辑窗口。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        // 切换确认（两处共用一套文案语义：搬运数据 + 关闭未完成窗口）。
        .alert("切换保存位置", isPresented: Binding(
            get: { pendingSwitchDirectory != nil },
            set: { if !$0 { pendingSwitchDirectory = nil } }
        )) {
            Button("切换", role: .destructive) {
                let target = pendingSwitchDirectory
                pendingSwitchDirectory = nil
                guard let target else { return }
                Task { await model.switchLyricsStorage(to: target) }
            }
            Button("取消", role: .cancel) {
                pendingSwitchDirectory = nil
            }
        } message: {
            Text("将把歌词数据库复制到所选文件夹并立即启用。进行中的导入/编辑窗口会被关闭（未保存的草稿会丢失）；旧位置的数据文件会保留作安全副本。")
        }
        .alert("恢复默认位置", isPresented: $isRestoreDefaultConfirmVisible) {
            Button("恢复", role: .destructive) {
                Task { await model.switchLyricsStorage(to: nil) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把歌词数据库复制回默认位置（Application Support/ShinApple）并立即启用；当前自定义位置的数据文件会保留作安全副本。")
        }
    }

    /// 默认目录的展示文案（读取失败时给出可读说明，不伪装成功）。
    private static var defaultDirectoryText: String {
        (try? LyricsDatabase.defaultRealDirectory())?.path ?? "（默认目录不可用）"
    }

    /// 打开系统目录选择面板（AppKit NSOpenPanel；项目允许局部增强）。
    private func chooseStorageDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择歌词数据库的保存文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingSwitchDirectory = url
    }

    // MARK: - 开发者调试（默认收起）

    private var debugSection: some View {
        section(title: "开发者调试") {
            DisclosureGroup("原始播放快照", isExpanded: $isDebugExpanded) {
                Text(model.rawSnapshotDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    /// 分区容器（标题 + 内容卡片）。
    private func section(
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// 跨页面导航通知（设置页 → 主视图切到学习歌曲页；避免向下传绑定的绕线）。
extension Notification.Name {
    static let shinSelectLibraryPage = Notification.Name("shin.selectLibraryPage")
}
