import SwiftUI
import ShinAppleKit

// 同步歌词视图组件：歌词面板与播放器页面共用同一套同步渲染。
// - SyncLyricsMenu：右上角「···」菜单，提供回到当前歌词、偏移、双语、编辑与解除关联；
// - SyncLyricsArea：FOLLOW/MANUAL 滚动区 + Apple Music 歌词页排版
//   （固定行字号消除切行抖动，当前行以亮度强调，原生文本准确定位；
//   窄窗口缩 15%，当前行锚定视口上 1/3，减少动态效果时直接定位）。

/// 歌词注音显示字号偏好：主歌词面板与悬浮歌词共享同一配置。
enum LyricsPronunciationDisplaySettings {
    static let fontSizePreferenceKey = "lyrics.pronunciationFontSize"
    /// 默认 16pt（窄栏缩 15% 后为 13.6pt），兼顾清晰度与行间留白。
    static let defaultFontSize = 16.0
    static let fontSizeRange: ClosedRange<Double> = 12...32
    static let fontSizeStep = 1.0

    static func normalizedFontSize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound) : defaultFontSize
    }
}

/// 歌词行排版档位（对标 Apple Music 歌词页）：
/// 数值为项目默认排版参数，随用户文字大小设置缩放
/// （@ScaledMetric），mini 窗口再整体缩 15%。
struct LyricsTypography {
    /// 固定原文字号：切换高亮不会改变行高。
    let lineSize: CGFloat
    /// 注音行：默认 16pt（可在设置中调整）。
    let pronunciationSize: CGFloat
    /// 译文行：15pt。
    let translationSize: CGFloat
    /// 行内多行时的紧凑行距系数（~1.1）。
    static let lineSpacingFactor: CGFloat = 0.12
    /// 大字歌词组间留白；强调变化不改动间距。
    static let groupSpacing: CGFloat = 30
    /// 原文与注音的间距。
    static let pronunciationSpacing: CGFloat = 3
    /// 原文/注音与译文的间距（紧贴原文或注音行下 4~6pt）。
    static let translationSpacing: CGFloat = 4
    /// 非当前行透明度分层：相邻 0.65，线性衰减到 0.35 封底。
    static func opacity(distance: Int) -> Double {
        guard distance > 0 else { return 1.0 }
        return max(0.35, 0.65 - 0.075 * Double(distance - 1))
    }

    /// 按可用宽度生成的实际档位：窄窗口（mini 形态）整体缩 15%。
    static func resolved(
        line: CGFloat,
        pronunciation: CGFloat = CGFloat(LyricsPronunciationDisplaySettings.defaultFontSize),
        translation: CGFloat,
        width: CGFloat
    ) -> LyricsTypography {
        let factor: CGFloat = width < 520 ? 0.85 : 1.0
        return LyricsTypography(
            lineSize: line * factor,
            pronunciationSize: pronunciation * factor,
            translationSize: translation * factor
        )
    }
}

/// 同步歌词区常量（泛型视图不能有 static 存储属性，集中放这里）。
enum LyricsSyncConstants {
    /// 等待槽只容纳三点，独立于大字歌词字号，避免空行叠出大块留白。
    static let waitingSlotHeight: CGFloat = 24
    /// 译文语言（v1 固定简体中文；与编辑器一致）。
    static let translationLanguage = "zh-Hans"
    /// 边缘渐隐高度（上下各 80pt，远端行淡出；比逐行 blur 便宜）。
    static let edgeFadeHeight: CGFloat = 80
}

/// 宿主决定当前歌词在视口内的位置；完整播放器沿用上方三分之一。
struct LyricsViewportAnchorKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0 / 3.0

    static func clamped(_ fraction: CGFloat) -> CGFloat {
        fraction.isFinite ? min(max(fraction, 0.05), 0.5) : defaultValue
    }
}

extension EnvironmentValues {
    var lyricsViewportAnchorFraction: CGFloat {
        get { self[LyricsViewportAnchorKey.self] }
        set { self[LyricsViewportAnchorKey.self] = LyricsViewportAnchorKey.clamped(newValue) }
    }
}

