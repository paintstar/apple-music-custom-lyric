import AppKit
import SwiftUI

/// 仅展示当前权威歌词组；不登记主歌词区的浏览状态或创建新的播放监听。
struct FloatingLyricsView: View {
    @ObservedObject var model: AppModel
    let isLocked: Bool
    let onLock: () -> Void
    let onClose: () -> Void
    var onPresentMainWindow: () -> Void = {}
    @AppStorage(LyricsPanelView.translationsSettingKey) private var showsTranslations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @State private var isHovered = false
    @State private var toolbarFrame = CGRect.zero
    @State private var showsSettings = false
    private static let toolbarHeight: CGFloat = 34
    private static let bottomInset: CGFloat = 16
    private static let lyricsAnchor = "floating-current-lyrics"
    private static let coordinateSpace = "floating-lyrics-window"

    private var showsToolbar: Bool { !isLocked && (isHovered || showsSettings || voiceOverEnabled || switchControlEnabled) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    lyricsContent(onContentChange: { proxy.scrollTo(Self.lyricsAnchor, anchor: .top) })
                        .transaction { $0.animation = nil }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(0, geometry.size.height - Self.toolbarHeight - Self.bottomInset))
                        .id(Self.lyricsAnchor)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, 24)
                .padding(.top, Self.toolbarHeight)
                .padding(.bottom, Self.bottomInset)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(showsToolbar ? 0.20 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(showsToolbar ? 0.20 : 0), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .overlay {
            FloatingLyricsDragRegion(isEnabled: !isLocked, excludedRect: showsToolbar ? toolbarFrame : .zero,
                                     onHover: { isHovered = !isLocked && $0 })
        }
        .overlay(alignment: .topLeading) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 28, height: 3)
                .padding(.leading, 16).padding(.top, 16).opacity(showsToolbar ? 1 : 0)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay {
            FloatingLyricsResizeRegion(isEnabled: !isLocked)
        }
        .overlay(alignment: .topTrailing) {
            toolbar.padding(.trailing, 8).padding(.top, 3)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: FloatingLyricsToolbarFramePreference.self,
                                               value: geometry.frame(in: .named(Self.coordinateSpace)))
                    }
                }
                .opacity(showsToolbar ? 1 : 0)
                .allowsHitTesting(showsToolbar)
                .accessibilityHidden(!showsToolbar)
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(FloatingLyricsToolbarFramePreference.self) { toolbarFrame = $0 }
        .contentShape(Rectangle())
        .onChange(of: isLocked) { _, locked in if locked { isHovered = false; showsSettings = false } }
        .animation(reduceMotion || isLocked ? nil : .easeOut(duration: 0.15), value: showsToolbar)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("悬浮歌词")
    }

    @ViewBuilder
    private func lyricsContent(onContentChange: @escaping () -> Void) -> some View {
        if let panel = model.lyricsPanel {
            ObservedFloatingLyricsContent(model: model, panel: panel, showsTranslations: showsTranslations,
                                         onContentChange: onContentChange)
        } else {
            FloatingLyricsText(presentation: FloatingLyricsPresentation.resolve(
                snapshot: model.snapshot, panel: nil,
                display: model.lyricsCoordinator?.currentDisplay() ?? .empty,
                showsTranslations: showsTranslations
            ), onContentChange: onContentChange)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button { showsTranslations.toggle() } label: {
                Image(systemName: showsTranslations ? "character.bubble.fill" : "character.bubble")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PlaybackButtonStyle(isSelected: showsTranslations))
            .foregroundStyle(showsTranslations ? Color.appleMusicPink : .white.opacity(0.82))
            .accessibilityLabel(showsTranslations ? "隐藏悬浮歌词译文" : "显示悬浮歌词译文")
            .help(showsTranslations ? "隐藏译文" : "显示译文")
            Button { showsSettings.toggle() } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }
            .buttonStyle(PlaybackButtonStyle(isSelected: showsSettings))
            .foregroundStyle(.white.opacity(0.82))
            .accessibilityLabel("悬浮歌词设置")
            .help("悬浮歌词设置")
            .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                FloatingLyricsSettingsPopover(model: model, onFetch: {
                    showsSettings = false
                    FloatingLyricsActions.fetch(model, presentMainWindow: onPresentMainWindow)
                }, onImport: {
                    showsSettings = false
                    FloatingLyricsActions.importLyrics(model, presentMainWindow: onPresentMainWindow)
                }, onContinue: {
                    showsSettings = false
                    onPresentMainWindow()
                })
            }
            Button(action: onLock) {
                Image(systemName: "lock").frame(width: 28, height: 28)
            }
            .buttonStyle(PlaybackButtonStyle())
            .foregroundStyle(.white.opacity(0.82))
            .accessibilityLabel("锁定悬浮歌词")
            .help("锁定后鼠标穿透；将鼠标停在歌词上，等待锁标志出现后点击解锁")
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(PlaybackButtonStyle())
            .foregroundStyle(.white.opacity(0.82))
            .accessibilityLabel("关闭悬浮歌词")
            .help("关闭悬浮歌词")
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(.black.opacity(0.32), in: Capsule())
    }
}

