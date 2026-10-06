import Foundation
import Testing
@testable import ShinLyricsProvider

// 匹配打分单测（纯函数，虚构曲目）。
// 重点覆盖：同名不同歌手、
// 括号后缀归一、全半角/大小写、feat 艺人、时长冲突降级。

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

    @Test("括号后缀归一：Live 版对原版歌名判精确")
    func bracketSuffixNormalized() {
        let query = LyricsMatchQuery(title: "测试歌A")
        let score = LyricsMatchRanker.score(
            candidate: candidate(id: 1, title: "测试歌A (Live版)", artists: []),
            query: query
        )
        #expect(score.titleExact)
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

    @Test("排序：总分降序，同分稳定（按 songId 升序）")
    func rankingOrder() {
        let query = LyricsMatchQuery(title: "测试歌A", artist: "虚拟歌手X", durationMs: 234_000)
        let ranked = LyricsMatchRanker.rank(
            candidates: [
                candidate(id: 30, title: "完全无关", artists: ["路人"]),
                candidate(id: 10, title: "测试歌A (Live版)", artists: ["虚拟歌手X"], durationMs: 234_100),
                candidate(id: 20, title: "测试歌A", artists: ["无关歌手W"]),
                candidate(id: 40, title: "测试歌A", artists: ["无关歌手W"])
            ],
            query: query
        )
        #expect(ranked.first?.candidate.songId == 10)
        #expect(ranked.first?.score.confidence == .high)
        // 同分的 20 与 40 保持 id 升序（稳定排序）。
        #expect(ranked.map(\.candidate.songId) == [10, 20, 40, 30])
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
