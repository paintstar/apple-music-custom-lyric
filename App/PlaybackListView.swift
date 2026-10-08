import SwiftUI
import ShinAppleKit

struct PlaybackListView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var browser: MusicLibraryBrowserModel
    @StateObject private var list: PlaybackListModel

    private struct PlaybackIdentity: Equatable {
        let trackKey: String?
        let trackEpoch: Int
        let sessionEpoch: Int
    }
    private var playbackIdentity: PlaybackIdentity {
        PlaybackIdentity(trackKey: model.snapshot.trackKey, trackEpoch: model.snapshot.trackEpoch,
                         sessionEpoch: model.snapshot.sessionEpoch)
    }

    init(browser: MusicLibraryBrowserModel) {
        self.browser = browser
        _list = StateObject(wrappedValue: PlaybackListModel(service: browser.browsingService))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("当前播放列表").font(.headline)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                    .buttonStyle(PlaybackButtonStyle())
                    .disabled(list.isLoading)
                    .accessibilityLabel("刷新当前播放列表")
            }
            if let title = list.title {
                Text("\(title) · \(list.tracks.count) 首").font(.callout).foregroundStyle(.secondary)
            }
            if list.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取当前播放列表……").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if list.tracks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(list.message ?? "当前播放列表为空。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试", action: reload)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(list.tracks) { track in row(track).id(track.id) }
                        }
                    }
                    .onAppear {
                        if let currentTrackKey = model.snapshot.trackKey { proxy.scrollTo(currentTrackKey, anchor: .center) }
                    }
                }
                if let message = list.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            Text("随机播放时，实际播放顺序以「音乐」App 为准。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340, height: 440)
        .onAppear(perform: reload)
        .onChange(of: playbackIdentity) { _, _ in reload() }
        .onDisappear { list.cancel() }
    }

    private func row(_ track: MusicLibraryTrack) -> some View {
        let isCurrent = track.trackRef == model.snapshot.trackKey
        return Button { list.play(track) } label: {
            HStack(spacing: 10) {
                MusicLibraryArtworkView(browser: browser, trackRef: track.trackRef)
                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(track.artist ?? "未知艺人").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: model.snapshot.status == .playing ? "waveform" : "pause.fill")
                        .foregroundStyle(Color.appleMusicPink)
                } else {
                    Text(PlayerBarView.formatDuration(track.durationMs)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlaybackButtonStyle(isSelected: isCurrent))
        .disabled(list.isPlayingRequest)
        .accessibilityLabel("播放\(track.title)\(isCurrent ? "，当前歌曲" : "")")
    }

    private func reload() { list.reload(currentTrackKey: model.snapshot.trackKey) }
}
