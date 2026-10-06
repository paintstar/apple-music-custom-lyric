import Foundation

/// 原创虚构资料库，仅供 Mock 模式；不读取用户歌曲或任何网络服务。
public enum MockMusicLibrary {
    public static let tracks: [MusicLibraryTrack] = [
        MusicLibraryTrack(persistentID: "A000000000000001", title: "窗边的纸船", artist: "演示歌手甲", album: "晴日手记",
                          durationMs: 180_000, isFavorite: true, dateAdded: Date(timeIntervalSince1970: 1_700_000_003)),
        MusicLibraryTrack(persistentID: "A000000000000002", title: "雨后的长街", artist: "演示歌手甲", album: "晴日手记",
                          durationMs: 210_000, isFavorite: false, dateAdded: Date(timeIntervalSince1970: 1_700_000_002)),
        MusicLibraryTrack(persistentID: "A000000000000003", title: "夜色里的车站", artist: "演示歌手乙", album: "沿途微光",
                          durationMs: 195_000, isFavorite: true, dateAdded: Date(timeIntervalSince1970: 1_700_000_001)),
        MusicLibraryTrack(persistentID: "A000000000000004", title: "青い窓の約束", artist: "演示歌手乙", album: "沿途微光",
                          durationMs: 165_000, isFavorite: false, dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
    ]

    public static let playlists: [MusicLibraryPlaylist] = [
        MusicLibraryPlaylist(id: "B000000000000001", name: "学习歌单", isFolder: true),
        MusicLibraryPlaylist(id: "B000000000000002", name: "每日轻听", parentID: "B000000000000001"),
        MusicLibraryPlaylist(id: "B000000000000003", name: "夜晚练习"),
        MusicLibraryPlaylist(id: "B000000000000004", name: "空白歌单")
    ]

    static func tracks(in source: MusicLibrarySource) throws -> [MusicLibraryTrack] {
        switch source {
        case .library: return tracks
        case .playlist(id: "B000000000000001"): return []
        case .playlist(id: "B000000000000002"): return [tracks[0], tracks[1], tracks[3]]
        case .playlist(id: "B000000000000003"): return [tracks[2], tracks[3]]
        case .playlist(id: "B000000000000004"): return []
        case .playlist: throw MusicLibraryError.sourceUnavailable
        }
    }
}

extension MockPlaybackController: MusicLibraryBrowsing {
    public func prepareMusicInBackground() async throws {
        try Task.checkCancellation()
    }

    public func loadPlaylists() async throws -> [MusicLibraryPlaylist] {
        try Task.checkCancellation()
        return MockMusicLibrary.playlists
    }

    public func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        try Task.checkCancellation()
        guard offset >= 0, (1...500).contains(limit) else { throw MusicLibraryError.invalidRequest }
        let overrides = mockLibraryFavorites.withLock { $0 }
        let tracks = try MockMusicLibrary.tracks(in: source).map { track in
            var copy = track
            copy.isFavorite = overrides[track.trackRef] ?? track.isFavorite
            return copy
        }
        let start = min(offset, tracks.count)
        let end = start + min(limit, tracks.count - start)
        return MusicLibraryTrackPage(tracks: Array(tracks[start..<end]), totalCount: tracks.count,
                                     nextOffset: end < tracks.count ? end : nil)
    }

    public func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws {
        try Task.checkCancellation()
        let tracks = try MockMusicLibrary.tracks(in: source)
        guard let index = tracks.firstIndex(where: { $0.trackRef == trackRef }) else {
            throw MusicLibraryError.sourceUnavailable
        }
        setMockQueue(tracks.map { track in
            MockTrack(identity: CatalogIdentity(storefront: "mock", catalogSongId: track.persistentID),
                      title: track.title, artist: track.artist, durationMs: track.durationMs, trackRef: track.trackRef)
        }, startAt: index)
    }

    public func playTrackRef(_ trackRef: String) async throws {
        do {
            try await playTrack(trackRef, in: .library)
        } catch MusicLibraryError.sourceUnavailable {
            throw PlaybackError.trackUnavailable
        }
    }

    public func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool {
        try Task.checkCancellation()
        guard MockMusicLibrary.tracks.contains(where: { $0.trackRef == trackRef }) else {
            throw MusicLibraryError.sourceUnavailable
        }
        mockLibraryFavorites.withLock { $0[trackRef] = value }
        return value
    }
}
