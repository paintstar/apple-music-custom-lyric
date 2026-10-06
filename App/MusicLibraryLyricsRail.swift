import SwiftUI

struct MusicLibraryLyricsRail: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var artworkStore: ArtworkStore
    let onClose: () -> Void

    var body: some View {
        ZStack {
            ArtworkBackdrop(artwork: artworkStore.currentArtwork, trackKey: model.snapshot.trackKey)
                .saturation(0.14)
            Color.black.opacity(0.34).ignoresSafeArea()
            LyricsPanelView(headerTrailing: AnyView(closeButton))
                .environment(\.lyricsViewportAnchorFraction, 0.10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.78))
        .help("收起当前歌词")
        .accessibilityLabel("收起当前歌词")
    }
}