private struct FloatingLyricsToolbarFramePreference: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let frame = nextValue()
        // 设置弹窗等子树会传播默认空值，不能覆盖工具条实际测得的位置。
        if !frame.isEmpty { value = frame }
    }
}

/// 面板在暂停时仍能异步加载；直接观察当前实例，存储切换后由外层替换。
private struct ObservedFloatingLyricsContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var panel: LyricsPanelModel
    let showsTranslations: Bool
    let onContentChange: () -> Void

    var body: some View {
        FloatingLyricsText(presentation: FloatingLyricsPresentation.resolve(
            snapshot: model.snapshot, panel: panel,
            display: model.lyricsCoordinator?.currentDisplay() ?? .empty,
            showsTranslations: showsTranslations
        ), onContentChange: onContentChange)
    }
}

private struct FloatingLyricsText: View {
    let presentation: FloatingLyricsPresentation
    let onContentChange: () -> Void
    @ScaledMetric(relativeTo: .title2) private var originalSize = CGFloat(FloatingLyricsSettings.defaultFontSize)
    @ScaledMetric(relativeTo: .body) private var translationSize = CGFloat(FloatingLyricsSettings.defaultTranslationFontSize)
    @AppStorage(FloatingLyricsSettings.fontSizePreferenceKey)
    private var fontSize = FloatingLyricsSettings.defaultFontSize
    @AppStorage(FloatingLyricsSettings.characterSpacingPreferenceKey)
    private var characterSpacing = FloatingLyricsSettings.defaultCharacterSpacing
    private var normalizedFontSize: CGFloat { CGFloat(FloatingLyricsSettings.normalizedFontSize(fontSize)) }
    private var fontScale: CGFloat { normalizedFontSize / CGFloat(FloatingLyricsSettings.defaultFontSize) }
    private var normalizedCharacterSpacing: CGFloat { CGFloat(FloatingLyricsSettings.normalizedCharacterSpacing(characterSpacing)) }
    // 延续原默认排版；字距只影响文字测量，不改变纵向层次。
    private static let wrappedLineSpacing: CGFloat = 3
    private static let translationSpacing: CGFloat = 4
    private static let lyricGroupSpacing: CGFloat = 12

    var body: some View {
        Group {
            switch presentation {
            case let .current(lines):
                VStack(spacing: Self.lyricGroupSpacing) {
                    ForEach(lines) { line in
                        VStack(spacing: Self.translationSpacing) {
                            Text(line.text).tracking(normalizedCharacterSpacing)
                                .font(.system(size: originalSize * fontScale, weight: .semibold))
                            if let translation = line.translation {
                                Text(translation).tracking(normalizedCharacterSpacing)
                                    .font(.system(size: translationSize * fontScale, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.86))
                                if line.translationNeedsReview {
                                    Text("译文待复核").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            case let .waiting(interval):
                message(interval.anchorLineId == nil ? "前奏中，等待歌词…" : "间奏中，等待下一句…")
            case let .message(text):
                message(text)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineSpacing(Self.wrappedLineSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.96), radius: 1)
        .shadow(color: .black.opacity(0.88), radius: 4, x: 0, y: 1)
        .onAppear(perform: onContentChange)
        .onChange(of: presentation) { _, _ in onContentChange() }
        .onChange(of: normalizedCharacterSpacing) { _, _ in onContentChange() }
        .onChange(of: normalizedFontSize) { _, _ in onContentChange() }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.85))
    }
}

struct FloatingLyricsToggleButton: View {
    @ObservedObject var controller: FloatingLyricsWindowController
    let model: AppModel

    private var isPresentedAndLocked: Bool { controller.isPresented && controller.isLocked }
    private var label: String {
        if isPresentedAndLocked { return "解锁悬浮歌词" }
        return controller.isPresented ? "关闭悬浮歌词" : "显示悬浮歌词"
    }
    private var symbol: String {
        if isPresentedAndLocked { return "lock.fill" }
        return controller.isPresented ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle"
    }

    var body: some View {
        Button(action: toggleFloatingLyrics) {
            Image(systemName: symbol)
                .font(.system(size: PlaybackControlSizing.iconSize, weight: .medium))
                .foregroundStyle(controller.isPresented ? Color.appleMusicPink : .secondary)
                .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlaybackButtonStyle(isSelected: controller.isPresented))
        .accessibilityLabel(label)
        .help(isPresentedAndLocked ? "解锁悬浮歌词并保持显示" : label)
        .contextMenu {
            if controller.isPresented {
                Button(controller.isLocked ? "解锁悬浮歌词" : "锁定悬浮歌词") { controller.toggleLock() }
                Button("关闭悬浮歌词") { controller.close() }
            } else {
                Button("显示悬浮歌词") { controller.show(model: model) }
            }
        }
    }

    private func toggleFloatingLyrics() {
        if isPresentedAndLocked { controller.setLocked(false) } else { controller.toggle(model: model) }
    }
}
