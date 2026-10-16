import Foundation
import Testing
@testable import ShinLyricsProvider

// 匹配打分单测（纯函数，虚构曲目）。
// 重点覆盖：同名不同歌手、
// 版本区分、全半角/大小写、feat 艺人、时长冲突降级与稳定排序。

@Suite("LyricsMatchRanker")
struct LyricsMatchRankerTests {

    private func candidate(
        id: Int64,
        title: String,
        artists: [String],
        durationMs: Int64? = nil
    ) -> NeteaseSongCandidate {
        NeteaseSongCandidate(songId: id, title: title, artists: artists, durationMs: durationMs)
    }

    @Test("歌名+歌手+时长全对 → high 且可自动落位")
    func exactMatchIsAutoEligible() {
        let query = LyricsMatchQuery(title: "测试歌A", artist: "虚拟歌手X", durationMs: 234_000)
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "测试歌A", artists: ["虚拟歌手X"], durationMs: 234_567),
            query: query
        )
        #expect(score.titleExact)
        #expect(score.artistExact)
        #expect(score.durationDeltaMs == 567)
        #expect(score.confidence == .high)
        #expect(score.isAutoHighEligible)
    }

    @Test("同名但歌手完全不同 → 不自动落位（防「深情版」类误配）")
    func sameTitleWrongArtistNotEligible() {
        let query = LyricsMatchQuery(title: "测试歌A", artist: "原唱歌手Z", durationMs: 234_000)
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "测试歌A", artists: ["无关歌手W"], durationMs: 234_100),
            query: query
        )
        #expect(score.titleExact)
        #expect(!score.artistExact)
        #expect(!score.artistContains)
        #expect(!score.isAutoHighEligible)
        #expect(score.confidence != .high)
    }

    @Test("版本文本保留：原版与不同版本不判精确或自动高置信", arguments: ["伴奏", "翻唱", "Live", "日语版"])
    func bracketVersionRemainsDistinct(version: String) {
        let query = LyricsMatchQuery(title: "星河纸船", artist: "虚拟歌手X", durationMs: 234_000)
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "星河纸船（\(version)）", artists: ["虚拟歌手X"], durationMs: 234_000),
            query: query
        )
        #expect(!score.titleExact)
        #expect(score.titleContains)
        #expect(!score.isAutoHighEligible)
        #expect(score.confidence != .high)
    }

    @Test("显式版本查询优先同版，保留版本文本的全半角和大小写归一", arguments: ["翻唱", "Live", "日语版"])
    func explicitVersionPrefersSameVersion(version: String) {
        let query = LyricsMatchQuery(title: "星河纸船（\(version)）", artist: "虚拟歌手X", durationMs: 234_000)
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 3, title: "星河纸船", artists: ["虚拟歌手X"], durationMs: 234_000),
                candidate(id: 1, title: "星河纸船（轻声版）", artists: ["虚拟歌手X"], durationMs: 234_000),
                candidate(id: 9, title: "星河纸船【\(version.uppercased())】", artists: ["虚拟歌手X"], durationMs: 236_500)
            ],
            query: query
        )
        #expect(ranked.first?.candidate.songId == 9)
        #expect(ranked.first?.score.titleExact == true)
        #expect(ranked.first?.score.isAutoHighEligible == true)
        #expect(ranked.dropFirst().allSatisfy { !$0.score.titleExact && !$0.score.isAutoHighEligible })
    }

    @Test("明确伴奏标题始终排除，即使查询歌名、歌手和时长完全匹配", arguments: [
        "星河纸船(伴奏)", "星河纸船（伴奏）", "星河纸船【伴奏】", "星河纸船[伴奏]",
        "星河纸船 （ 伴奏 ）", "星河纸船 伴奏", "星河纸船 - 伴奏", "星河纸船—伴奏",
        "伴奏 - 星河纸船", "星河纸船伴奏版", "星河纸船 - 伴奏 版",
        "星河纸船 (Instrument)", "星河纸船 - INSTRUMENTAL", "星河纸船【Ｉｎｓｔｒｕｍｅｎｔａｌ】",
        "星河纸船（Instrumental版）", "星河纸船 Instrument版", "星河纸船 (Instrumental 版)"
    ])
    func instrumentalVersionsAreExcluded(title: String) {
        let ranked = LyricsMatchRanker.rank(
            candidates: [candidate(id: 1, title: title, artists: ["虚拟歌手X"], durationMs: 234_000)],
            query: LyricsMatchQuery(title: title, artist: "虚拟歌手X", durationMs: 234_000)
        )
        #expect(ranked.isEmpty)
    }

    @Test("普通歌名不因含伴奏或较长英文单词而被排除", arguments: [
        "为月光伴奏", "伴奏着微风", "星河纸船（Instrumentation）", "The Instrumentalist",
        "Reinstrument", "Instrument_Collection"
    ])
    func ordinaryTitlesRemainAvailable(title: String) {
        let entry = candidate(id: 1, title: title, artists: [])
        let ranked = LyricsMatchRanker.rank(candidates: [entry], query: LyricsMatchQuery(title: title))
        #expect(ranked.map(\.candidate) == [entry])
    }

    @Test("伴奏标签只检查标题，不检查歌手或专辑且保留完整候选")
    func instrumentalMetadataDoesNotHideVocalTitle() {
        let entry = NeteaseSongCandidate(
            songId: 1,
            title: "星河纸船",
            artists: ["伴奏", "Instrument"],
            album: "星河纸船（伴奏版 / Instrumental）",
            durationMs: 234_000
        )
        let ranked = LyricsMatchRanker.rank(candidates: [entry], query: LyricsMatchQuery(title: entry.title))
        #expect(ranked.map(\.candidate) == [entry])
    }

    @Test("混合结果排除伴奏后，仍按总分、毫秒时长差和搜索顺序排序")
    func filteredCandidatesKeepExistingOrdering() {
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 1, title: "星河纸船", artists: ["虚拟歌手X"], durationMs: 236_500),
                candidate(id: 2, title: "星河纸船（伴奏）", artists: ["虚拟歌手X"], durationMs: 234_000),
                candidate(id: 90, title: "星河纸船", artists: ["虚拟歌手X"], durationMs: 234_300),
                candidate(id: 3, title: "星河纸船 - Instrumental", artists: ["虚拟歌手X"], durationMs: 234_000),
                candidate(id: 40, title: "星河纸船", artists: ["虚拟歌手X"], durationMs: 233_700),
                candidate(id: 5, title: "星河纸船 (Live)", artists: ["虚拟歌手X"], durationMs: 234_000)
            ],
            query: LyricsMatchQuery(title: "星河纸船", artist: "虚拟歌手X", durationMs: 234_000)
        )
        #expect(ranked.map(\.candidate.songId) == [90, 40, 1, 5])
    }

    @Test("搜索结果全部是伴奏时不保留低置信或自动获取候选")
    func allInstrumentalResultsAreEmpty() {
        let titles = ["星河纸船（伴奏）", "星河纸船伴奏版", "星河纸船 (Instrumental)"]
        let ranked = LyricsMatchRanker.rank(
            candidates: titles.enumerated().map { candidate(id: Int64($0.offset), title: $0.element, artists: []) },
            query: LyricsMatchQuery(title: "星河纸船")
        )
        #expect(ranked.isEmpty)
    }

    @Test("全半角与大小写归一")
    func widthAndCaseNormalized() {
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "ＴＥＳＴ ＳＯＮＧ", artists: []),
            query: LyricsMatchQuery(title: "test song")
        )
        #expect(score.titleExact)
    }

    @Test("feat 艺人拆分：feat 部分与查询歌手一致即判精确")
    func featuredArtistTokenized() {
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "合作曲", artists: ["主唱P feat. 客串歌手Y"]),
            query: LyricsMatchQuery(title: "合作曲", artist: "客串歌手Y")
        )
        #expect(score.artistExact)
    }

    @Test("多艺人列表：任一匹配即判精确")
    func multiArtistAnyMatch() {
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "合作曲", artists: ["虚拟歌手X", "客串歌手Y"]),
            query: LyricsMatchQuery(title: "合作曲", artist: "客串歌手Y、伴奏团Q")
        )
        #expect(score.artistExact)
    }

    @Test("时长冲突（差 >3s）阻断自动落位并扣分")
    func durationConflictBlocksEligibility() {
        let query = LyricsMatchQuery(title: "测试歌A", artist: "虚拟歌手X", durationMs: 234_000)
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "测试歌A", artists: ["虚拟歌手X"], durationMs: 260_000),
            query: query
        )
        #expect(score.durationDeltaMs == 26_000)
        #expect(!score.isAutoHighEligible)
    }

    @Test("时长未知：文本双证（歌名+歌手）仍可自动落位，不硬卡时长")
    func unknownDurationStillEligible() {
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "测试歌A", artists: ["虚拟歌手X"]),
            query: LyricsMatchQuery(title: "测试歌A", artist: "虚拟歌手X")
        )
        #expect(score.durationDeltaMs == nil)
        #expect(score.isAutoHighEligible)
    }

    @Test("排序优先总分：版本和歌手匹配先于时长差")
    func rankingPrioritizesTextMatch() {
        let query = LyricsMatchQuery(title: "测试歌A", artist: "虚拟歌手X", durationMs: 234_000)
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 20, title: "测试歌A", artists: ["无关歌手W"], durationMs: 234_000),
                candidate(id: 10, title: "测试歌A (Live版)", artists: ["虚拟歌手X"], durationMs: 234_000),
                candidate(id: 40, title: "测试歌A", artists: ["虚拟歌手X"], durationMs: 236_500)
            ],
            query: query
        )
        #expect(ranked.map(\.candidate.songId) == [40, 10, 20])
        #expect(ranked.first?.score.confidence == .high)
    }

    @Test("同分按原始时长差排序：0、300、2500 毫秒")
    func equalScoresUseDurationDelta() {
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 1, title: "星河纸船", artists: [], durationMs: 236_500),
                candidate(id: 2, title: "星河纸船", artists: [], durationMs: 233_700),
                candidate(id: 9, title: "星河纸船", artists: [], durationMs: 234_000)
            ],
            query: LyricsMatchQuery(title: "星河纸船", durationMs: 234_000)
        )
        #expect(Set(ranked.map(\.score.totalScore)).count == 1)
        #expect(ranked.map(\.candidate.songId) == [9, 2, 1])
        #expect(ranked.map(\.score.durationDeltaMs) == [0, 300, 2_500])
    }

    @Test("显示同为 0.0 秒的微小差值仍按毫秒排序")
    func subDisplayPrecisionDeltaStillOrders() {
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 1, title: "星河纸船", artists: [], durationMs: 234_049),
                candidate(id: 9, title: "星河纸船", artists: [], durationMs: 233_999),
                candidate(id: 3, title: "星河纸船", artists: [], durationMs: 234_000)
            ],
            query: LyricsMatchQuery(title: "星河纸船", durationMs: 234_000)
        )
        #expect(ranked.map(\.candidate.songId) == [3, 9, 1])
        #expect(ranked.map(\.score.durationDeltaMs) == [0, 1, 49])
    }

    @Test("同分且时长差相同，保留搜索返回顺序，不按歌曲 ID")
    func identicalDeltasPreserveSearchOrder() {
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 90, title: "星河纸船", artists: [], durationMs: 234_001),
                candidate(id: 5, title: "星河纸船", artists: [], durationMs: 233_999),
                candidate(id: 40, title: "星河纸船", artists: [], durationMs: 234_001)
            ],
            query: LyricsMatchQuery(title: "星河纸船", durationMs: 234_000)
        )
        #expect(ranked.map(\.candidate.songId) == [90, 5, 40])
    }

    @Test("同分时已知时长差优先，未知差值之间保留搜索返回顺序")
    func knownDeltaPrecedesUnknownWithoutReorderingUnknowns() {
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 40, title: "星河纸船", artists: []),
                candidate(id: 90, title: "无关曲名", artists: ["虚拟歌手X"], durationMs: 234_300),
                candidate(id: 10, title: "无关曲名", artists: ["虚拟歌手X"], durationMs: 234_000),
                candidate(id: 1, title: "星河纸船", artists: [])
            ],
            query: LyricsMatchQuery(title: "星河纸船", artist: "虚拟歌手X", durationMs: 234_000)
        )
        // 未知时长候选靠歌名得 50 分，已知候选靠歌手和时长也得 50 分。
        #expect(ranked.allSatisfy { $0.score.totalScore == 50 })
        #expect(ranked.map(\.candidate.songId) == [10, 90, 40, 1])
        #expect(ranked.suffix(2).allSatisfy { $0.score.durationDeltaMs == nil })
    }

    @Test("查询时长未知，候选时长不参与排序，保留搜索返回顺序")
    func unknownQueryDurationPreservesSearchOrder() {
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 90, title: "星河纸船", artists: [], durationMs: 236_500),
                candidate(id: 5, title: "星河纸船", artists: []),
                candidate(id: 40, title: "星河纸船", artists: [], durationMs: 234_000)
            ],
            query: LyricsMatchQuery(title: "星河纸船")
        )
        #expect(ranked.allSatisfy { $0.score.durationDeltaMs == nil })
        #expect(ranked.map(\.candidate.songId) == [90, 5, 40])
    }

    @Test("歌名包含关系给部分分（remix 标题等场景）")
    func titleContainmentScores() {
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "测试歌A - 虚构Remix", artists: ["虚拟歌手X"]),
            query: LyricsMatchQuery(title: "测试歌A", artist: "虚拟歌手X")
        )
        #expect(!score.titleExact)
        #expect(score.titleContains)
        #expect(score.confidence == .medium || score.confidence == .low)
        #expect(!score.isAutoHighEligible)
    }
}
