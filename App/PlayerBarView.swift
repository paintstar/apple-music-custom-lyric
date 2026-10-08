import AppKit
import SwiftUI
import ShinAppleKit

/// 歌词库与设置页面的播放条，复用正在播放页的真实播放控制。
struct PlayerBarView: View {
    static let maximumWidth: CGFloat = 700
    private static let horizontalPadding: CGFloat = 16
    private static let trailingControlSpacing: CGFloat = 4
    // 原单行布局宽度加上当前播放列表的槽位及间距，避免新增按钮挤压歌曲信息。
    private static let inlineContentWidth: CGFloat = 528 + PlaybackControlSizing.optionSide + trailingControlSpacing
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var artworkStore: ArtworkStore
    let availableWidth: CGFloat
    var onNowPlaying: (() -> Void)?
    var onToggleLyrics: (() -> Void)?
    var showsLyrics = false
    var trailingMenu: AnyView?
    @State private var isArtworkHovered = false
    @State private var showsPlaybackList = false

    var body: some View {
        VStack(spacing: 6) {
            if availableWidth >= Self.inlineContentWidth + 2 * Self.horizontalPadding {
                HStack(spacing: 14) {
                    PlaybackControlsView(layout: .transport)
                    trackAndProgress
                    trailingControls
                }
            } else {
                VStack(spacing: 6) {
                    trackAndProgress
                    HStack(spacing: 8) {
                        PlaybackControlsView(layout: .transport)
                        Spacer(minLength: 0)
                        trailingControls
                    }
                }
            }
            if let message = model.playbackMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = model.playbackHint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isMock {
                Text("模拟模式 · 不控制「音乐」App")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: Self.maximumWidth)
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 7)
    }

    private var trackAndProgress: some View {
        HStack(spacing: 10) {
            Button { onNowPlaying?() } label: { interactiveArtwork }
                .buttonStyle(.plain)
                .disabled(onNowPlaying == nil)
                .accessibilityLabel("打开完整播放器")
                .help("打开完整播放器")
            VStack(alignment: .leading, spacing: 0) {
                Text(model.currentTitle ?? "未在播放")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .help(model.currentTitle ?? "未在播放")
                Text(model.currentArtist ?? "艺人未知")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.currentArtist ?? "艺人未知")
                PlaybackTimelineProgressView(showsTimeLabels: false, thinStyle: true)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trailingControls: some View {
        HStack(spacing: Self.trailingControlSpacing) {
            lyricsButton
            playbackListButton
            trailingMenu
            PlaybackVolumeButton(model: model.playbackOptions)
        }
    }

    private var playbackListButton: some View {
        Button { showsPlaybackList.toggle() } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: PlaybackControlSizing.iconSize, weight: .medium))
                .foregroundStyle(showsPlaybackList ? Color.appleMusicPink : .secondary)
                .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlaybackButtonStyle(isSelected: showsPlaybackList))
        .accessibilityLabel("当前播放列表")
        .help("显示当前播放列表")
        .popover(isPresented: $showsPlaybackList) {
            PlaybackListView(browser: model.musicLibraryBrowser).environmentObject(model)
        }
    }

    private var interactiveArtwork: some View {
        PlayerArtwork(artwork: artworkStore.currentArtwork, trackKey: model.snapshot.trackKey)
            .frame(width: 44, height: 44)
            .overlay {
                ZStack {
                    Color.black.opacity(0.28)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .opacity(isArtworkHovered ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(isArtworkHovered && !reduceMotion ? 1.055 : 1)
            .animation(.easeOut(duration: 0.16), value: isArtworkHovered)
            .onHover { isArtworkHovered = $0 && onNowPlaying != nil }
    }

    @ViewBuilder
    private var lyricsButton: some View {
        if let onToggleLyrics {
            Button(action: onToggleLyrics) {
                Image(systemName: showsLyrics ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: PlaybackControlSizing.iconSize, weight: .medium))
                    .foregroundStyle(showsLyrics ? Color.appleMusicPink : .secondary)
                    .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 在Button外固定36点槽位的几何边界，状态切换重建的label仍沿父动画移动。
            .geometryGroup()
            .accessibilityLabel(showsLyrics ? "收起当前歌词" : "显示当前歌词")
        }
    }

    static func formatDuration(_ ms: Int64?) -> String {
        guard let ms, ms >= 0 else { return "--:--" }
        let totalSeconds = ms / 1_000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct PlayerTrackInfo: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.currentTitle ?? "未在播放")
                .font(.headline)
                .lineLimit(2)
                .help(model.currentTitle ?? "未在播放")
            if let artist = model.currentArtist {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(artist)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
