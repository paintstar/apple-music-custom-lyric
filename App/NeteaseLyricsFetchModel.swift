import Foundation
import ShinAIProvider
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
    /// 搜索词（预填去除末尾括号附注的当前曲目标题，可改）。
    @Published var queryTitle = ""
    @Published var queryArtist = ""
    /// 可恢复错误说明（中文）；nil = 无错误。
    @Published var alertMessage: String?
    /// 自动回退补搜说明（如补搜假名或仅搜歌名）；nil = 未触发回退。
    @Published private(set) var searchFallbackNote: String?
    /// AI 推测的原曲搜索建议列表（仅用户主动点击触发）。
    @Published private(set) var aiSuggestions: [AISearchQuerySuggestion] = []
    @Published private(set) var isSuggestingWithAI = false
    @Published private(set) var aiSuggestionError: String?
    @Published private(set) var aiSuggestionNeedsSettings = false
    /// 目标歌曲的本地信息（打分基准；打开时固定，不随播放变化）。
    let matchQuery: LyricsMatchQuery
    /// 导入目标（固定；取词完成后交给 ImportFlowModel 开会话）。
    let target: ImportSessionTarget
    let isMock: Bool
    /// 取词完成回调：合并文本 + 来源注记 → 宿主转入导入预览。
    var onDelivered: ((NeteaseLyrics, FetchProvenance) -> Void)?

    /// 离线日语罗马音转假名搜索建议（纯本地计算，零网络）。
    var offlineKanaSuggestions: [String] {
        JapaneseRomajiTransliterator.suggestedKanaQueries(for: queryTitle)
    }

    private let service: any LyricsFetchServicing
    private let aiClient: (any AIStudyProviding)?
    private let settingsStore: AIServiceSettingsStore
    private let credentialStore: any AICredentialStoring
    private var generation = 0
    private var aiSuggestionGeneration = 0
    private var aiSuggestionTask: Task<Void, Never>?

    init(
        service: any LyricsFetchServicing,
        matchQuery: LyricsMatchQuery,
        target: ImportSessionTarget,
        isMock: Bool = false,
        aiClient: (any AIStudyProviding)? = nil,
        settingsStore: AIServiceSettingsStore = AIServiceSettingsStore(),
        credentialStore: (any AICredentialStoring)? = nil
    ) {
        self.service = service
        self.matchQuery = matchQuery
        self.target = target
        self.isMock = isMock
        self.aiClient = aiClient
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
            ?? (isMock ? InMemoryAICredentialStore() : SystemKeychainCredentialStore())
        queryTitle = Self.prefilledTitle(matchQuery.title)
        queryArtist = matchQuery.artist ?? ""
    }

    /// 仅在打开弹窗时清理附注；原始目标及用户后续输入保持原样。
    private static func prefilledTitle(_ title: String) -> String {
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = original
        while let annotationStart = trailingAnnotationStart(in: result) {
            result = String(result[..<annotationStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 只有括号的标题仍可由用户直接搜索，不能回填成空白。
            if result.isEmpty { return original }
        }
        return result
    }

    // 标题附注的标点配对规则，不依赖歌名或版本关键词。
    private static let annotationBrackets: [Character: Character] = [")": "(", "]": "[", "）": "（", "］": "［"]

    private static func trailingAnnotationStart(in title: String) -> String.Index? {
        guard let last = title.last, annotationBrackets[last] != nil else { return nil }
        var expectedOpenings: [Character] = []
        for index in title.indices.reversed() {
            let character = title[index]
            if let opening = annotationBrackets[character] {
                expectedOpenings.append(opening)
            } else if annotationBrackets.values.contains(character) {
                guard expectedOpenings.popLast() == character else { return nil }
                if expectedOpenings.isEmpty { return index }
            }
        }
        return nil
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
        searchFallbackNote = nil
        do {
            let query = LyricsMatchQuery(
                title: title,
                artist: artist.isEmpty ? nil : artist,
                durationMs: matchQuery.durationMs
            )
            let outcome = try await searchWithFallback(
                title: title,
                artist: artist,
                query: query,
                generation: currentGeneration
            )
            guard currentGeneration == generation else { return }
            searchFallbackNote = outcome.fallbackNote
            if outcome.mergedEmpty && outcome.primaryReturnedNoResults {
                phase = .idle
                alertMessage = NeteaseLyricsError.noResults.userMessage
            } else {
                phase = .candidates(outcome.ranked)
                if outcome.ranked.isEmpty {
                    alertMessage = NeteaseLyricsError.noResults.userMessage
                }
            }
        } catch {
            guard currentGeneration == generation else { return }
            phase = .idle
            alertMessage = (error as? NeteaseLyricsError)?.userMessage
                ?? "搜索失败：\(error.localizedDescription)"
        }
    }

    /// 填入建议关键词并立刻搜索。
    func applySuggestionAndSearch(
        title: String,
        artist: String? = nil,
        replaceArtist: Bool = false
    ) async {
        queryTitle = title
        if let artist {
            let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || replaceArtist {
                queryArtist = trimmed
            }
        } else if replaceArtist {
            queryArtist = ""
        }
        await search()
    }

    /// 清空歌手字段，仅按当前歌名重新搜索。
    func searchTitleOnly() async {
        queryArtist = ""
        await search()
    }

    /// 用户主动触发：调用 AI 推测可能对应的原曲名/歌手搜索词。
    func requestAISearchSuggestions() {
        let title = queryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = queryArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            aiSuggestionError = NeteaseLyricsError.emptyQuery.userMessage
            aiSuggestionNeedsSettings = false
            return
        }
        aiSuggestionTask?.cancel()
        aiSuggestionGeneration += 1
        let currentGeneration = aiSuggestionGeneration
        isSuggestingWithAI = true
        aiSuggestionError = nil
        aiSuggestionNeedsSettings = false

        aiSuggestionTask = Task { [weak self] in
            guard let self else { return }
            await self.runAISearchSuggestions(
                title: title,
                artist: artist.isEmpty ? nil : artist,
                generation: currentGeneration
            )
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
        aiSuggestionGeneration += 1
        aiSuggestionTask?.cancel()
        aiSuggestionTask = nil
        isSuggestingWithAI = false
        aiSuggestionError = nil
        aiSuggestionNeedsSettings = false
        phase = .idle
        alertMessage = nil
        searchFallbackNote = nil
    }
}

private extension NeteaseLyricsFetchModel {
    struct SearchOutcome {
        let ranked: [RankedCandidate]
        let mergedEmpty: Bool
        let primaryReturnedNoResults: Bool
        let fallbackNote: String?
    }

    func searchWithFallback(
        title: String,
        artist: String,
        query: LyricsMatchQuery,
        generation currentGeneration: Int
    ) async throws -> SearchOutcome {
        let keyword = artist.isEmpty ? title : "\(title) \(artist)"
        var primaryReturnedNoResults = false
        let primaryCandidates: [NeteaseSongCandidate]
        do {
            primaryCandidates = try await service.searchSongs(query: keyword)
        } catch NeteaseLyricsError.noResults {
            primaryCandidates = []
            primaryReturnedNoResults = true
        }
        guard currentGeneration == generation else { return Self.cancelledOutcome }

        var merged = primaryCandidates
        var seenIds = Set(merged.map(\.songId))
        var ranked = LyricsMatchRanker.rank(candidates: merged, query: query)
        var fallbackNote: String?

        if !ranked.contains(where: { $0.score.isAutoHighEligible }),
           let kana = JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji(title) {
            let kanaQueries = Self.kanaFallbackQueries(kana: kana, artist: artist, primaryKeyword: keyword)
            for fallbackQuery in kanaQueries {
                guard !ranked.contains(where: { $0.score.isAutoHighEligible }) else { break }
                guard let added = try await appendFallbackSearch(
                    queryText: fallbackQuery,
                    generation: currentGeneration,
                    merged: &merged,
                    seenIds: &seenIds
                ) else { return Self.cancelledOutcome }
                if added {
                    fallbackNote = "已自动补充搜索假名「\(fallbackQuery)」的候选"
                }
                ranked = LyricsMatchRanker.rank(candidates: merged, query: query)
            }
        }

        if !Self.hasTitleHit(ranked),
           !artist.isEmpty,
           !ranked.contains(where: { $0.score.artistExact || $0.score.artistTransliterationMatch }) {
            guard let added = try await appendFallbackSearch(
                queryText: title,
                generation: currentGeneration,
                merged: &merged,
                seenIds: &seenIds
            ) else { return Self.cancelledOutcome }
            if added, fallbackNote == nil {
                fallbackNote = "已自动补充仅按歌名搜索的候选"
            }
            ranked = LyricsMatchRanker.rank(candidates: merged, query: query)
        }

        return SearchOutcome(
            ranked: ranked,
            mergedEmpty: merged.isEmpty,
            primaryReturnedNoResults: primaryReturnedNoResults,
            fallbackNote: fallbackNote
        )
    }

    static let cancelledOutcome = SearchOutcome(
        ranked: [], mergedEmpty: true, primaryReturnedNoResults: false, fallbackNote: nil
    )

    static func kanaFallbackQueries(kana: String, artist: String, primaryKeyword: String) -> [String] {
        var queries: [String] = []
        if !artist.isEmpty {
            let kanaWithArtist = "\(kana) \(artist)"
            if kanaWithArtist != primaryKeyword { queries.append(kanaWithArtist) }
        }
        if kana != primaryKeyword { queries.append(kana) }
        return queries
    }

    func appendFallbackSearch(
        queryText: String,
        generation currentGeneration: Int,
        merged: inout [NeteaseSongCandidate],
        seenIds: inout Set<Int64>
    ) async throws -> Bool? {
        let candidates = try await searchAllowingNoResults(query: queryText)
        guard currentGeneration == generation else { return nil }
        return Self.appendUnique(candidates, to: &merged, seenIds: &seenIds)
    }

    func searchAllowingNoResults(query: String) async throws -> [NeteaseSongCandidate] {
        do {
            return try await service.searchSongs(query: query)
        } catch NeteaseLyricsError.noResults {
            return []
        }
    }

    func runAISearchSuggestions(title: String, artist: String?, generation currentGeneration: Int) async {
        if isMock && aiClient == nil {
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard currentGeneration == aiSuggestionGeneration, !Task.isCancelled else { return }
            aiSuggestions = Self.mockAISuggestions(for: title, artist: artist)
            isSuggestingWithAI = false
            return
        }

        let client = aiClient ?? OpenAICompatibleClient(credentialStore: credentialStore)
        let configuration = settingsStore.load()
        do {
            let suggestions = try await client.suggestLyricsSearchQueries(
                title: title,
                artist: artist,
                configuration: configuration,
                apiKey: nil
            )
            guard currentGeneration == aiSuggestionGeneration, !Task.isCancelled else { return }
            aiSuggestions = suggestions
            isSuggestingWithAI = false
        } catch is CancellationError {
            return
        } catch let error as AIProviderError {
            guard currentGeneration == aiSuggestionGeneration, !Task.isCancelled else { return }
            isSuggestingWithAI = false
            if case .missingAPIKey = error {
                aiSuggestionNeedsSettings = true
            }
            aiSuggestionError = error.userMessage
        } catch {
            guard currentGeneration == aiSuggestionGeneration, !Task.isCancelled else { return }
            isSuggestingWithAI = false
            aiSuggestionError = "AI 推测失败：\(error.localizedDescription)"
        }
    }

    static func hasTitleHit(_ ranked: [RankedCandidate]) -> Bool {
        ranked.contains { item in
            item.score.titleExact
                || item.score.titleContains
                || item.score.titleTransliterationMatch
                || item.score.titleAliasMatch
        }
    }

    @discardableResult
    static func appendUnique(
        _ incoming: [NeteaseSongCandidate],
        to target: inout [NeteaseSongCandidate],
        seenIds: inout Set<Int64>
    ) -> Bool {
        var added = false
        for candidate in incoming where seenIds.insert(candidate.songId).inserted {
            target.append(candidate)
            added = true
        }
        return added
    }

    static func mockAISuggestions(for title: String, artist: String?) -> [AISearchQuerySuggestion] {
        let mockArtist = artist?.isEmpty == false ? artist : "演示歌手一"
        let kanaList = JapaneseRomajiTransliterator.suggestedKanaQueries(for: title)
        if kanaList.count >= 2 {
            return [
                AISearchQuerySuggestion(title: kanaList[1], artist: mockArtist, reason: "片假名模拟示例"),
                AISearchQuerySuggestion(title: kanaList[0], artist: mockArtist, reason: "平假名模拟示例")
            ]
        }
        return [
            AISearchQuerySuggestion(title: "模拟原曲名", artist: mockArtist, reason: "原曲名模拟示例"),
            AISearchQuerySuggestion(title: "模拟别名曲", artist: "演示歌手一", reason: "别名模拟示例")
        ]
    }
}