/// 顶栏与独立侧栏共用歌词动作，状态变化后重新计算启用状态。
@MainActor
enum LyricsMenuActions {
    static func items(
        panel: LyricsPanelModel?,
        showTranslations: Binding<Bool>,
        showPronunciations: Binding<Bool> = .constant(true),
        isClozeMode: Binding<Bool> = .constant(false),
        onToggleCurrentLineLoop: (() -> Void)? = nil,
        onAIStudy: (() -> Void)? = nil,
        onAIKeyPoints: (() -> Void)? = nil,
        onUnlink: @escaping () -> Void,
        onEdit: @escaping () -> Void
    ) -> [PlaybackMenu.Item] {
        let hasDocument = panel?.currentDocumentId != nil && panel?.isAutoScrollSuspended != true
        let canReturnToCurrentLine = hasDocument && panel?.canReturnToCurrentLine == true
        let canAdjust = panel?.canAdjustDelay == true && hasDocument
        let delay = canAdjust ? panel?.syncDisplay.delayDescription ?? "不可用" : "不可用"
        var result: [PlaybackMenu.Item] = [
            .init(title: "回到当前歌词", symbol: "scope", isEnabled: canReturnToCurrentLine,
                  action: { panel?.resumeFollowing() }),
            .separator,
            .init(title: "偏移：\(delay)", isSectionHeader: true),
            .init(title: "延后 0.1 秒", symbol: "goforward.plus", isEnabled: canAdjust,
                  action: { panel?.adjustDelay(byMs: LyricsPanelModel.delayStepMs) }),
            .init(title: "提前 0.1 秒", symbol: "gobackward.minus", isEnabled: canAdjust,
                  action: { panel?.adjustDelay(byMs: -LyricsPanelModel.delayStepMs) }),
            .init(title: "归零", symbol: "arrow.counterclockwise",
                  isEnabled: canAdjust && panel?.syncDisplay.userDelayMs != 0,
                  action: { panel?.resetDelay() }),
            .separator,
            .init(title: "显示译文", symbol: "text.bubble", isEnabled: hasDocument,
                  isChecked: showTranslations.wrappedValue, action: { showTranslations.wrappedValue.toggle() }),
            .init(title: "显示注音", symbol: "captions.bubble", isEnabled: hasDocument,
                  isChecked: showPronunciations.wrappedValue, action: { showPronunciations.wrappedValue.toggle() }),
            .init(title: "盲听生词挖空", symbol: "eye.slash", isEnabled: hasDocument,
                  isChecked: isClozeMode.wrappedValue, action: { isClozeMode.wrappedValue.toggle() }),
            .separator
        ]
        result.append(contentsOf: loopItems(
            panel: panel,
            hasDocument: hasDocument,
            onToggleCurrentLineLoop: onToggleCurrentLineLoop
        ))
        result.append(.separator)
        let aiSectionItems = aiItems(
            hasDocument: hasDocument,
            onAIStudy: onAIStudy,
            onAIKeyPoints: onAIKeyPoints
        )
        if !aiSectionItems.isEmpty {
            result.append(contentsOf: aiSectionItems)
            result.append(.separator)
        }
        result.append(contentsOf: [
            .init(title: "编辑歌词", symbol: "square.and.pencil", isEnabled: hasDocument, action: onEdit),
            .init(title: "解除关联", symbol: "xmark.circle", isEnabled: hasDocument, action: onUnlink)
        ])
        return result
    }

    private static func loopItems(
        panel: LyricsPanelModel?,
        hasDocument: Bool,
        onToggleCurrentLineLoop: (() -> Void)?
    ) -> [PlaybackMenu.Item] {
        let currentLineId = panel?.syncDisplay.currentLineIds?.first
        let canLoopCurrent = hasDocument
            && currentLineId.map { panel?.canToggleSingleLineLoop(lineId: $0) == true } == true
            && onToggleCurrentLineLoop != nil
        let isLoopingCurrent = currentLineId.map { panel?.isSingleLineLooping(lineId: $0) == true } == true
        let hasLoop = hasDocument && (panel?.activeABLoop != nil || panel?.pendingLoopAnchorLineId != nil)
        return [
            .init(
                title: "循环当前句",
                symbol: "repeat.1",
                isEnabled: canLoopCurrent,
                isChecked: isLoopingCurrent,
                action: { onToggleCurrentLineLoop?() }
            ),
            .init(
                title: "退出 AB 循环",
                symbol: "stop.circle",
                isEnabled: hasLoop,
                action: { panel?.clearABLoop() }
            )
        ]
    }

    private static func aiItems(
        hasDocument: Bool,
        onAIStudy: (() -> Void)?,
        onAIKeyPoints: (() -> Void)?
    ) -> [PlaybackMenu.Item] {
        var items: [PlaybackMenu.Item] = []
        if let onAIStudy {
            items.append(.init(
                title: "AI 生成注音 / 译文…",
                symbol: "sparkles",
                isEnabled: hasDocument,
                action: onAIStudy
            ))
        }
        if let onAIKeyPoints {
            items.append(.init(
                title: "提炼本曲重点词汇…",
                symbol: "book.closed",
                isEnabled: hasDocument,
                action: onAIKeyPoints
            ))
        }
        return items
    }
}

