import SwiftUI
import ShinAppleKit
import ShinAppServices

// 歌词区：嵌入播放器页面，处理空态、同步歌词与浏览交互。
// - 空态包括库不可用、加载中、无曲目、无本地歌词和全未打轴；
//   加载失败提供重试入口；
// - ready：同步高亮（当前组）+ FOLLOW/MANUAL 浏览 + 点击行跳转；
//   切歌过渡态（旧内容置灰 + 「正在阅读非当前播放歌曲」提示条）；
//   偏移/双语/编辑/解除关联通过共享菜单提供；
// - 原文保持固定字号，跟随播放时以亮度和清晰度突出当前行；双语开关改变行高时重新定位；
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
    /// 右侧栏传入关闭按钮时，将菜单移到同一顶部行。
    var headerTrailing: AnyView?
    /// 完整与紧凑播放器的歌词动作已合并到顶栏菜单。
    var showsInlineMenu = true

    /// 「显示译文」的 UserDefaults 键（@AppStorage；不进歌词库设置表）。
    static let translationsSettingKey = "lyrics.showTranslations"
    /// 「显示注音」的 UserDefaults 键（@AppStorage；与设置页、悬浮窗互通）。
    static let pronunciationsSettingKey = AISettingsSectionView.pronunciationsSettingKey
    /// 「盲听挖空自测模式（Cloze）」的 UserDefaults 键（@AppStorage）。
    static let clozeModeSettingKey = "lyrics.clozeMode"

    var body: some View {
        if let panel = model.lyricsPanel {
            ObservedLyricsPanelView(panel: panel, headerTrailing: headerTrailing, showsInlineMenu: showsInlineMenu)
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
    var showsInlineMenu: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var unlinkRequest: LyricsUnlinkRequest?
    /// 双语显示开关。持久化方式：@AppStorage → UserDefaults 标准
    /// 域，key 见 `translationsSettingKey`（README 有说明；不入歌词库备份）。
    @AppStorage(LyricsPanelView.translationsSettingKey)
    private var showTranslations = true
    @AppStorage(LyricsPanelView.pronunciationsSettingKey)
    private var showPronunciations = true
    @AppStorage(LyricsPanelView.clozeModeSettingKey)
    private var isClozeMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: headerTrailing == nil ? 8 : 16) {
            if let headerTrailing {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if showsInlineMenu, case .ready = panel.state { lyricsMenu }
                    headerTrailing
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeIn(duration: 0.25), value: panel.contentChangeKey)
        .modifier(LyricsUnlinkConfirmation(request: $unlinkRequest))
        .onChange(of: scenePhase) { _, phase in
            // 前台恢复：立即按最近权威快照重算（协调器从不用计时器累加）。
            if phase == .active {
                panel.refreshSyncFromForeground()
            }
        }
        .onChange(of: panel.currentDocumentId) { _, newDocumentId in
            model.lyricsStudy?.reconcileDocument(id: newDocumentId)
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
        case let .ready(document), let .transitioning(document, false):
            timedContent(document)
        case let .transitioning(retained, true):
            transitioningUntimedContent(retained)
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
            Button("重新检查本地歌词") {
                model.refreshLyricsPanel()
            }
            .font(.caption)
            .help("只重新读取本地关联，不会联网获取或覆盖歌词")
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
            if showsInlineMenu {
                HStack {
                    Button("编辑歌词") {
                        model.beginLyricsEditing()
                    }
                    .disabled(!model.canBeginLyricsEditing)
                    Button("AI 生成注音 / 译文…") {
                        model.beginAIStudyPreview()
                    }
                    .disabled(!model.canBeginAIStudyPreview)
                    unlinkButton
                }
            }
        }
    }

    // MARK: 同步视图

    private var transitionLabel: some View {
        Label("正在阅读非当前播放歌曲；正在载入当前曲目的歌词……", systemImage: "arrow.triangle.2.circlepath")
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .help("上一首的歌词仍在展示；当前曲目的歌词载入后会自动替换")
    }

    private func transitioningUntimedContent(_ retained: LyricDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            transitionLabel
            ScrollView {
                Text(staticLines(retained, limit: .max))
                    .font(.callout)
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
            Text("上一首的歌词没有时间轴，静态展示。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 新曲目加载期间复用已有原生滚动视图，保持原文停在正在阅读的位置。
    private func timedContent(_ document: LyricDocument) -> some View {
        let isTransitioning = panel.isTransitioning
        return timedLyrics(document, isTransitioning: isTransitioning)
            .opacity(isTransitioning ? 0.6 : 1)
            .allowsHitTesting(!isTransitioning)
            .accessibilityHidden(isTransitioning)
            .overlay(alignment: .topLeading) {
                if isTransitioning {
                    transitionLabel
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
    }

    private func timedLyrics(_ document: LyricDocument, isTransitioning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 播放器由顶栏统一提供歌词菜单，独立侧栏保留自己的入口。
            // 来源徽标：在线获取的歌词显示来源与核对状态；
            // 手动导入/人工编辑成果不带任何获取标记（手动优先的呈现面）。
            if let sourceLabel = Self.fetchSourceLabel(document) {
                Label(sourceLabel, systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if panel.activeABLoop != nil || panel.pendingLoopAnchorLineId != nil {
                ABLoopStatusBanner(panel: panel)
            }
            SyncLyricsArea(
                document: document,
                panel: panel,
                showTranslations: showTranslations,
                showPronunciations: showPronunciations,
                isClozeMode: isClozeMode,
                reduceMotion: reduceMotion,
                onTapLine: { [expected = model.snapshot] lineId in
                    if let target = panel.seekPosition(forLineId: lineId) {
                        model.seek(toMs: target, expectedSnapshot: expected)
                    }
                },
                canSeek: AppModel.canSeek(model.snapshot, isMock: model.isMock) && !isTransitioning
                    && !panel.isAutoScrollSuspended,
                interactionIdentity: "\(model.snapshot.sessionEpoch):\(model.snapshot.trackEpoch):\(model.snapshot.trackKey ?? "")",
                waitingPosition: {
                    guard !panel.isTransitioning, !panel.isAutoScrollSuspended,
                          model.pendingSeek == nil, let position = model.snapshot.positionMs else { return nil }
                    switch model.snapshot.status {
                    case .playing:
                        let estimate = model.estimatedPositionMs(nowMonotonicMs: AppModel.monotonicNowMs())
                        // 陈旧样本冻结圆点，等待权威位置恢复。
                        return estimate.isStale ? nil : estimate.positionMs
                    case .paused: return position
                    default: return nil
                    }
                },
                isPlaying: model.snapshot.status == .playing && model.pendingSeek == nil
                    && !panel.isTransitioning && !panel.isAutoScrollSuspended,
                studyModel: isTransitioning ? nil : model.lyricsStudy,
                onToggleSingleLineLoop: isTransitioning ? nil : { lineId in model.toggleSingleLineLoop(lineId: lineId) },
                onSetABLoopAnchor: isTransitioning ? nil : { lineId in model.setABLoopAnchor(lineId: lineId) },
                onCompleteABLoop: isTransitioning ? nil : { lineId in model.completeABLoop(endLineId: lineId) },
                menu: {
                    if !isTransitioning, showsInlineMenu, headerTrailing == nil { lyricsMenu }
                }
            )
            .id("\(document.id):\(panel.displayedTrackKey ?? ""):\(panel.displayedTrackEpoch ?? 0)")
        }
    }

    private var lyricsMenu: some View {
        SyncLyricsMenu(
            panel: panel,
            showTranslations: $showTranslations,
            showPronunciations: $showPronunciations,
            isClozeMode: $isClozeMode,
            onToggleCurrentLineLoop: { model.toggleCurrentLineLoop() },
            onAIStudy: { model.beginAIStudyPreview() },
            onAIKeyPoints: { model.beginAIKeyPoints() },
            onUnlink: { unlinkRequest = LyricsUnlinkRequest(model: model) },
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
            unlinkRequest = LyricsUnlinkRequest(model: model)
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

private struct ABLoopStatusBanner: View {
    @ObservedObject var panel: LyricsPanelModel

    var body: some View {
        if let loop = panel.activeABLoop {
            let isSingle = loop.startLineId == loop.endLineId
            let summary = isSingle
                ? "🔁 单句循环中：\(Self.snippet(loop.startLineText)) · 点击退出"
                : "🔁 AB 复读中：\(Self.snippet(loop.startLineText)) → \(Self.snippet(loop.endLineText)) · 点击退出"
            pillButton(text: summary, tint: Color.appleMusicPink.opacity(0.84), help: "点击退出单句或 AB 循环复读")
        } else if panel.pendingLoopAnchorLineId != nil {
            pillButton(
                text: "📍 已设起点 A · 请右键目标行设终点 B（点击取消）",
                tint: Color.orange.opacity(0.78),
                help: "点击取消待定的 AB 复读起点 A"
            )
        }
    }

    private func pillButton(text: String, tint: Color, help: String) -> some View {
        Button {
            panel.clearABLoop()
        } label: {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tint, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(text)
    }

    private static func snippet(_ text: String) -> String {
        let singleLine = text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !singleLine.isEmpty else { return "当前句" }
        return singleLine.count <= 14 ? singleLine : String(singleLine.prefix(14)) + "…"
    }
}
