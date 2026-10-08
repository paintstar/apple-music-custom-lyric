import Foundation

/// 来自用户 Music 资料库的曲目；persistent ID 属于本机 Music 命名空间，非目录 ID。
public struct MusicLibraryTrack: Identifiable, Equatable, Sendable {
    public var persistentID: String
    public var title: String
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var durationMs: Int64?
    public var isFavorite: Bool?
    public var dateAdded: Date?
    public var trackRef: String { SongBinding.trackKey(persistentID: persistentID) }
    public var id: String { trackRef }

    public init(
        persistentID: String, title: String, artist: String? = nil, albumArtist: String? = nil, album: String? = nil,
        durationMs: Int64? = nil, isFavorite: Bool? = nil, dateAdded: Date? = nil
    ) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.durationMs = durationMs
        self.isFavorite = isFavorite
        self.dateAdded = dateAdded
    }
}

public struct MusicLibraryPlaylist: Identifiable, Equatable, Sendable {
    /// Music 公开脚本词典提供的歌单 persistent ID，不采用可能随排序变化的 index。
    public var id: String
    public var name: String
    public var isFolder: Bool
    public var parentID: String?
    public var isSmart: Bool

    public init(id: String, name: String, isFolder: Bool = false, parentID: String? = nil, isSmart: Bool = false) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.parentID = parentID
        self.isSmart = isSmart
    }
}

public enum MusicLibrarySource: Hashable, Sendable {
    case library
    case playlist(id: String)
}

public struct MusicLibraryTrackPage: Equatable, Sendable {
    public var tracks: [MusicLibraryTrack]
    public var totalCount: Int
    /// nil 表示读至本次查询的末尾；读取过程中资料库变化时由调用方刷新，而非假装原子快照。
    public var nextOffset: Int?

    public init(tracks: [MusicLibraryTrack], totalCount: Int, nextOffset: Int?) {
        self.tracks = tracks
        self.totalCount = totalCount
        self.nextOffset = nextOffset
    }
}

/// 资料库浏览使用分页读取，调用方在切页/取消后丢弃旧请求；不包含云目录搜索或下载。
public protocol MusicLibraryBrowsing: AnyObject, Sendable {
    /// 仅启动 Music 宿主，不激活窗口、不开始播放。
    func prepareMusicInBackground() async throws
    func loadPlaylists() async throws -> [MusicLibraryPlaylist]
    func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage
    /// Music 正在播放的资料库/歌单来源；无法可靠识别时为 nil，不代表系统待播顺序。
    func currentPlaybackSource() async throws -> MusicLibrarySource?
    /// 在原歌单上下文中点播；不改歌单、不临时复制歌曲、不拼接用户文本为脚本。
    func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws
    /// 仅按需读封面原始图像数据；无封面/不支持返回 nil，不包含音频数据。
    func artworkData(for trackRef: String) async throws -> Data?
    /// 用户主动修改喜爱标记，并返回 Music 实际读回值；调用方不可乐观冒充成功。
    func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool
}

public extension MusicLibraryBrowsing {
    func currentPlaybackSource() async throws -> MusicLibrarySource? { nil }
    func artworkData(for trackRef: String) async throws -> Data? { nil }
    func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool { throw MusicLibraryError.unsupported }
}

public enum MusicLibraryError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest
    case sourceUnavailable
    case contentsChanged
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "资料库请求参数无效。"
        case .sourceUnavailable: return "该歌单或曲目已不在资料库中，请刷新后重试。"
        case .contentsChanged: return "读取期间资料库发生变化，请刷新后重试。"
        case .unsupported: return "当前播放连接不支持资料库浏览。"
        }
    }
}
