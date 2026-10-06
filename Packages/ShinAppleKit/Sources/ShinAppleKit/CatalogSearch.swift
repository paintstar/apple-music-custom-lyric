import Foundation

// domain/music：目录搜索契约。
// 项目契约，当前仅供 Mock 目录使用；真实模式使用 Music.app 资料库。

/// 搜索结果中的歌曲摘要（domain 层，不携带 SDK 类型）。
public struct SongSummary: Equatable, Sendable {
    public var identity: CatalogIdentity
    public var title: String
    public var artistName: String
    /// 未知时长保持 nil（整数毫秒）。
    public var durationMs: Int64?

    public init(
        identity: CatalogIdentity,
        title: String,
        artistName: String,
        durationMs: Int64?
    ) {
        self.identity = identity
        self.title = title
        self.artistName = artistName
        self.durationMs = durationMs
    }
}

/// Mock 目录搜索契约。真实模式不提供官方目录搜索。
/// 请求序号/防抖由界面层维护：旧响应不得覆盖新结果。
public protocol CatalogSearchService: Sendable {
    /// 按关键词搜索目录歌曲。term 去除首尾空白后为空时抛 `.emptyTerm`。
    func searchSongs(term: String, limit: Int) async throws -> [SongSummary]
}

/// 目录搜索错误（判别枚举）。
public enum CatalogSearchError: Error, Equatable, Sendable {
    case emptyTerm
    case unauthorized
    case network(String)
    case rateLimited
    case trackUnavailable
    case unknown(String)
}
