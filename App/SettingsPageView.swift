import SwiftUI

// 设置页：播放权限、显示偏好、本地数据位置与自动获取。
// - 播放来源与授权状态（含「打开自动化权限设置」出口，语义同原状态区）；
// - 显示偏好：「显示译文」与歌词面板互通，悬浮字号和字距与浮窗设置互通；
// - 减少动态效果：跟随系统辅助功能设置（动效实现处均已遵守），只读呈现；
// - 本地数据：保存位置、歌词资源和备份与导出；
// - 播放诊断：默认收起的只读播放快照。

struct SettingsPageView: View {
    @EnvironmentObject private var model: AppModel
    var bottomContentInset: CGFloat = 100
    @AppStorage(PlaybackCleanupSettings.preferenceKey)
    private var cleanupManagedPlaylistsOnQuit = PlaybackCleanupSettings.defaultEnabled
    /// 与歌词面板共享同一键（LyricsPanelView.translationsSettingKey）。
    @AppStorage(LyricsPanelView.translationsSettingKey)
    private var showTranslations = true
    @AppStorage(FloatingLyricsUnlockSettings.delayPreferenceKey)
    private var floatingLyricsUnlockDelay = FloatingLyricsUnlockSettings.defaultDelay
    @AppStorage(LyricsReadingSettings.resumeDelayPreferenceKey)
    private var lyricsResumeDelay = LyricsReadingSettings.defaultResumeDelay
    @AppStorage(FloatingLyricsSettings.fontSizePreferenceKey)
    private var floatingLyricsFontSize = FloatingLyricsSettings.defaultFontSize
    @AppStorage(FloatingLyricsSettings.characterSpacingPreferenceKey)
    private var floatingLyricsCharacterSpacing = FloatingLyricsSettings.defaultCharacterSpacing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDiagnosticsExpanded = false
    @State private var isResourceManagementPresented = false
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
                diagnosticsSection
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
        .sheet(isPresented: $isResourceManagementPresented) {
            if let library = model.library {
                LocalResourceManagementView(library: library)
                    .id(ObjectIdentifier(library))
            }
        }
        .onChange(of: model.library.map(ObjectIdentifier.init)) { _, _ in
            isResourceManagementPresented = false
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
            Toggle("退出时清理应用临时播放清单", isOn: $cleanupManagedPlaylistsOnQuit)
            Text("清理前会停止「音乐」播放；只删除应用创建且未被修改的临时清单，用户修改过的清单会保留。关闭窗口不会触发清理。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Stepper(value: Binding(
                get: { LyricsReadingSettings.normalized(lyricsResumeDelay) },
                set: { lyricsResumeDelay = LyricsReadingSettings.normalized($0) }
            ), in: LyricsReadingSettings.resumeDelayRange, step: LyricsReadingSettings.resumeDelayStep) {
                Text("自动回到当前歌词：空闲 \(formattedSetting(LyricsReadingSettings.normalized(lyricsResumeDelay))) 秒")
            }
            .help("停止滚动、拖动或选词达到等待时间后，自动跟随当前歌词；调整立即生效")
            Stepper(value: Binding(
                get: { FloatingLyricsSettings.normalizedFontSize(floatingLyricsFontSize) },
                set: { floatingLyricsFontSize = FloatingLyricsSettings.normalizedFontSize($0) }
            ), in: FloatingLyricsSettings.fontSizeRange, step: FloatingLyricsSettings.fontSizeStep) {
                Text("悬浮歌词字体大小：\(formattedSetting(FloatingLyricsSettings.normalizedFontSize(floatingLyricsFontSize))) 点")
            }
            .help("原文和译文按比例缩放，仅作用于悬浮歌词。")
            Stepper(value: Binding(
                get: { FloatingLyricsSettings.normalizedCharacterSpacing(floatingLyricsCharacterSpacing) },
                set: { floatingLyricsCharacterSpacing = FloatingLyricsSettings.normalizedCharacterSpacing($0) }
            ), in: FloatingLyricsSettings.characterSpacingRange, step: FloatingLyricsSettings.characterSpacingStep) {
                Text("悬浮歌词字间距：\(formattedSetting(FloatingLyricsSettings.normalizedCharacterSpacing(floatingLyricsCharacterSpacing))) 点")
            }
            .help("调整字与字之间的距离，仅作用于悬浮歌词。")
            Stepper(value: $floatingLyricsUnlockDelay, in: FloatingLyricsUnlockSettings.delayRange,
                    step: FloatingLyricsUnlockSettings.delayStep) {
                Text("悬浮歌词解锁等待：\(floatingLyricsUnlockDelay.formatted(.number.precision(.fractionLength(0...1)))) 秒")
            }
            .help("锁定后持续将鼠标放在悬浮歌词上，等待指定时间显示解锁按钮；调整立即生效")
            Text("锁定歌词后，鼠标停在歌词上会显示可点击的锁标志；移出歌词即隐藏。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("减少动态效果：跟随系统辅助功能设置（当前 \(reduceMotion ? "已开启：歌词滚动与高亮不做动画" : "未开启：歌词平滑滚动")）。")
                .foregroundStyle(.secondary)
        }
    }

    private func formattedSetting(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    // MARK: - 本地数据（含保存位置切换）

    private var dataSection: some View {
        let usesCustomLocation = !model.isMock && LyricsDatabase.storedOverrideDirectory() != nil
        return section(title: "本地数据") {
            VStack(alignment: .leading, spacing: 12) {
                dataRow("保存位置", symbol: "folder") {
                    storageLocationDetails(usesCustomLocation: usesCustomLocation)
                } actions: {
                    if !model.isMock {
                        storageLocationControls(usesCustomLocation: usesCustomLocation)
                    }
                }
                Divider()
                dataRow("本地歌词资源", symbol: "tray.full") {
                    Text("查看或清理本机保存的歌词与译文。")
                } actions: {
                    Button("管理资源…") { isResourceManagementPresented = true }
                        .disabled(model.library == nil || model.isSwitchingStorage)
                }
                Divider()
                dataRow("备份与导出", symbol: "archivebox") {
                    Text("导入或导出完整 JSON 备份，也可导出 LRC 歌词。")
                } actions: {
                    Button("打开学习歌曲") {
                        NotificationCenter.default.post(name: .shinSelectLibraryPage, object: nil)
                    }
                }
            }
            Text("学习资料与备份都保存在本机。卸载 App 后，数据文件仍保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
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
            Text(Self.storageSwitchExplanation)
        }
        .alert("恢复默认位置", isPresented: $isRestoreDefaultConfirmVisible) {
            Button("恢复", role: .destructive) {
                Task { await model.switchLyricsStorage(to: nil) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.storageSwitchExplanation)
        }
    }

    private func dataRow<Details: View, Actions: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder details: () -> Details,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let heading = Text(title).font(.callout.weight(.semibold))
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        heading
                        Spacer(minLength: 0)
                        actions().fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        heading
                        actions()
                    }
                }
                details()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let storageSwitchExplanation =
        "目标位置没有歌词库时会复制当前资料。已有歌词库时会直接打开该库，两个库各自保留。"
        + "切换立即生效，原位置的数据保留。打开的导入和编辑窗口会关闭，未保存的内容将丢失。"

    private func storageLocationControls(usesCustomLocation: Bool) -> some View {
        HStack(spacing: 8) {
            Button("更改位置…", action: chooseStorageDirectory)
                .help("选择要使用的歌词库文件夹")
            if usesCustomLocation {
                Button("恢复默认位置") { isRestoreDefaultConfirmVisible = true }
            }
        }
        .disabled(model.isSwitchingStorage || model.library?.isDeletingResources == true)
    }

    @ViewBuilder
    private func storageLocationDetails(usesCustomLocation: Bool) -> some View {
        if let directory = model.lyricsDatabaseDirectory {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isMock ? "模拟模式 · 临时目录" : usesCustomLocation ? "自定义位置" : "默认位置")
                Text((directory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .help(directory.path)
                    .contextMenu {
                        Button("复制完整路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(directory.path, forType: .string)
                        }
                    }
            }
        } else {
            Text(model.lyricsDatabaseNote)
                .textSelection(.enabled)
        }
        if !model.isMock {
            if model.isSwitchingStorage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在切换保存位置……")
                }
            }
            if let message = model.storageSwitchMessage {
                Text(message)
                    .textSelection(.enabled)
            }
        }
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

    // MARK: - 播放诊断（默认收起）

    private var diagnosticsSection: some View {
        section(title: "播放诊断") {
            Text("用于排查播放异常和歌词不同步，查看「音乐」上报的播放状态、进度和错误码。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("查看原始播放快照", isExpanded: $isDiagnosticsExpanded) {
                Text(model.rawSnapshotDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
