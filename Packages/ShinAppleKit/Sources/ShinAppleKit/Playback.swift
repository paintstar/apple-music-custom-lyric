// domain/music：播放契约的数据类型。
// 本文件是项目自定义契约，不是 Apple SDK 方法清单；ShinMusicScript
// 将 Music.app 的公开脚本能力映射到这里，Mock 用于离线演示与验证。

/// 播放器状态机。loading/buffering/seeking 等中间态必须显式建模，
/// 不允许用“时间在走”冒充任何状态。
public enum PlayerStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case seeking
    case ended
    case error
    // 脚本采样状态：读取失败不显示为 playing，
    // 环境状态显式建模而非折叠进 idle/error。
    /// 播放器宿主（Music.app）未运行：读不到任何播放状态。
    case notRunning
    /// 宿主运行但无当前曲目（未选歌/队列为空）。
    case noTrack
}

/// 目录歌曲身份，保留用于 Mock 和已有资料的持久绑定兼容。
/// 不使用无类型的 songId；library ID 与目录 ID 是不同资源。
public struct CatalogIdentity: Equatable, Sendable {
    /// 恒为 "apple-music"。
    public static let provider = "apple-music"

    /// Apple Music storefront 代码（如 "us"、"cn"）。
    public var storefront: String
    /// 目录歌曲 ID（catalog song，非 library song）。
    public var catalogSongId: String

    public init(storefront: String, catalogSongId: String) {
        self.storefront = storefront
        self.catalogSongId = catalogSongId
    }
}

/// 播放能力集，按适配器已实现的能力填充，
/// 适配器未提供时整体为 nil；调用方不能将未知值视为支持。
public struct PlaybackCapabilities: Equatable, Sendable {
    public var playPause: Bool
    public var next: Bool
    public var previous: Bool
    public var seek: Bool

    public init(playPause: Bool, next: Bool, previous: Bool, seek: Bool) {
        self.playPause = playPause
        self.next = next
        self.previous = previous
        self.seek = seek
    }
}

/// 播放快照。
/// SDK 报告的播放位置是唯一权威时钟；未知时间必须为 nil，绝不冒充 0。
public struct PlaybackSnapshot: Equatable, Sendable {
    /// 当前播放项目的生命周期编号：每次切歌/重新装载队列递增。
    /// 用于丢弃过期异步结果（trackEpoch + requestSeq 规则）。
    public var trackEpoch: Int
    /// 无目录映射时允许为 nil。
    public var track: CatalogIdentity?
    public var title: String?
    /// 曲目歌手（展示用）。未知为 nil（不冒充空串）。
    /// SB/AppleScript 执行器与 Mock 均可提供；默认 nil
    /// 不破坏既有构造调用点。
    public var artist: String?
    /// 整数毫秒；未获得有效时间时为 nil。
    public var positionMs: Int64?
    /// 整数毫秒；未知时长为 nil。
    public var durationMs: Int64?
    public var status: PlayerStatus
    /// 出错时的稳定错误代码（可展示、可判别），无错误为 nil。
    public var errorCode: String?

    // 脚本采样字段。适配器与 Mock
    // 使用默认值，不破坏既有构造与相等语义。

    /// 已发布快照的会话内单调序号（仅内容变化并发布时递增；未实现为 0）。
    public var seq: Int
    /// 适配器会话编号（每次构造新控制器递增），区分适配器重启前后的快照流。
    public var sessionEpoch: Int
    /// 曲目的项目内引用（带来源命名空间，如 `music-script:persistent:<persistentID>`）；
    /// 未知为 nil。这不是官方目录 ID。
    public var trackRef: String?
    /// 采样时刻的单调时钟毫秒（宿主进程时钟域；跨时钟域不可直接比较；未提供为 0）。
    public var sampledAtMonotonicMs: Int64
    /// 本次采样往返耗时毫秒（用于采样策略；未提供为 0）。
    public var requestDurationMs: Int64
    /// 能力集；适配器未提供为 nil（未知，不假设支持）。
    public var capabilities: PlaybackCapabilities?

