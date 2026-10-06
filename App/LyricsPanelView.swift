import SwiftUI
import ShinAppleKit
import ShinAppServices

// 歌词区：嵌入播放器页面，处理空态、同步歌词与浏览交互。
// - 空态包括库不可用、加载中、无曲目、无本地歌词和全未打轴；
//   加载失败提供重试入口；开启双语而缺少译文时给出提示；
// - ready：同步高亮（当前组）+ FOLLOW/MANUAL 浏览 + 点击行跳转；
//   切歌过渡态（旧内容置灰 + 「正在阅读非当前播放歌曲」提示条）；
//   偏移/双语/编辑/解除关联收进「···」菜单（SyncLyricsMenu），
//   MANUAL 态出现「回到当前歌词」悬浮胶囊（ResumeFollowingCapsule）；
// - 原文保持固定字号，当前行提高亮度；双语开关改变行高时 FOLLOW 下立即重新定位；
// - 原生文本排版缓存准确坐标，万行文档不创建万行视图。
// - 本视图透明嵌入 Now Playing 页（封面模糊铺底由宿主提供）；
//   「本地歌词库」入口移至侧边栏，库位置说明移至设置页；
//   文档整体替换（过渡 → ready / 编辑保存）以 0.25s ease-in 淡入
//   （reduceMotion 时瞬跳）。
//
// 滚动定位只发生在允许的触发点：
// 当前组变化、恢复跟随、seek（经组变化体现）、FOLLOW 下的窗口尺寸或双语开关变化。
// MANUAL 阅读期间不抢回，空闲后恢复跟随；减少动态效果时不做平滑动画；
// 连续 seek/组变化以新滚动请求取代旧动画。

struct LyricsPanelView: View {
    @EnvironmentObject private var model: AppModel
    /// 右侧栏传入关闭按钮时，将菜单移到同一顶部行；其他播放器沿用正文入口。
    var headerTrailing: AnyView?

    /// 「显示译文」的 UserDefaults 键（@AppStorage；不进歌词库设置表）。
    static let translationsSettingKey = "lyrics.showTranslations"

