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
    /// 在已有歌单上下文中点播，不修改该歌单。
    func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws
    /// 将当前可见曲目建立为真实播放上下文；只复制 Music 曲目引用，不读取音频。
    /// nil 随机状态表示保留 Music 当前设置；有值时先建立上下文再设置并确认。
    func playTracks(_ trackRefs: [String], startingAt trackRef: String, in source: MusicLibrarySource,
                    shuffleEnabled: Bool?) async throws
    /// 随机播放完整可见集合，由 Music 选择首曲；完整原歌单可直接播放，筛选集合保持成员隔离。
    func shuffleTracks(_ trackRefs: [String], in source: MusicLibrarySource) async throws
    /// 仅按需读封面原始图像数据；无封面/不支持返回 nil，不包含音频数据。
    func artworkData(for trackRef: String) async throws -> Data?
    /// 用户主动修改喜爱标记，并返回 Music 实际读回值；调用方不可乐观冒充成功。
    func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool
}

public extension MusicLibraryBrowsing {
    func playTracks(_ trackRefs: [String], startingAt trackRef: String, in source: MusicLibrarySource,
                    shuffleEnabled: Bool?) async throws { throw MusicLibraryError.unsupported }
    func shuffleTracks(_ trackRefs: [String], in source: MusicLibrarySource) async throws { throw MusicLibraryError.unsupported }
    func currentPlaybackSource() async throws -> MusicLibrarySource? { nil }
    func artworkData(for trackRef: String) async throws -> Data? { nil }
    func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool { throw MusicLibraryError.unsupported }
}

public enum MusicLibraryError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest
    case sourceUnavailable
    case contentsChanged
    case playbackModeUnconfirmed
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "资料库请求参数无效。"
        case .sourceUnavailable: return "当前无法在资料库中找到该歌单或曲目，请刷新后重试。"
        case .contentsChanged: return "读取期间资料库发生变化，请刷新后重试。"
        case .playbackModeUnconfirmed: return "列表已开始播放，但随机播放状态未能确认。请检查「音乐」App 后重试。"
        case .unsupported: return "当前播放连接不支持资料库浏览。"
        }
    }
}

/// 上下文建立与启动失败只携带固定阶段和数字错误码，不包含资料库内容或脚本。
public struct MusicPlaybackContextError: Error, Equatable, Sendable, LocalizedError {
    public enum Stage: String, Sendable {
        case create, select, append, readback, start, currentPlaylist, shuffle, cleanup
    }

    public let stage: Stage
    public let appleEventCode: Int?

    public init(stage: Stage, appleEventCode: Int? = nil) {
        self.stage = stage
        self.appleEventCode = appleEventCode
    }

    public var errorDescription: String? {
        // Apple Events 固定错误码；只给出恢复说明，不显示系统原始错误文本。
        switch appleEventCode {
        case -1743:
            return "需要允许 ShinApple 控制「音乐」App。请在系统设置的自动化权限中允许后重试。"
        case -600:
            return "「音乐」App 未运行，请打开后再播放当前列表。"
        case -1712:
            return "「音乐」App 响应超时，暂时未能确认本次列表的播放状态。请稍后重试。"
        default:
            break
        }
        switch stage {
        case .create, .append, .readback:
            return "未能在「音乐」App 中建立本次播放列表。请检查「音乐」App 后重试。"
        case .select:
            return "未能定位本次列表中的歌曲。请检查「音乐」App 后重试。"
        case .start, .currentPlaylist:
            return "未能确认本次播放列表已开始播放。请检查「音乐」App 后重试。"
        case .shuffle:
            return MusicLibraryError.playbackModeUnconfirmed.errorDescription
        case .cleanup:
            return "旧的应用播放列表暂未清理，可在「音乐」App 中检查。"
        }
    }
}
