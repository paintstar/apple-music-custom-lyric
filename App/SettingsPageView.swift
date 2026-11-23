import SwiftUI

// 设置页：按分类标签快速定位播放与来源、歌词获取、AI 与学习、歌词显示和本地数据。
// - 播放与来源：授权状态（含「打开自动化权限设置」出口）、退出清理及播放诊断；
// - 歌词获取：网易云音乐自动获取总开关、列表勾选、待确认队列与记录；
// - AI 与学习：AI 服务商、钥匙串密钥、注音偏好与划词窗口尺寸；
// - 歌词显示：「显示译文」「显示注音」与注音字号与主歌词和浮窗互通，悬浮字号和字距与浮窗设置互通，减少动态效果跟随系统；
// - 本地数据：保存位置、歌词资源和备份与导出。

struct SettingsPageView: View {
    @EnvironmentObject private var model: AppModel
    private let initialCategory: SettingsCategory?
    var bottomContentInset: CGFloat
    @AppStorage(SettingsCategory.preferenceKey)
    private var storedCategoryRawValue = SettingsCategory.playback.rawValue
    @AppStorage(PlaybackCleanupSettings.preferenceKey)
    private var cleanupManagedPlaylistsOnQuit = PlaybackCleanupSettings.defaultEnabled
    /// 与歌词面板共享同一键（LyricsPanelView.translationsSettingKey）。
    @AppStorage(LyricsPanelView.translationsSettingKey)
    private var showTranslations = true
    /// 与歌词面板、AI 设置页及悬浮歌词共享同一键。
    @AppStorage(LyricsPanelView.pronunciationsSettingKey)
    private var showPronunciations = true
    @AppStorage(LyricsPronunciationDisplaySettings.fontSizePreferenceKey)
    private var pronunciationFontSize = LyricsPronunciationDisplaySettings.defaultFontSize
    @AppStorage(FloatingLyricsUnlockSettings.delayPreferenceKey)
    private var floatingLyricsUnlockDelay = FloatingLyricsUnlockSettings.defaultDelay
    @AppStorage(LyricsReadingSettings.resumeDelayPreferenceKey)
    private var lyricsResumeDelay = LyricsReadingSettings.defaultResumeDelay
    @AppStorage(FloatingLyricsSettings.fontSizePreferenceKey)
    private var floatingLyricsFontSize = FloatingLyricsSettings.defaultFontSize
    @AppStorage(FloatingLyricsSettings.characterSpacingPreferenceKey)
    private var floatingLyricsCharacterSpacing = FloatingLyricsSettings.defaultCharacterSpacing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedCategory: SettingsCategory
    @State private var isDiagnosticsExpanded = false
    @State private var isResourceManagementPresented = false

    init(initialCategory: SettingsCategory? = nil, bottomContentInset: CGFloat = 100) {
        self.initialCategory = initialCategory
        self.bottomContentInset = bottomContentInset
        let persisted = SettingsCategory(
            rawValue: UserDefaults.standard.string(forKey: SettingsCategory.preferenceKey) ?? ""
        ) ?? .playback
        _selectedCategory = State(initialValue: initialCategory ?? persisted)
    }