/// 同一菜单可独立展示，或将歌词动作并入播放器顶栏的导航菜单。
struct SyncLyricsMenu: View {
    @ObservedObject var panel: LyricsPanelModel
    @Binding var showTranslations: Bool
    @Binding var showPronunciations: Bool
    @Binding var isClozeMode: Bool
    var onToggleCurrentLineLoop: (() -> Void)?
    var onAIStudy: (() -> Void)?
    var onAIKeyPoints: (() -> Void)?
    let onUnlink: () -> Void
    let onEdit: () -> Void
    var leadingItems: [PlaybackMenu.Item] = []
    var trailingItems: [PlaybackMenu.Item] = []
    var compact = false
    var accessibilityLabel = "歌词选项"
    var help = "回到当前歌词、偏移调整、显示译文、显示注音、盲听挖空、AB 循环、AI 学习、编辑与解除关联"

    var body: some View {
        PlaybackMenu(items: leadingItems + LyricsMenuActions.items(
            panel: panel,
            showTranslations: $showTranslations,
            showPronunciations: $showPronunciations,
            isClozeMode: $isClozeMode,
            onToggleCurrentLineLoop: onToggleCurrentLineLoop,
            onAIStudy: onAIStudy,
            onAIKeyPoints: onAIKeyPoints,
            onUnlink: onUnlink,
            onEdit: onEdit
        ) + trailingItems, iconSize: compact ? 14 : PlaybackControlSizing.iconSize,
                     width: compact ? 28 : PlaybackControlSizing.optionSide,
                     height: compact ? 30 : PlaybackControlSizing.optionSide,
                     accessibilityLabel: accessibilityLabel, help: help)
    }
}

/// 确认期间固定曲目和文档，切歌后不能解除新曲目的关联。
@MainActor
struct LyricsUnlinkRequest {
    let trackKey: String
    let trackEpoch: Int
    let documentId: UUID
    let revision: Int
    private let panelIdentity: ObjectIdentifier

    init?(model: AppModel) {
        guard let trackKey = model.currentTrackKey, let panel = model.lyricsPanel,
              panel.displayedTrackKey == trackKey, panel.displayedTrackEpoch == model.snapshot.trackEpoch,
              let document = panel.currentDocument, !model.isSwitchingStorage else { return nil }
        self.trackKey = trackKey
        trackEpoch = model.snapshot.trackEpoch
        documentId = document.id
        revision = document.revision
        panelIdentity = ObjectIdentifier(panel)
    }

    func matches(_ model: AppModel) -> Bool {
        guard let panel = model.lyricsPanel else { return false }
        return !model.isSwitchingStorage && ObjectIdentifier(panel) == panelIdentity
            && model.currentTrackKey == trackKey && model.snapshot.trackEpoch == trackEpoch
            && panel.displayedTrackKey == trackKey && panel.displayedTrackEpoch == trackEpoch
            && panel.currentDocumentId == documentId && panel.currentDocument?.revision == revision
    }
}

/// 侧栏和播放器顶栏沿用同一破坏性确认，说明共享文档的保留条件。
struct LyricsUnlinkConfirmation: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var request: LyricsUnlinkRequest?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "解除当前曲目的歌词关联？",
            isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            titleVisibility: .visible, presenting: request
        ) { target in
            Button("解除关联并清理歌词", role: .destructive) {
                if target.matches(model) { model.unlinkCurrentLyrics(target) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("解除后该曲目将没有本地歌词。若没有其他歌曲使用这份歌词，将同时删除歌词和人工译文，且无法恢复；仍被其他歌曲使用时只解除当前关联。")
        }
    }
}

/// 标准播放器与紧凑播放器共用的歌词区。
struct SyncLyricsArea<MenuContent: View>: View {
    @Environment(\.lyricsViewportAnchorFraction) private var viewportAnchorFraction
    let document: LyricDocument
    @ObservedObject var panel: LyricsPanelModel
    let showTranslations: Bool
    var showPronunciations = true
    var isClozeMode = false
    let reduceMotion: Bool
    let onTapLine: (UUID) -> Void
    var canSeek = false
    var interactionIdentity = ""
    var waitingPosition: (() -> Int64?)?
    var waitingIsPlaying = false
    var studyModel: LyricsStudyModel?
    var onToggleSingleLineLoop: ((UUID) -> Void)?
    var onSetABLoopAnchor: ((UUID) -> Void)?
    var onCompleteABLoop: ((UUID) -> Void)?
    @ViewBuilder let menu: () -> MenuContent
    @State private var areaId = UUID()
    @State private var isDraggingLyrics = false
    @State private var isStudyPopoverOpen = false
    @State private var clearSelectionToken = 0
    @AppStorage(LyricsPronunciationDisplaySettings.fontSizePreferenceKey)
    private var pronunciationFontSize = LyricsPronunciationDisplaySettings.defaultFontSize
    @ScaledMetric(relativeTo: .largeTitle) private var lineSize: CGFloat = 30
    @ScaledMetric(relativeTo: .subheadline)
    private var pronunciationScaleBase: CGFloat = CGFloat(LyricsPronunciationDisplaySettings.defaultFontSize)
    @ScaledMetric(relativeTo: .subheadline) private var translationLineSize: CGFloat = 15