    var body: some View {
        if let panel = model.lyricsPanel {
            ObservedLyricsPanelView(panel: panel, headerTrailing: headerTrailing)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let headerTrailing {
                    HStack {
                        Spacer(minLength: 0)
                        headerTrailing
                    }
                }
                Text("歌词服务初始化中……")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// AppModel 只发布面板实例的替换；面板异步加载/浏览模式必须直接订阅。
/// 否则暂停时没有播放采样，查询完成或自动回归后的界面会停留在旧状态。
private struct ObservedLyricsPanelView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var panel: LyricsPanelModel
    var headerTrailing: AnyView?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showUnlinkConfirm = false
    @State private var translationHintDocumentKey: LyricsTranslationPolicy.DocumentKey?
    @State private var showsMissingTranslationHint = false
    /// 双语显示开关。持久化方式：@AppStorage → UserDefaults 标准
    /// 域，key 见 `translationsSettingKey`（README 有说明；不入歌词库备份）。
    @AppStorage(LyricsPanelView.translationsSettingKey)
    private var showTranslations = true

    var body: some View {
        VStack(alignment: .leading, spacing: headerTrailing == nil ? 8 : 16) {
            if let headerTrailing {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if case .ready = panel.state { lyricsMenu }
                    headerTrailing
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeIn(duration: 0.25), value: panel.contentChangeKey)
        .confirmationDialog(
            "解除当前曲目的歌词关联？",
            isPresented: $showUnlinkConfirm,
            titleVisibility: .visible
        ) {
            Button("解除关联（歌词文档保留在本机）", role: .destructive) {
                model.unlinkCurrentLyrics()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("解除后该曲目将回到「无本地歌词」状态；已保存的歌词文档不会被删除。")
        }
        .onChange(of: scenePhase) { _, phase in
            // 前台恢复：立即按最近权威快照重算（协调器从不用计时器累加）。
            if phase == .active {
                panel.refreshSyncFromForeground()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.state {
        case let .unavailable(message):
            // 加载失败空态：中文说明 + 可操作「重试」出口。
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") {
                    model.refreshLyricsPanel()
                }
                .help("重新查询当前曲目的本地歌词")
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在查询本地歌词……")
                    .foregroundStyle(.secondary)
            }
        case .noTrack:
            Text(model.isMock
                 ? "选择一首模拟歌曲后，可为它导入本地歌词。"
                 : "在「音乐」App 中选歌播放后，可为它导入本地歌词。")
                .foregroundStyle(.secondary)
        case .unbound:
            unboundContent
        case let .untimedOnly(document):
            untimedContent(document)
        case let .ready(document):
            readyContent(document, panel: panel)
        case let .transitioning(retained, retainedUntimedOnly):
            transitioningContent(retained, untimedOnly: retainedUntimedOnly, panel: panel)
        }
    }

    // MARK: - 空态视图

    private var unboundContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("当前曲目还没有本地歌词。", systemImage: "doc.text")
            Text("可在线获取（网易云音乐），或导入 LRC / 粘贴文本；歌词只保存在本机。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("在线获取…") {
                    model.beginOnlineFetch()
                }
                .disabled(!model.canBeginOnlineFetch)
                .help("按歌名/歌手在网易云音乐搜索并获取歌词，预览确认后保存")
                Button("手动导入") {
                    model.beginImport()
                }
                .disabled(!model.canBeginImport)
                .help("选择 LRC/文本文件或直接粘贴歌词")
            }
        }
    }

    private func untimedContent(_ document: LyricDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("该歌词没有时间轴（全部 \(document.lines.count) 行未打轴），仅静态显示，不参与自动高亮；可在编辑器中补时间。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(staticLines(document, limit: .max))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("编辑歌词") {
                    model.beginLyricsEditing()
                }
                .disabled(!model.canBeginLyricsEditing)
                unlinkButton
            }
        }
    }

    // MARK: 同步视图

    /// 切歌过渡视图：顶部提示条 + 旧文档置灰静态展示。
    /// 新曲目关联到位后整体替换为 ready 视图（淡入，见 content 容器动画）；
    /// 关联失败则由 refresh 落到 unavailable 明确错误态。期间不提供
    /// 编辑/偏移/解除关联（旧文档不是可操作目标）。
    private func transitioningContent(
        _ retained: LyricDocument,
        untimedOnly: Bool,
        panel: LyricsPanelModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("正在阅读非当前播放歌曲；正在载入当前曲目的歌词……", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .help("上一首的歌词仍在展示；当前曲目的歌词载入后会自动替换")
            ScrollView {
                Text(staticLines(retained, limit: .max))
                    .font(untimedOnly ? .callout : .body)
                    .lineSpacing(4)
                    .foregroundStyle(.secondary.opacity(0.6))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor).opacity(0.8), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 18)
                .allowsHitTesting(false)
            }
            if untimedOnly {
                Text("上一首的歌词没有时间轴，静态展示。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func readyContent(_ document: LyricDocument, panel: LyricsPanelModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 歌词菜单：偏移/双语/编辑/解除关联收进歌词区右上角
            // 「···」菜单；「回到当前歌词」仅在 MANUAL 态以悬浮胶囊出现。
            // 来源徽标：在线获取的歌词显示来源与核对状态；
            // 手动导入/人工编辑成果不带任何获取标记（手动优先的呈现面）。
            if let sourceLabel = Self.fetchSourceLabel(document) {
                Label(sourceLabel, systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // 中文原文无需中文译文；外文无译文时保留编辑入口。
            if showTranslations, translationHintDocumentKey == .init(document), showsMissingTranslationHint {
                Label(
                    "这份歌词还没有译文；可在「···」菜单的「编辑歌词」中为每行填写简体中文译文。",
                    systemImage: "text.bubble"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SyncLyricsArea(
                document: document,
                panel: panel,
                showTranslations: showTranslations,
                reduceMotion: reduceMotion,
                onTapLine: { [expected = model.snapshot] lineId in
                    if let target = panel.seekPosition(forLineId: lineId) {
                        model.seek(toMs: target, expectedSnapshot: expected)
                    }
                },
                canSeek: AppModel.canSeek(model.snapshot, isMock: model.isMock) && !panel.isTransitioning
                    && !panel.isAutoScrollSuspended,
                interactionIdentity: "\(model.snapshot.sessionEpoch):\(model.snapshot.trackEpoch):\(model.snapshot.trackKey ?? "")",
                waitingPosition: {
                    guard !panel.isTransitioning, !panel.isAutoScrollSuspended,
                          model.pendingSeek == nil, let position = model.snapshot.positionMs else { return nil }
                    switch model.snapshot.status {
                    case .playing:
                        let estimate = model.estimatedPositionMs(nowMonotonicMs: AppModel.monotonicNowMs())
                        // 过期估计会回到旧样本；用 nil 冻结已显示的圆点，避免倒退闪动。
                        return estimate.isStale ? nil : estimate.positionMs
                    case .paused: return position
                    default: return nil
                    }
                },
                waitingIsPlaying: model.snapshot.status == .playing && model.pendingSeek == nil
                    && !panel.isTransitioning && !panel.isAutoScrollSuspended,
                menu: {
                    if headerTrailing == nil { lyricsMenu }
                }
            )
        }
        // 任务挂在始终存在的正文容器上；空 Group 不会启动 task。
        // 按文档变更计算一次，新文档识别完成前不展示旧结果。
        .task(id: LyricsTranslationPolicy.DocumentKey(document)) {
            guard !Task.isCancelled else { return }
            showsMissingTranslationHint = LyricsTranslationPolicy.shouldShowMissingTranslation(document)
            translationHintDocumentKey = .init(document)
        }
    }

    private var lyricsMenu: some View {
        SyncLyricsMenu(
            panel: panel,
            showTranslations: $showTranslations,
            onUnlink: { showUnlinkConfirm = true },
            onEdit: { model.beginLyricsEditing() }
        )
    }

    /// 在线来源徽标文案；手动导入返回 nil（不显示）。
    private static func fetchSourceLabel(_ document: LyricDocument) -> String? {
        guard document.hasFetchProvenance else { return nil }
        let provider: String
        switch document.fetchProvider {
        case "netease": provider = "网易云音乐"
        case let other?: provider = other
        case nil: return nil
        }
        if document.isAutoFetched && document.isUneditedSinceFetch {
            return "歌词来源：\(provider) · 自动获取，未核对"
        }
        return "歌词来源：\(provider)"
    }


    private var unlinkButton: some View {
        Button("解除关联") {
            showUnlinkConfirm = true
        }
    }

    /// 静态行文本（默认预览前 8 行；过渡视图传 `.max` 展示全部行）。
    private func staticLines(_ document: LyricDocument, limit: Int = 8) -> String {
        let texts = document.lines.map { line in
            line.text.isEmpty ? "（空行）" : line.text
        }
        let prefix = texts.prefix(limit).joined(separator: "\n")
        if texts.count > limit {
            return prefix + "\n……其余 \(texts.count - limit) 行略"
        }
        return prefix
    }
}