    private static let sidebarLayoutMinWidth: CGFloat = 580

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= Self.sidebarLayoutMinWidth {
                HStack(alignment: .top, spacing: 0) {
                    SettingsNavigationSidebar(
                        selectedCategory: selectedCategory,
                        bottomContentInset: bottomContentInset,
                        onSelect: selectCategory
                    )
                    Divider()
                    settingsScrollContent(showsDetailHeader: true)
                }
            } else {
                VStack(spacing: 0) {
                    SettingsCompactNavigationBar(
                        selectedCategory: selectedCategory,
                        onSelect: selectCategory
                    )
                    settingsScrollContent(showsDetailHeader: false)
                }
            }
        }
        .task {
            await model.autoFetch?.reloadState()
        }
        .onAppear {
            if initialCategory == nil,
               let persisted = SettingsCategory(rawValue: storedCategoryRawValue) {
                selectedCategory = persisted
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shinSelectSettingsPage)) { notification in
            let target = notification.object as? SettingsCategory ?? .aiStudy
            selectCategory(target)
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

    private func settingsScrollContent(showsDetailHeader: Bool) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showsDetailHeader {
                        SettingsCategoryDetailHeader(category: selectedCategory)
                    }
                    categoryContent
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // 底部留出悬浮播放条空间。
                .padding(.bottom, max(24, bottomContentInset))
                .id("settings.scrollTop")
            }
            .onChange(of: selectedCategory) { _, _ in
                scrollProxy.scrollTo("settings.scrollTop", anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .playback:
            sourceSection
            diagnosticsSection
        case .autoFetch:
            autoFetchSection
        case .aiStudy:
            aiStudySection
            wordStudyWindowSection
        case .display:
            displaySection
        case .data:
            SettingsDataSectionView(isResourceManagementPresented: $isResourceManagementPresented)
        }
    }

    private func selectCategory(_ category: SettingsCategory) {
        guard selectedCategory != category else {
            if storedCategoryRawValue != category.rawValue {
                storedCategoryRawValue = category.rawValue
            }
            return
        }
        let apply = {
            selectedCategory = category
            storedCategoryRawValue = category.rawValue
        }
        if reduceMotion {
            apply()
        } else {
            withAnimation(.easeInOut(duration: 0.16), apply)
        }
    }

    // MARK: - 播放来源与授权

    private var sourceSection: some View {
        SettingsSectionCard(title: "播放来源") {
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
        SettingsSectionCard(title: "歌词自动获取（网易云音乐）") {
            if let autoFetch = model.autoFetch {
                AutoFetchSettingsContent(model: autoFetch)
            } else {
                Text("歌词库初始化失败，自动获取不可用。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - AI 学习服务

    private var aiStudySection: some View {
        SettingsSectionCard(title: "AI 学习服务") {
            AISettingsSectionView()
        }
    }

    // MARK: - 显示

    private var displaySection: some View {
        let normalizedPronunciationSize = LyricsPronunciationDisplaySettings.normalizedFontSize(pronunciationFontSize)
        return SettingsSectionCard(title: "显示") {
            Toggle("显示简体中文译文", isOn: $showTranslations)
                .help("开启后，在歌词下方显示简体中文译文；「待复核」标记原文修改后尚未核对的译文")
            Toggle("显示歌词注音", isOn: $showPronunciations)
                .help("开启后，在主歌词面板与悬浮歌词原文下方显示逐行注音")
            HStack(spacing: 10) {
                Stepper(value: Binding(
                    get: { LyricsPronunciationDisplaySettings.normalizedFontSize(pronunciationFontSize) },
                    set: { pronunciationFontSize = LyricsPronunciationDisplaySettings.normalizedFontSize($0) }
                ), in: LyricsPronunciationDisplaySettings.fontSizeRange,
                   step: LyricsPronunciationDisplaySettings.fontSizeStep) {
                    Text("注音字体大小：\(formattedSetting(normalizedPronunciationSize)) 点")
                }
                .help("调节主歌词面板与悬浮歌词的逐行注音字号，调整立即生效")
                if normalizedPronunciationSize != LyricsPronunciationDisplaySettings.defaultFontSize {
                    Button("恢复默认") {
                        pronunciationFontSize = LyricsPronunciationDisplaySettings.defaultFontSize
                    }
                    .controlSize(.small)
                }
            }
            Text("作用于主歌词面板与悬浮歌词的逐行注音，调整立即生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var wordStudyWindowSection: some View {
        SettingsSectionCard(title: "划词窗口") {
            WordStudyWindowSettingsControls()
        }
    }

    // MARK: - 播放诊断（默认收起）

    private var diagnosticsSection: some View {
        SettingsSectionCard(title: "播放诊断") {
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
}

/// 跨页面导航通知（设置页 → 主视图切到学习歌曲页；避免向下传绑定的绕线）。
extension Notification.Name {
    static let shinSelectLibraryPage = Notification.Name("shin.selectLibraryPage")
}