    public init(
        trackEpoch: Int = 0,
        track: CatalogIdentity? = nil,
        title: String? = nil,
        artist: String? = nil,
        positionMs: Int64? = nil,
        durationMs: Int64? = nil,
        status: PlayerStatus = .idle,
        errorCode: String? = nil,
        seq: Int = 0,
        sessionEpoch: Int = 0,
        trackRef: String? = nil,
        sampledAtMonotonicMs: Int64 = 0,
        requestDurationMs: Int64 = 0,
        capabilities: PlaybackCapabilities? = nil
    ) {
        self.trackEpoch = trackEpoch
        self.track = track
        self.title = title
        self.artist = artist
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.status = status
        self.errorCode = errorCode
        self.seq = seq
        self.sessionEpoch = sessionEpoch
        self.trackRef = trackRef
        self.sampledAtMonotonicMs = sampledAtMonotonicMs
        self.requestDurationMs = requestDurationMs
        self.capabilities = capabilities
    }

    /// 快照的「播放内容」可比部分：采样时间戳/序号等每次采样必然变化的
    /// 字段不参与，供“内容未变化则不发布”的去抖判断使用。
    public var contentValue: PlaybackSnapshotContent {
        PlaybackSnapshotContent(
            trackEpoch: trackEpoch,
            track: track,
            title: title,
            artist: artist,
            positionMs: positionMs,
            durationMs: durationMs,
            status: status,
            errorCode: errorCode,
            trackRef: trackRef
        )
    }
}

/// 快照内容的可比值（不含 seq/采样时间戳等流水字段）。
public struct PlaybackSnapshotContent: Equatable, Sendable {
    var trackEpoch: Int
    var track: CatalogIdentity?
    var title: String?
    var artist: String?
    var positionMs: Int64?
    var durationMs: Int64?
    var status: PlayerStatus
    var errorCode: String?
    var trackRef: String?
}

public extension PlaybackSnapshot {
    /// v2 曲目键（命名空间化）：trackRef（脚本身份）优先；
    /// 否则按 v1 目录身份推导 `apple-music:catalog:<storefront>:<id>`；
    /// 两者皆无（不可定位）为 nil。
    var trackKey: String? {
        if let trackRef { return trackRef }
        guard let track else { return nil }
        return SongBinding.trackKey(for: track)
    }
}

/// 播放域错误（判别枚举）。
/// 适配器必须把底层 SDK 错误映射到这里，不允许全部折叠成一种“失败”。
public enum PlaybackError: Error, Equatable, Sendable {
    /// 应用配置不可用。
    case configurationMissing
    /// 用户尚未授予「音乐」App 自动化访问权限。
    case unauthorized
    /// 用户取消了授权或操作。
    case userCancelled
    /// 网络失败。
    case network
    /// 曲目不可播放（下架、地区不可用、无订阅资格等）。
    case trackUnavailable
    /// 播放器初始化失败，附带原因。
    case initializationFailed(String)
    /// v2：播放器宿主（Music.app）未运行，命令无处投递。
    case musicNotRunning
    /// 未能归类的底层错误，附带可展示代码。
    case unknown(String)

    /// 稳定的字符串代码，用于 PlaybackSnapshot.errorCode 与日志。
    public var code: String {
        switch self {
        case .configurationMissing: return "configurationMissing"
        case .unauthorized: return "unauthorized"
        case .userCancelled: return "userCancelled"
        case .network: return "network"
        case .trackUnavailable: return "trackUnavailable"
        case .initializationFailed(let reason): return "initializationFailed:\(reason)"
        case .musicNotRunning: return "musicNotRunning"
        case .unknown(let raw): return "unknown:\(raw)"
        }
    }
}
