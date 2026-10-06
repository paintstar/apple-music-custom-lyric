import Foundation
import ShinAppleKit

/// Mock 模式的搜索服务：从内置演示曲目中过滤。
/// 全部为原创虚构内容，不访问任何网络。
public struct MockCatalogSearchService: CatalogSearchService {
    public static let demoTracks: [SongSummary] = [
        SongSummary(
            identity: CatalogIdentity(storefront: "mock", catalogSongId: "demo-001"),
            title: "测试曲目一",
            artistName: "演示歌手甲",
            durationMs: 180_000
        ),
        SongSummary(
            identity: CatalogIdentity(storefront: "mock", catalogSongId: "demo-002"),
            title: "测试曲目二",
            artistName: "演示歌手乙",
            durationMs: 210_000
        ),
        SongSummary(
            identity: CatalogIdentity(storefront: "mock", catalogSongId: "demo-003"),
            title: "示例歌曲三",
            artistName: "演示歌手甲",
            durationMs: 195_000
        )
    ]

    public init() {}

    public func searchSongs(term: String, limit: Int) async throws -> [SongSummary] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatalogSearchError.emptyTerm }
        // 模拟真实目录行为：标题或歌手包含关键词即命中。
        let matched = Self.demoTracks.filter { summary in
            summary.title.localizedCaseInsensitiveContains(trimmed)
                || summary.artistName.localizedCaseInsensitiveContains(trimmed)
        }
        return Array(matched.prefix(max(1, limit)))
    }
}
