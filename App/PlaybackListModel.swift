import Foundation
import ShinAppleKit

/// 弹窗独立读取 Music 的当前播放列表，不复用浏览页或推测系统待播队列。
@MainActor
final class PlaybackListModel: ObservableObject {
    @Published private(set) var tracks: [MusicLibraryTrack] = []
    @Published private(set) var title: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlayingRequest = false
    @Published private(set) var message: String?
    private let service: MusicLibraryBrowsing?
    private var source: MusicLibrarySource?
    private var request: Task<Void, Never>?
    private var playRequest: Task<Void, Never>?
    private var sequence = 0

    init(service: MusicLibraryBrowsing?) { self.service = service }
    deinit { request?.cancel(); playRequest?.cancel() }

    func reload(currentTrackKey: String?) {
        cancel()
        guard let service, let currentTrackKey else {
            message = "当前没有可读取的播放列表。请先选择歌曲播放。"
            return
        }
        let sequence = sequence
        isLoading = true
        request = Task { [weak self] in
            do {
                let source = try await service.currentPlaybackSource()
                try Task.checkCancellation()
                guard let self, sequence == self.sequence else { return }
                guard let source else {
                    self.message = "「音乐」App 暂未提供当前播放列表。"
                    self.isLoading = false
                    return
                }
                let title = try await self.readTitle(for: source, using: service)
                let tracks = try await self.readTracks(in: source, using: service, sequence: sequence)
                let confirmedSource = try await service.currentPlaybackSource()
                try Task.checkCancellation()
                guard sequence == self.sequence else { return }
                guard confirmedSource == source, tracks.contains(where: { $0.trackRef == currentTrackKey }) else {
                    throw MusicLibraryError.contentsChanged
                }
                self.source = source
                self.title = title
                self.tracks = tracks
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled, sequence == self.sequence else { return }
                self.isLoading = false
                self.message = "当前播放列表暂时无法读取，请重试。"
            }
        }
    }

    private func readTitle(for source: MusicLibrarySource, using service: MusicLibraryBrowsing) async throws -> String {
        switch source {
        case .library: return "资料库"
        case let .playlist(id):
            let playlists = try await service.loadPlaylists()
            return playlists.first { $0.id == id }?.name ?? "播放列表"
        }
    }

    private func readTracks(in source: MusicLibrarySource, using service: MusicLibraryBrowsing,
                            sequence: Int) async throws -> [MusicLibraryTrack] {
        var tracks: [MusicLibraryTrack] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            let page = try await service.loadTracks(in: source, offset: offset, limit: MusicLibraryBrowserModel.pageSize)
            try Task.checkCancellation()
            guard sequence == self.sequence else { throw CancellationError() }
            tracks.append(contentsOf: page.tracks.filter { seen.insert($0.id).inserted })
            guard let next = page.nextOffset else { return tracks }
            guard next > offset else { throw MusicLibraryError.contentsChanged }
            offset = next
        }
    }

    func play(_ track: MusicLibraryTrack) {
        guard let service, let source, !isPlayingRequest else { return }
        let sequence = sequence
        isPlayingRequest = true
        message = nil
        playRequest = Task { [weak self] in
            do {
                let confirmedSource = try await service.currentPlaybackSource()
                try Task.checkCancellation()
                guard let self, sequence == self.sequence else { return }
                guard confirmedSource == source else {
                    self.source = nil
                    self.title = nil
                    self.tracks = []
                    throw MusicLibraryError.contentsChanged
                }
                try await service.playTrack(track.trackRef, in: source)
                guard !Task.isCancelled, sequence == self.sequence else { return }
                self.isPlayingRequest = false
            } catch {
                guard let self, !Task.isCancelled, sequence == self.sequence else { return }
                self.isPlayingRequest = false
                self.message = "歌曲未能播放，请刷新列表后重试。"
            }
        }
    }

    func cancel() {
        sequence += 1
        request?.cancel()
        playRequest?.cancel()
        request = nil
        playRequest = nil
        source = nil
        title = nil
        tracks = []
        message = nil
        isLoading = false
        isPlayingRequest = false
    }
}
