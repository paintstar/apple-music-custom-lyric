import Foundation

// 网易云歌词获取层的公开数据模型。
// 全部为纯值类型：不含播放状态、不含项目文档模型，只携带
// 「搜索候选」与「取回的歌词文本」两类信息。时间统一整数毫秒。

/// 网易云搜索候选曲目。
public struct NeteaseSongCandidate: Identifiable, Equatable, Sendable {
    /// 网易云曲目 ID（作为外部引用保存时带 `netease:song:` 命名空间前缀）。
    public let songId: Int64
    public let title: String
    /// 按网易云返回顺序的歌手名列表。
    public let artists: [String]
    public let album: String?
    /// 整数毫秒；网易云未知时为 nil。
    public let durationMs: Int64?

    public var id: Int64 { songId }

    /// UI 展示用歌手行（空列表返回空串，不冒充「未知」）。
    public var artistLine: String { artists.joined(separator: " / ") }

    /// 带命名空间的外部引用（与 Music persistent ID 同一存放惯例）。
    public var externalRef: String { "netease:song:\(songId)" }

    public init(
        songId: Int64,
        title: String,
        artists: [String],
        album: String? = nil,
        durationMs: Int64? = nil
    ) {
        self.songId = songId
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
    }
}

/// 取回的歌词（纯文本，未解析成项目文档——那一步走既有导入管线）。
public struct NeteaseLyrics: Equatable, Sendable {
    public let songId: Int64
    /// 原文 LRC 文本（网易云 `lrc.lyric`）。
    public let originalLRC: String
    /// 翻译 LRC 文本（网易云 `tlyric.lyric`）；无翻译为 nil。
    public let translatedLRC: String?

    public init(songId: Int64, originalLRC: String, translatedLRC: String?) {
        self.songId = songId
        self.originalLRC = originalLRC
        self.translatedLRC = translatedLRC
    }
}

/// 获取失败的类型化原因。UI 按类呈现，不把失败伪装成「无歌词」。
public enum NeteaseLyricsError: Error, Equatable, Sendable {
    /// 网络层失败（离线 / 超时 / DNS / 连接重置）。
    case network(String)
    /// HTTP 状态非 200（含风控页）。
    case httpStatus(Int)
    /// 响应结构不符合预期——私有接口可能已变更，隔离在本层呈现。
    case apiChanged(String)
    /// 服务端明确返回「无歌词 / 纯音乐」。
    case noLyrics
    /// 搜索关键词为空（或仅空白）。
    case emptyQuery
    /// 搜索成功但零结果。
    case noResults
    /// 触发限流 / 需要登录（VIP 歌曲等）。匿名模式下可能出现在歌词接口。
    case restricted

    /// 面向用户的中文说明。
    public var userMessage: String {
        switch self {
        case .network:
            return "网络不可用或连接超时，请检查网络后重试（手动导入不受影响）。"
        case .httpStatus(let code):
            return "网易云返回异常状态（HTTP \(code)），请稍后重试。"
        case .apiChanged(let detail):
            return "网易云接口响应异常（可能已变更），在线获取暂不可用：\(detail)"
        case .noLyrics:
            return "网易云没有这首歌的歌词（可能是纯音乐或未收录）。手动导入仍然可用。"
        case .emptyQuery:
            return "请输入歌名（可加歌手）后再搜索。"
        case .noResults:
            return "没有搜到匹配的歌曲，可调整关键词后重试。"
        case .restricted:
            return "该歌词需要登录或受限（如 VIP 歌曲），暂不自动获取；手动导入仍然可用。"
        }
    }
}
