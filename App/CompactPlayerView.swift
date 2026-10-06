import SwiftUI

/// 小窗口以封面和歌词为主；鼠标浮入时显示上方控制，不改变歌词布局。
struct CompactPlayerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @ObservedObject var artworkStore: ArtworkStore
    var topControls: AnyView?
    @State private var showsControls = false

    var body: some View {
        GeometryReader { geometry in
            let coverHeight = min(geometry.size.width, geometry.size.height * 0.5)
            let controlsVisible = showsControls || voiceOverEnabled || switchControlEnabled
            ZStack(alignment: .top) {
                ArtworkBackdrop(artwork: artworkStore.currentArtwork, trackKey: model.snapshot.trackKey)
                    .saturation(0.18)
                    .overlay(Color.black.opacity(0.5).allowsHitTesting(false))
                PlayerArtwork(artwork: artworkStore.currentArtwork, trackKey: model.snapshot.trackKey)
                    .frame(height: coverHeight)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.68),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Color.clear.frame(height: coverHeight).allowsHitTesting(false)
                    PlaybackStatusView(compact: true)
                    LyricsPanelView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                }
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.currentTitle ?? "未在播放")
                                .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text(model.currentArtist ?? "艺人未知")
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        PlaybackControlsView()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
                .frame(height: coverHeight)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controlsVisible)
                HStack {
                    Spacer(minLength: 0)
                    topControls
                }
                .padding(8)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controlsVisible)
            }
            .contentShape(Rectangle())
            .onHover { showsControls = $0 }
            .clipped()
        }
        .environment(\.colorScheme, .dark)
    }
}

/// 在两种播放器尺寸中都保留可恢复的权限、环境与模拟模式说明。
struct PlaybackStatusView: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isMock {
                Label("模拟模式 · 不控制「音乐」App", systemImage: "ladybug")
                    .foregroundStyle(.orange)
            }
            switch model.setup {
            case .loading:
                Label("正在初始化……", systemImage: "hourglass")
            case .automationDenied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("需要允许 ShinApple 控制「音乐」App，才能同步播放与歌词。")
                    Button("打开自动化权限设置") { model.openAutomationSettings() }
                        .controlSize(.small)
                }
            case .failed(let message):
                Label("失败：\(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .ready:
                if let hint = model.playbackHint { Text(hint) }
            }
        }
        .font(compact ? .caption : .callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 18 : 28)
        .padding(.vertical, needsStatus ? 8 : 0)
    }

    private var needsStatus: Bool {
        if model.isMock || model.playbackHint != nil { return true }
        if case .ready = model.setup { return false }
        return true
    }
}