    var body: some View {
        GeometryReader { geometry in
            let pronunciationScale = pronunciationScaleBase
                / CGFloat(LyricsPronunciationDisplaySettings.defaultFontSize)
            let resolvedPronunciationSize =
                CGFloat(LyricsPronunciationDisplaySettings.normalizedFontSize(pronunciationFontSize))
                * pronunciationScale
            let typography = LyricsTypography.resolved(
                line: lineSize,
                pronunciation: resolvedPronunciationSize,
                translation: translationLineSize,
                width: geometry.size.width
            )
            NativeLyricsScrollView(
                document: document,
                typography: typography,
                showTranslations: showTranslations,
                showPronunciations: showPronunciations,
                currentLineIds: Set(panel.syncDisplay.currentLineIds ?? []),
                request: panel.scrollRequest,
                followsPlayback: panel.browseMode == .follow && !panel.isAutoScrollSuspended && !panel.isTransitioning,
                reduceMotion: reduceMotion,
                onInteraction: { panel.enterManualBrowsing() },
                onDragStateChange: { active in
                    guard isDraggingLyrics != active else { return }
                    isDraggingLyrics = active
                    panel.setManualInteractionActive(active || isStudyPopoverOpen, in: areaId)
                },
                onTapLine: onTapLine,
                canSeek: canSeek,
                interactionIdentity: interactionIdentity,
                viewportAnchorFraction: viewportAnchorFraction,
                waitingInterval: panel.syncDisplay.waitingInterval,
                waitingPosition: waitingPosition,
                waitingIsPlaying: waitingIsPlaying,
                userDelayMs: panel.syncDisplay.userDelayMs,
                vocabularyOccurrences: panel.documentOccurrences,
                isClozeMode: isClozeMode,
                onWordSelection: { selection in studyModel?.updateSelection(selection) },
                onRequestWordStudy: { selection in studyModel?.openWordStudy(from: selection) },
                onRequestLineStudy: { lineId, rect in
                    studyModel?.openLineStudy(document: document, lineId: lineId, anchorRect: rect)
                },
                onRequestLineEdit: { lineId, rect in
                    studyModel?.openLineQuickEdit(document: document, lineId: lineId, anchorRect: rect)
                },
                resolveLineLoopMenuState: { lineId in panel.lineLoopMenuState(for: lineId) },
                onToggleSingleLineLoop: onToggleSingleLineLoop,
                onSetABLoopAnchor: onSetABLoopAnchor,
                onCompleteABLoop: onCompleteABLoop,
                clearSelectionToken: clearSelectionToken
            )
            .mask {
                let edgeHeight = min(LyricsSyncConstants.edgeFadeHeight, geometry.size.height / 6)
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: edgeHeight)
                    Rectangle().fill(.white)
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: edgeHeight)
                }
            }
            .overlay {
                if let studyModel {
                    LyricsStudyOverlayLayer(
                        studyModel: studyModel,
                        document: document,
                        containerSize: geometry.size,
                        onStudyPopoverPresentedChange: { open in
                            guard isStudyPopoverOpen != open else { return }
                            isStudyPopoverOpen = open
                            panel.setManualInteractionActive(isDraggingLyrics || open, in: areaId)
                        },
                        lineLoopMenuState: { lineId in panel.lineLoopMenuState(for: lineId) },
                        onToggleSingleLineLoop: onToggleSingleLineLoop,
                        onClearTextSelection: { clearSelectionToken += 1 }
                    )
                }
            }
            .overlay(alignment: .topTrailing) {
                menu().padding(.trailing, 10).padding(.top, 6)
            }
            .onAppear { panel.lyricsAreaAppeared(areaId) }
            .onDisappear { panel.lyricsAreaDisappeared(areaId) }
        }
        .frame(minHeight: 100)
    }
}
