import Foundation
import ShinAppleKit

// 在线歌词获取的来源注记。铁律机制化：
// - 任何在线获取的歌词落库时必须带 provenance（来源/外部引用/匹配方式/查询词），
//   UI 可据此展示「网易云 · 自动获取，未核对」徽标；
// - 「手动优先」判定完全依赖这些注记：无注记 = 手动导入/人工编辑成果，
//   永不被自动获取覆盖、永不被自动删除管线清理；
// - 歌单自动落位（auto-high）的文档在获取后一旦被人工编辑（revision 递增）
//   或绑定过人工翻译，即退出自动删除范围。

/// 一次在线获取的来源注记。随确认导入写入文档 metadata。
public struct FetchProvenance: Equatable, Sendable {
    /// 匹配产生方式：用户在候选列表中确认 / 歌单自动高置信落位。
    public enum MatchKind: String, Equatable, Sendable {
        case userConfirmed = "user-confirmed"
        case autoHigh = "auto-high"
    }

    /// 来源服务标识（如 "netease"）。
    public let provider: String
    /// 带命名空间的外部引用（如 "netease:song:1001"）。
    public let externalRef: String
    public let matchKind: MatchKind
    /// 当时使用的搜索词（追溯错配用）。
    public let queryTitle: String
    public let queryArtist: String?

    public init(
        provider: String,
        externalRef: String,
        matchKind: MatchKind,
        queryTitle: String,
        queryArtist: String? = nil
    ) {
        self.provider = provider
        self.externalRef = externalRef
        self.matchKind = matchKind
        self.queryTitle = queryTitle
        self.queryArtist = queryArtist
    }
}

/// 来源注记在文档 metadata 中的固定键（小写连字符，值恒为单元素数组）。
public enum FetchedLyricsMetadataKeys {
    public static let source = "shin-fetch-source"
    public static let externalRef = "shin-fetch-ref"
    public static let matchKind = "shin-fetch-match"
    public static let fetchedAt = "shin-fetch-time"
    public static let revisionAtFetch = "shin-fetch-revision"
    public static let queryTitle = "shin-fetch-query-title"
    public static let queryArtist = "shin-fetch-query-artist"
}

extension FetchProvenance {
    /// 生成写入 metadata 的键值（时间与 revision 快照由确认时补充）。
    public func metadataFields(fetchedAt: String, revisionAtFetch: Int) -> [String: [String]] {
        var fields: [String: [String]] = [
            FetchedLyricsMetadataKeys.source: [provider],
            FetchedLyricsMetadataKeys.externalRef: [externalRef],
            FetchedLyricsMetadataKeys.matchKind: [matchKind.rawValue],
            FetchedLyricsMetadataKeys.fetchedAt: [fetchedAt],
            FetchedLyricsMetadataKeys.revisionAtFetch: [String(revisionAtFetch)],
            FetchedLyricsMetadataKeys.queryTitle: [queryTitle]
        ]
        if let queryArtist {
            fields[FetchedLyricsMetadataKeys.queryArtist] = [queryArtist]
        }
        return fields
    }
}

extension LyricDocument {

    /// 来源服务标识；nil = 无在线获取注记（手动导入或人工编辑成果）。
    public var fetchProvider: String? {
        metadata[FetchedLyricsMetadataKeys.source]?.first
    }

    /// 匹配产生方式；无注记为 nil。
    public var fetchMatchKind: FetchProvenance.MatchKind? {
        metadata[FetchedLyricsMetadataKeys.matchKind]?.first
            .flatMap(FetchProvenance.MatchKind.init(rawValue:))
    }

    /// 是否为歌单自动落位的在线歌词（自动删除管线的唯一候选类型；
    /// 用户确认导入的在线歌词不参与自动删除）。
    public var isAutoFetched: Bool {
        fetchProvider != nil && fetchMatchKind == .autoHigh
    }

    /// 是否带任何在线获取注记（UI 来源徽标判定）。
    public var hasFetchProvenance: Bool { fetchProvider != nil }

    /// 落位以来是否未经人工编辑：当前 revision 仍等于获取时记录的 revision。
    /// 任何经保存路径的人工编辑都会递增 revision，从而使本判定为 false。
    public var isUneditedSinceFetch: Bool {
        guard let recorded = metadata[FetchedLyricsMetadataKeys.revisionAtFetch]?.first,
              let recordedRevision = Int(recorded)
        else { return false }
        return recordedRevision == revision
    }

    /// 是否存在人工录入的翻译（自动删除保护的另一信号）。
    public var hasManualTranslation: Bool {
        lines.contains { line in
            line.translations.values.contains { $0.source == .manual }
        }
    }
}
