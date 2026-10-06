import Foundation
import ShinAppServices
import ShinLyricsProvider

// 在线歌词获取状态机，负责手动获取流程。
// - 只负责「搜索 → 候选展示 → 取词 → 合成双语 LRC」；解析/校验/确认
//   一律交回既有导入流程（用户看到熟悉的预览再决定是否写库）；
// - 世代号（generation）丢弃被取消/被取代的旧结果（切歌、关窗、重搜）；
// - 真实模式走 NeteaseLyricsClient；Mock 模式走虚构候选（--mock 演示用，
//   不打网络，内容为原创虚构，与 MockCatalogSearchService 同一模式）。

/// 获取服务的最小面（真实/Mock 共用；App 层不直接触碰 URLSession）。
protocol LyricsFetchServicing: Sendable {
    func searchSongs(query: String) async throws -> [NeteaseSongCandidate]
    func fetchLyrics(songId: Int64) async throws -> NeteaseLyrics
}

/// 真实服务：包一层 provider 客户端（默认限速在客户端内）。
struct LiveLyricsFetchService: LyricsFetchServicing {
    private let client = NeteaseLyricsClient()

    func searchSongs(query: String) async throws -> [NeteaseSongCandidate] {
        try await client.searchSongs(query: query)
    }

    func fetchLyrics(songId: Int64) async throws -> NeteaseLyrics {
        try await client.fetchLyrics(songId: songId)
    }
}

/// Mock 服务：--mock 模式演示用，虚构曲目与歌词，延迟模拟网络节奏。
struct MockLyricsFetchService: LyricsFetchServicing {
    func searchSongs(query: String) async throws -> [NeteaseSongCandidate] {
        try await Task.sleep(for: .milliseconds(250))
        return [
            NeteaseSongCandidate(
                songId: 9_100_101, title: "模拟歌\(query.isEmpty ? "曲" : "曲")",
                artists: ["演示歌手一"], album: "虚构演示专辑", durationMs: 201_000
            ),
            NeteaseSongCandidate(
                songId: 9_100_102, title: "模拟歌曲 (Live版)",
                artists: ["演示歌手一", "客串歌手二"], durationMs: 233_000
            )
        ]
    }

    func fetchLyrics(songId: Int64) async throws -> NeteaseLyrics {
        try await Task.sleep(for: .milliseconds(250))
        return NeteaseLyrics(
            songId: songId,
            originalLRC: """
            [ti:模拟歌曲]
            [ar:演示歌手一]
            [00:01.000]模拟歌词第一行
            [00:04.500]模拟歌词第二行
            [00:09.000]模拟歌词第三行
            """,
            translatedLRC: """
            [00:01.000]模拟译文第一行
            [00:04.500]模拟译文第二行
            [00:09.000]模拟译文第三行
            """
        )
    }
}

@MainActor
final class NeteaseLyricsFetchModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case searching
        case candidates([RankedCandidate])
        case fetching(NeteaseSongCandidate)
        /// 取词完成（已交回导入流程），本 sheet 应关闭。
        case delivered
    }

    @Published private(set) var phase: Phase = .idle
    /// 搜索词（预填当前曲目标题，可改）。
    @Published var queryTitle = ""
    @Published var queryArtist = ""
    /// 可恢复错误说明（中文）；nil = 无错误。
    @Published var alertMessage: String?
    /// 目标歌曲的本地信息（打分基准；打开时固定，不随播放变化）。
    let matchQuery: LyricsMatchQuery
    /// 导入目标（固定；取词完成后交给 ImportFlowModel 开会话）。
    let target: ImportSessionTarget
    /// 取词完成回调：合并文本 + 来源注记 → 宿主转入导入预览。
    var onDelivered: ((NeteaseLyrics, FetchProvenance) -> Void)?

    private let service: any LyricsFetchServicing
    private var generation = 0

    init(
        service: any LyricsFetchServicing,
        matchQuery: LyricsMatchQuery,
        target: ImportSessionTarget
    ) {
        self.service = service
        self.matchQuery = matchQuery
        self.target = target
        queryTitle = matchQuery.title
        queryArtist = matchQuery.artist ?? ""
    }

    // MARK: - 搜索

    func search() async {
        let title = queryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = queryArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            alertMessage = NeteaseLyricsError.emptyQuery.userMessage
            return
        }
        generation += 1
        let currentGeneration = generation
        phase = .searching
        alertMessage = nil
        do {
            let keyword = artist.isEmpty ? title : "\(title) \(artist)"
            let candidates = try await service.searchSongs(query: keyword)
            guard currentGeneration == generation else { return }
            // 用本地信息重打分排序（本地信息含时长；搜索词只是查询用）。
            let query = LyricsMatchQuery(title: title, artist: artist.isEmpty ? nil : artist,
                                         durationMs: matchQuery.durationMs)
            let ranked = LyricsMatchRanker.rank(candidates: candidates, query: query)
            phase = .candidates(ranked)
            if ranked.isEmpty {
                alertMessage = NeteaseLyricsError.noResults.userMessage
            }
        } catch {
            guard currentGeneration == generation else { return }
            phase = .idle
            alertMessage = (error as? NeteaseLyricsError)?.userMessage
                ?? "搜索失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 取词

    /// 用户选定候选：取词 → 合成双语 LRC → 交回导入流程。
    func deliver(_ ranked: RankedCandidate) async {
        guard case let .candidates(candidates) = phase else { return }
        generation += 1
        let currentGeneration = generation
        phase = .fetching(ranked.candidate)
        alertMessage = nil
        do {
            let lyrics = try await service.fetchLyrics(songId: ranked.candidate.songId)
            guard currentGeneration == generation else { return }
            let provenance = FetchProvenance(
                provider: "netease",
                externalRef: ranked.candidate.externalRef,
                matchKind: .userConfirmed,
                queryTitle: queryTitle,
                queryArtist: queryArtist.isEmpty ? nil : queryArtist
            )
            phase = .delivered
            onDelivered?(lyrics, provenance)
        } catch {
            guard currentGeneration == generation else { return }
            // 失败回到候选列表（会话内容还在，可直接换候选重试）。
            phase = .candidates(candidates)
            alertMessage = (error as? NeteaseLyricsError)?.userMessage
                ?? "获取歌词失败：\(error.localizedDescription)"
        }
    }

    /// 关闭/取消：丢弃一切进行中的结果。
    func cancel() {
        generation += 1
        phase = .idle
        alertMessage = nil
    }
}
