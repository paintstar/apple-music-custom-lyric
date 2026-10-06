import SwiftUI
import ShinAppleKit

// 同步歌词视图组件：歌词面板与播放器页面共用同一套同步渲染。
// - SyncLyricsMenu：右上角「···」菜单，提供偏移、双语、编辑与解除关联；
// - ResumeFollowingCapsule：手动浏览时显示「回到当前歌词」，可立即恢复跟随；
// - SyncLyricsArea：FOLLOW/MANUAL 滚动区 + Apple Music 歌词页排版
//   （固定行字号消除切行抖动，当前行以亮度强调，原生文本准确定位；
//   窄窗口缩 15%，当前行锚定视口上 1/3，减少动态效果时直接定位）。

/// 歌词行排版档位（对标 Apple Music 歌词页）：
/// 数值为项目默认排版参数，随用户文字大小设置缩放
/// （@ScaledMetric），mini 窗口再整体缩 15%。
struct LyricsTypography {
    /// 固定原文字号：切换高亮不会改变行高。
    let lineSize: CGFloat
    /// 译文行：15pt。
    let translationSize: CGFloat
    /// 行内多行时的紧凑行距系数（~1.1）。
    static let lineSpacingFactor: CGFloat = 0.12
    /// 大字歌词组间留白；强调变化不改动间距。
    static let groupSpacing: CGFloat = 30
    /// 原文与译文的间距（紧贴原文行下 4~6pt）。
    static let translationSpacing: CGFloat = 4
    /// 非当前行透明度分层：相邻 0.65，线性衰减到 0.35 封底。
    static func opacity(distance: Int) -> Double {
        guard distance > 0 else { return 1.0 }
        return max(0.35, 0.65 - 0.075 * Double(distance - 1))
    }

    /// 按可用宽度生成的实际档位：窄窗口（mini 形态）整体缩 15%。
    static func resolved(
        line: CGFloat, translation: CGFloat, width: CGFloat
    ) -> LyricsTypography {
        let factor: CGFloat = width < 520 ? 0.85 : 1.0
        return LyricsTypography(
            lineSize: line * factor,
            translationSize: translation * factor
        )
    }
}

/// 同步歌词区常量（泛型视图不能有 static 存储属性，集中放这里）。
enum LyricsSyncConstants {
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

/// 右上角「···」菜单：偏移调整/双语开关/编辑/解除关联（chrome 收纳）。
struct SyncLyricsMenu: View {
    @ObservedObject var panel: LyricsPanelModel
    @Binding var showTranslations: Bool
    let onUnlink: () -> Void
    let onEdit: () -> Void

    var body: some View {
        Menu {
            Section {
                // 偏移当前值以禁用菜单项副标题展示（正数延后/负数提前）。
                Text("偏移：\(panel.syncDisplay.delayDescription)")
                    .help("正数表示歌词比播放延后显示，负数表示提前；保存在本机，刷新后保留")
                Button {
                    panel.adjustDelay(byMs: LyricsPanelModel.delayStepMs)
                } label: {
                    Label("延后 0.1 秒", systemImage: "goforward.100")
                }
                .disabled(!panel.canAdjustDelay)
                Button {
                    panel.adjustDelay(byMs: -LyricsPanelModel.delayStepMs)
                } label: {
                    Label("提前 0.1 秒", systemImage: "gobackward.100")
                }
                .disabled(!panel.canAdjustDelay)
                Button {
                    panel.resetDelay()
                } label: {
                    Label("归零", systemImage: "arrow.counterclockwise")
                }
                .disabled(!panel.canAdjustDelay || panel.syncDisplay.userDelayMs == 0)
            }
            Section {
                Toggle(isOn: $showTranslations) {
                    Label("显示译文", systemImage: "text.bubble")
                }
                .help("开启后，在歌词下方显示简体中文译文；「待复核」标记原文修改后尚未核对的译文")
            }
            Section {
                Button {
                    onEdit()
                } label: {
                    Label("编辑歌词", systemImage: "square.and.pencil")
                }
                .disabled(!canEdit)
                Button(role: .destructive) {
                    onUnlink()
                } label: {
                    Label("解除关联", systemImage: "link.slash")
                }
                .disabled(panel.isTransitioning)
            }
        } label: {
            Color.clear
                .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)
        .overlay {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: PlaybackControlSizing.iconSize))
                .foregroundStyle(.primary.opacity(0.75))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("歌词选项")
        .help("偏移调整、显示译文、编辑歌词与解除关联")
    }

    private var canEdit: Bool {
        panel.currentDocumentId != nil
    }
}

/// 「回到当前歌词」悬浮胶囊：仅在 MANUAL（用户滚离当前行）时出现，
/// 手动浏览期间的恢复跟随入口。
struct ResumeFollowingCapsule: View {
    @ObservedObject var panel: LyricsPanelModel
    let reduceMotion: Bool

    var body: some View {
        // 组切换时字号/字重/透明度平滑过渡与滚动同节奏；reduceMotion 瞬变。
        ZStack {
            if panel.browseMode == .manual {
                Button {
                    panel.resumeFollowing()
                } label: {
                    Label("回到当前歌词", systemImage: "arrow.down.to.line.compact")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                .help("立即恢复跟随；停止浏览约 5 秒后也会自动返回")
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: panel.browseMode)
    }
}

/// 标准播放器与紧凑播放器共用的歌词区。
struct SyncLyricsArea<MenuContent: View>: View {
    @Environment(\.lyricsViewportAnchorFraction) private var viewportAnchorFraction
    let document: LyricDocument
    @ObservedObject var panel: LyricsPanelModel
    let showTranslations: Bool
    let reduceMotion: Bool
    let onTapLine: (UUID) -> Void
    var canSeek = false
    var interactionIdentity = ""
    var waitingPosition: (() -> Int64?)?
    var waitingIsPlaying = false
    @ViewBuilder let menu: () -> MenuContent
    @State private var areaId = UUID()
    @ScaledMetric(relativeTo: .largeTitle) private var lineSize: CGFloat = 30
    @ScaledMetric(relativeTo: .subheadline) private var translationLineSize: CGFloat = 15

    var body: some View {
        GeometryReader { geometry in
            let typography = LyricsTypography.resolved(
                line: lineSize,
                translation: translationLineSize, width: geometry.size.width
            )
            NativeLyricsScrollView(
                document: document,
                typography: typography,
                showTranslations: showTranslations,
                currentLineIds: Set(panel.syncDisplay.currentLineIds ?? []),
                request: panel.scrollRequest,
                followsPlayback: panel.browseMode == .follow && !panel.isAutoScrollSuspended && !panel.isTransitioning,
                reduceMotion: reduceMotion,
                onInteraction: { panel.enterManualBrowsing() },
                onDragStateChange: { panel.setManualInteractionActive($0, in: areaId) },
                onTapLine: onTapLine,
                canSeek: canSeek,
                interactionIdentity: interactionIdentity,
                viewportAnchorFraction: viewportAnchorFraction,
                waitingInterval: panel.syncDisplay.waitingInterval,
                waitingPosition: waitingPosition,
                waitingIsPlaying: waitingIsPlaying
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
            .overlay(alignment: .topTrailing) {
                menu().padding(.trailing, 10).padding(.top, 6)
            }
            .overlay(alignment: .top) {
                ResumeFollowingCapsule(panel: panel, reduceMotion: reduceMotion).padding(.top, 6)
            }
            .onAppear { panel.lyricsAreaAppeared(areaId) }
            .onDisappear { panel.lyricsAreaDisappeared(areaId) }
        }
        .frame(minHeight: 100)
    }
}
