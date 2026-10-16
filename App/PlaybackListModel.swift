import Foundation
import ShinAppleKit

/// 弹窗独立读取 Music 的当前播放列表，不复用浏览页或推测系统待播队列。
@MainActor
final class PlaybackListModel: ObservableObject {
    struct PlaybackIdentity: Equatable {
        let trackKey: String?
        let trackEpoch: Int
        let sessionEpoch: Int
        let contextVersion: Int
    }

    @Published private(set) var tracks: [MusicLibraryTrack] = []
    @Published private(set) var title: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlayingRequest = false
    @Published private(set) var message: String?
    private let service: MusicLibraryBrowsing?
    private var source: MusicLibrarySource?
    var artworkSource: MusicLibrarySource? { source }
    private var request: Task<Void, Never>?
    private var playRequest: Task<Void, Never>?
    private var sequence = 0
    private var playbackIdentity: PlaybackIdentity?
    private var pendingTrackRef: String?
    private var pendingPreviousTrackRef: String?
    private var observedTargetEpoch: Int?
    private var currentTrackKey: String?

    init(service: MusicLibraryBrowsing?) { self.service = service }
    deinit { request?.cancel(); playRequest?.cancel() }

    func synchronize(with identity: PlaybackIdentity) {
        let previous = playbackIdentity
        playbackIdentity = identity
        let sameSession = previous?.sessionEpoch == identity.sessionEpoch
        let sameContext = previous?.contextVersion == identity.contextVersion
        // 自己发出的点歌会先更新快照，后完成来源与成员确认，不能用这个快照取消自己的确认。
        if isPlayingRequest, sameSession, sameContext {
            if identity.trackKey == pendingTrackRef {
                observedTargetEpoch = max(observedTargetEpoch ?? identity.trackEpoch, identity.trackEpoch)
                currentTrackKey = identity.trackKey
                return
            }
            if identity.trackKey == nil { return }
            // 目标曲已出现后，以更新 epoch 回到原曲是外部切歌；旧 epoch 的迟到样本仍可忽略。
            if identity.trackKey == pendingPreviousTrackRef,
               observedTargetEpoch.map({ identity.trackEpoch <= $0 }) ?? true {
                if observedTargetEpoch == nil { currentTrackKey = identity.trackKey }
                return
            }
        }
        let message = isPlayingRequest ? "上次播放请求未完成确认，已重新读取当前播放列表。" : self.message
        reload(currentTrackKey: identity.trackKey, preservingMessage: message)
    }

    func reload(currentTrackKey: String?) {
        let message = isPlayingRequest ? "上次播放请求未完成确认，已重新读取当前播放列表。" : nil
        reload(currentTrackKey: currentTrackKey, preservingMessage: message)
    }

    private func reload(currentTrackKey: String?, preservingMessage: String?) {
        cancelRequests()
        self.currentTrackKey = currentTrackKey
        message = preservingMessage
        guard let service, let currentTrackKey else {
            message = message ?? "当前没有可读取的播放列表。请先选择歌曲播放。"
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
                    self.message = self.message ?? "「音乐」App 暂未提供当前播放列表。"
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
                self.message = self.message ?? "当前播放列表暂时无法读取，请重试。"
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
        guard let service, let source else { return }
        let trackRefs = tracks.map(\.trackRef)
        guard trackRefs.contains(track.trackRef) else { return }
        sequence += 1
        request?.cancel()
        request = nil
        playRequest?.cancel()
        let sequence = sequence
        pendingTrackRef = track.trackRef
        pendingPreviousTrackRef = currentTrackKey
        observedTargetEpoch = nil
        isLoading = false
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
                try await service.playTracks(trackRefs, startingAt: track.trackRef, in: source, shuffleEnabled: nil)
                guard !Task.isCancelled, sequence == self.sequence else { return }
                self.playRequest = nil
                self.reload(currentTrackKey: track.trackRef, preservingMessage: nil)
            } catch {
                guard let self, !Task.isCancelled, sequence == self.sequence else { return }
                self.playRequest = nil
                self.reload(currentTrackKey: self.currentTrackKey,
                            preservingMessage: MusicLibraryBrowserModel.message(for: error, playing: true))
            }
        }
    }

    func cancel() {
        cancelRequests()
        playbackIdentity = nil
        currentTrackKey = nil
    }

    private func cancelRequests() {
        sequence += 1
        request?.cancel()
        playRequest?.cancel()
        request = nil
        playRequest = nil
        pendingTrackRef = nil
        pendingPreviousTrackRef = nil
        observedTargetEpoch = nil
        source = nil
        title = nil
        tracks = []
        message = nil
        isLoading = false
        isPlayingRequest = false
    }
}
