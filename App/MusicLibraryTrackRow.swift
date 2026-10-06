import SwiftUI
import ShinAppleKit

/// 喜爱、封面与菜单各自接收点击，只有文字与时长区域承担选择/双击播放。
struct MusicLibraryTrackRow: View {
    @ObservedObject var browser: MusicLibraryBrowserModel
    let track: MusicLibraryTrack
    let isSelected: Bool
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            favoriteControl.frame(width: 20)
            artworkButton
            information
            Menu { menuActions } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(isHovered ? Color.primary : .secondary)
                    .frame(width: 24, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(track.title)的更多操作")
            .help("歌曲选项")
        }
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(isSelected ? 0.11 : isHovered ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) { Divider().padding(.leading, 78).allowsHitTesting(false) }
        .onHover { isHovered = $0 }
        .contextMenu { menuActions }
    }

    @ViewBuilder
    private var favoriteControl: some View {
        if let isFavorite = track.isFavorite {
            Button { browser.setFavorite(track, value: !isFavorite) } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(isFavorite ? Color.appleMusicPink : Color.secondary.opacity(isHovered ? 0.8 : 0.3))
                    .frame(width: 20, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(browser.favoriteWrites.contains(track.trackRef))
            .accessibilityLabel(isFavorite ? "取消喜爱\(track.title)" : "标记喜爱\(track.title)")
            .help(isFavorite ? "取消喜爱" : "标记为喜爱")
        } else {
            Color.clear.frame(width: 20, height: 32).accessibilityHidden(true)
        }
    }

    private var artworkButton: some View {
        Button(action: onPlay) {
            MusicLibraryArtworkView(browser: browser, trackRef: track.trackRef)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    if isCurrent || isHovered {
                        RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.32))
                        Image(systemName: isCurrent && isPlaying ? "waveform" : "play.fill")
                            .font(.caption).foregroundStyle(.white)
                    }
                }
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放\(track.title)")
    }

    private var information: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(PlayerBarView.formatDuration(track.durationMs))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .onTapGesture(perform: onSelect)
        .help([track.title, track.album, track.artist].compactMap { $0 }.joined(separator: " · "))
    }

    private var subtitle: String {
        [track.album, track.artist].compactMap { value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }.joined(separator: " — ")
    }

    @ViewBuilder
    private var menuActions: some View {
        Button("播放", action: onPlay)
        if let isFavorite = track.isFavorite {
            Button(isFavorite ? "取消喜爱" : "标记为喜爱") { browser.setFavorite(track, value: !isFavorite) }
                .disabled(browser.favoriteWrites.contains(track.trackRef))
        }
    }
}
