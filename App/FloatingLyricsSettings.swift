import SwiftUI
import ShinAppServices

enum FloatingLyricsSettings {
    static let fontSizePreferenceKey = "floatingLyrics.fontSize"
    // 保留原文 26 点、译文 17 点的默认视觉与比例。
    static let defaultFontSize = 26.0
    static let defaultTranslationFontSize = 17.0
    static let fontSizeRange: ClosedRange<Double> = 16...56
    static let fontSizeStep = 1.0
    // 字距单独存储，避免把旧版纵向间距偏好误用为字距。
    static let characterSpacingPreferenceKey = "floatingLyrics.characterSpacing"
    static let defaultCharacterSpacing = 0.0
    static let characterSpacingRange: ClosedRange<Double> = 0...8
    static let characterSpacingStep = 0.5

    static func normalizedFontSize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound) : defaultFontSize
    }

    static func normalizedCharacterSpacing(_ value: Double) -> Double {
        value.isFinite
            ? min(max(value, characterSpacingRange.lowerBound), characterSpacingRange.upperBound)
            : defaultCharacterSpacing
    }
}

@MainActor
enum FloatingLyricsActions {
    static func hasPresentedSheet(_ model: AppModel) -> Bool {
        model.isImportPresented || model.isLyricsFetchPresented || model.isLyricsEditorPresented || model.isLibraryPresented
    }

    static func fetch(_ model: AppModel, presentMainWindow: () -> Void) {
        presentMainWindow()
        guard !hasPresentedSheet(model), model.canBeginOnlineFetch else { return }
        model.beginOnlineFetch()
    }

    static func importLyrics(_ model: AppModel, presentMainWindow: () -> Void) {
        presentMainWindow()
        guard !hasPresentedSheet(model), model.canBeginImport else { return }
        model.beginImport()
    }
}

struct FloatingLyricsSettingsPopover: View {
    @ObservedObject var model: AppModel
    let onFetch: () -> Void
    let onImport: () -> Void
    var onContinue: () -> Void = {}
    @State private var showsPlaybackList = false
    @AppStorage(FloatingLyricsSettings.fontSizePreferenceKey)
    private var fontSize = FloatingLyricsSettings.defaultFontSize
    @AppStorage(FloatingLyricsSettings.characterSpacingPreferenceKey)
    private var characterSpacing = FloatingLyricsSettings.defaultCharacterSpacing

    private var characterSpacingBinding: Binding<Double> {
        Binding(get: { FloatingLyricsSettings.normalizedCharacterSpacing(characterSpacing) },
                set: { characterSpacing = FloatingLyricsSettings.normalizedCharacterSpacing($0) })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { FloatingLyricsSettings.normalizedFontSize(fontSize) },
                set: { fontSize = FloatingLyricsSettings.normalizedFontSize($0) })
    }

    // 限制菜单视口，新增控制不撑出屏幕；其余内容通过滚动访问。
    private static let contentWidth: CGFloat = 300
    private static let maximumContentHeight: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("悬浮歌词设置").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    playbackControls
                    Divider()
                    if let panel = model.lyricsPanel {
                        FloatingLyricsDelayControls(model: model, panel: panel)
                    } else {
                        Text("歌词时间偏移：不可用").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    lyricsActions
                    Divider()
                    displaySettings
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.maximumContentHeight)
        }
        .padding(16)
        .frame(width: Self.contentWidth)
        // 用系统深色窗口底色覆盖整个弹窗（含原生箭头），不透出后方歌词或桌面。
        .background(Color(nsColor: .windowBackgroundColor))
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaybackControlsView(layout: .transport).environmentObject(model)
                .frame(maxWidth: .infinity)
            HStack {
                Button { showsPlaybackList.toggle() } label: {
                    Label("当前播放列表", systemImage: "list.bullet").padding(.vertical, 6)
                }
                .buttonStyle(PlaybackButtonStyle(isSelected: showsPlaybackList))
                .accessibilityIdentifier("floating-lyrics-playback-list")
                .popover(isPresented: $showsPlaybackList) {
                    PlaybackListView(browser: model.musicLibraryBrowser).environmentObject(model)
                }
                Spacer(minLength: 0)
                PlaybackVolumeButton(model: model.playbackOptions, compact: true)
            }
            if let message = model.playbackMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lyricsActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("在线获取当前歌词", action: onFetch)
                .disabled(!model.canBeginOnlineFetch || FloatingLyricsActions.hasPresentedSheet(model))
                .accessibilityIdentifier("floating-lyrics-fetch")
            Button("手动导入歌词…", action: onImport)
                .disabled(!model.canBeginImport || FloatingLyricsActions.hasPresentedSheet(model))
                .accessibilityIdentifier("floating-lyrics-import")
            if FloatingLyricsActions.hasPresentedSheet(model) {
                Button("继续当前歌词操作", action: onContinue)
                    .accessibilityIdentifier("floating-lyrics-resume")
            }
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: fontSizeBinding, in: FloatingLyricsSettings.fontSizeRange,
                    step: FloatingLyricsSettings.fontSizeStep) {
                Text("悬浮歌词字体大小：\(fontSizeBinding.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) 点")
            }
            .accessibilityIdentifier("floating-lyrics-font-size")
            Text("原文和译文按比例缩放，仅作用于悬浮歌词。")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: characterSpacingBinding, in: FloatingLyricsSettings.characterSpacingRange,
                    step: FloatingLyricsSettings.characterSpacingStep) {
                Text("悬浮歌词字间距：\(characterSpacingBinding.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) 点")
            }
            .accessibilityIdentifier("floating-lyrics-spacing")
            Text("调整字与字之间的距离，仅作用于悬浮歌词。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 独立观察当前面板；切歌过渡、文档切换或编辑挂起时不能修改旧歌词偏移。
private struct FloatingLyricsDelayControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var panel: LyricsPanelModel

    private var canAdjust: Bool {
        panel.canAdjustDelay && panel.currentDocumentId != nil && !panel.isAutoScrollSuspended
            && panel.displayedTrackKey == model.currentTrackKey
            && panel.displayedTrackEpoch == model.snapshot.trackEpoch
    }
    private var stepSeconds: String {
        (Double(LyricsPanelModel.delayStepMs) / 1_000).formatted(.number.precision(.fractionLength(0...1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("歌词时间偏移：\(canAdjust ? panel.syncDisplay.delayDescription : "不可用")")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("提前 \(stepSeconds) 秒") {
                    if canAdjust { panel.adjustDelay(byMs: -LyricsPanelModel.delayStepMs) }
                }
                .disabled(!canAdjust)
                .accessibilityIdentifier("floating-lyrics-delay-earlier")
                Button("延后 \(stepSeconds) 秒") {
                    if canAdjust { panel.adjustDelay(byMs: LyricsPanelModel.delayStepMs) }
                }
                .disabled(!canAdjust)
                .accessibilityIdentifier("floating-lyrics-delay-later")
                Button("归零") {
                    if canAdjust { panel.resetDelay() }
                }
                .disabled(!canAdjust || panel.syncDisplay.userDelayMs == 0)
                .accessibilityIdentifier("floating-lyrics-delay-reset")
            }
            Text("正数延后，负数提前；保存到当前歌曲的歌词设置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
