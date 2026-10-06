import Foundation
import Testing
@testable import ShinLyricsEngine

/// 偏移样例、offset 只应用一次、userDelay 方向与幅度、
/// 负 effectiveStart、等价坐标一致性、点击跳转反算与裁剪。
@Suite("偏移公式与跳转反算")
struct OffsetAndSeekTests {

    // MARK: 偏移样例

    @Test("样例：startMs=10000、sourceOffset=200、userDelay=500 → 10300 生效")
    func offsetSampleActivatesAt10300() throws {
        let doc = TimelineFixture.document(sourceOffsetMs: 200, lines: [(10_000, "偏移样例测试文本")])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 500)
        #expect(index.query(playbackMs: 10_299, durationMs: nil) == .noCurrentLine)
        let lines = try #require(currentLines(of: index.query(playbackMs: 10_300, durationMs: nil)))
        #expect(lines.map(\.text) == ["偏移样例测试文本"])
        #expect(lines[0].effectiveStartMs == 10_300)
    }

    @Test("点击该行反算请求 10,300ms；duration 已知时按 [0, duration] 裁剪，负值裁到 0")
    func seekPositionUsesEffectiveStartAndClamps() throws {
        let doc = TimelineFixture.document(sourceOffsetMs: 200, lines: [(10_000, "偏移样例测试文本")])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 500)
        let id = try #require(doc.lines.first?.id)
        #expect(index.seekPositionMs(forLineId: id, durationMs: nil) == 10_300)
        #expect(index.seekPositionMs(forLineId: id, durationMs: 10_000) == 10_000)
        #expect(index.seekPositionMs(forLineId: id, durationMs: 10_299) == 10_299)

        // 负 effective 裁到 0
        let negativeDoc = TimelineFixture.document(sourceOffsetMs: 2_000, lines: [(1_000, "负起点测试文本")])
        let negativeIndex = LyricsTimelineIndex(document: negativeDoc, userDelayMs: 0)
        let negativeId = try #require(negativeDoc.lines.first?.id)
        #expect(negativeIndex.seekPositionMs(forLineId: negativeId, durationMs: 6_000) == 0)
        #expect(negativeIndex.seekPositionMs(forLineId: negativeId, durationMs: nil) == 0)

        // 未知 id 返回 nil
        #expect(index.seekPositionMs(forLineId: UUID(), durationMs: nil) == nil)
    }

    @Test("负 effectiveStart 合法存在于内部时间轴：播放 0ms 直接选中应生效行组")
    func negativeEffectiveStartActiveAtPlaybackZero() throws {
        let doc = TimelineFixture.document(sourceOffsetMs: 2_000, lines: [
            (1_000, "提前组测试文本"),
            (4_000, "常规组测试文本")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        // 有效起点 -1000 / 2000：0ms 已落在第一组区间内
        #expect(index.groupCount == 2)
        #expect(
            try #require(currentLines(of: index.query(playbackMs: 0, durationMs: nil))).map(\.text)
                == ["提前组测试文本"]
        )
        #expect(
            try #require(currentLines(of: index.query(playbackMs: 1_999, durationMs: nil))).map(\.text)
                == ["提前组测试文本"]
        )
        #expect(
            try #require(currentLines(of: index.query(playbackMs: 2_000, durationMs: nil))).map(\.text)
                == ["常规组测试文本"]
        )
        // 负播放时间仍然不猜测
        #expect(index.query(playbackMs: -1, durationMs: nil) == .noCurrentLine)
    }

    // MARK: 不烘焙、不累计

    @Test("sourceOffset 只应用一次：查询与重建不改动文档、不重复累计")
    func offsetAppliedExactlyOnce() throws {
        let doc = TimelineFixture.document(sourceOffsetMs: 200, lines: [(10_000, "偏移样例测试文本")])
        let id = try #require(doc.lines.first?.id)
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 500)
        _ = index.query(playbackMs: 10_300, durationMs: nil)
        _ = index.seekPositionMs(forLineId: id, durationMs: nil)

        // 文档模型保持原样：offset 未被烘焙进 line.startMs
        #expect(doc.lines.first?.startMs == 10_000)
        #expect(doc.sourceOffsetMs == 200)

        // 重复构建结果一致，不出现二次应用
        let rebuilt = LyricsTimelineIndex(document: doc, userDelayMs: 500)
        #expect(rebuilt == index)
        #expect(rebuilt.query(playbackMs: 10_299, durationMs: nil) == .noCurrentLine)
        #expect(
            try #require(currentLines(of: rebuilt.query(playbackMs: 10_300, durationMs: nil))).count == 1
        )
    }

    @Test("userDelay=+500 比 0 晚 500ms；-500 早 500ms")
    func userDelayShiftsActivationExactly() {
        let doc = TimelineFixture.threeGroupDocument()

        func result(forDelay delay: Int64, playback: Int64) -> LyricsTimelineQueryResult {
            LyricsTimelineIndex(document: doc, userDelayMs: delay)
                .query(playbackMs: playback, durationMs: 20_000)
        }

        // +500：第一组从 1,000 推迟到 1,500
        #expect(result(forDelay: 0, playback: 999) == .noCurrentLine)
        #expect(currentLines(of: result(forDelay: 0, playback: 1_000)) != nil)
        #expect(result(forDelay: 500, playback: 1_499) == .noCurrentLine)
        #expect(currentLines(of: result(forDelay: 500, playback: 1_500)) != nil)
        // -500：第一组提前到 500
        #expect(result(forDelay: -500, playback: 499) == .noCurrentLine)
        #expect(currentLines(of: result(forDelay: -500, playback: 500)) != nil)
    }

    @Test("连续多次调整 userDelay：生效点只随公式线性变化，无累计烘焙")
    func repeatedDelayAdjustmentsDoNotAccumulate() throws {
        let doc = TimelineFixture.document(lines: [(1_000, "第一句测试文本")])
        let id = try #require(doc.lines.first?.id)
        let delays: [Int64] = [0, 500, 800, 800, 300, -200, -500]

        var index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        for delay in delays {
            index = index.withUserDelayMs(delay)
            let expected = 1_000 + delay
            #expect(
                index.query(playbackMs: expected - 1, durationMs: nil) == .noCurrentLine,
                "delay=\(delay)"
            )
            #expect(currentLines(of: index.query(playbackMs: expected, durationMs: nil)) != nil, "delay=\(delay)")
            #expect(index.effectiveStartMs(forLineId: id) == expected)
        }
        // 重复同值（800 两次）不叠加；文档全程未被改动
        #expect(doc.lines.first?.startMs == 1_000)
        #expect(doc.sourceOffsetMs == 0)
    }

    // MARK: 等价坐标

    @Test("lyricsClock 等价坐标与 effectiveStart 公式全区间一致")
    func lyricsClockCoordinateMatchesEffectiveStart() {
        let doc = TimelineFixture.document(sourceOffsetMs: 200, lines: [
            (10_000, "第一句测试文本"),
            (12_000, ""),
            (15_000, "第二句测试文本")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 500)

        // 歌词时钟 clock = playback + 200 - 500 = playback - 300。
        // 等价关系：行生效 ⇔ 原始 startMs <= clock < 下一原始起点。
        for playback in stride(from: Int64(0), through: Int64(16_000), by: 100) {
            let clock = LyricsTimelineIndex.lyricsClockMs(playbackMs: playback, sourceOffsetMs: 200, userDelayMs: 500)
            #expect(clock == playback - 300, "playback=\(playback)")
            let result = index.query(playbackMs: playback, durationMs: nil)
            if clock < 10_000 {
                #expect(result == .noCurrentLine, "playback=\(playback)")
            } else if clock < 12_000 {
                #expect(currentLines(of: result)?.map(\.text) == ["第一句测试文本"], "playback=\(playback)")
            } else if clock < 15_000 {
                #expect(clearedBoundary(of: result) != nil, "playback=\(playback)")
            } else {
                #expect(currentLines(of: result)?.map(\.text) == ["第二句测试文本"], "playback=\(playback)")
            }
        }
    }
}
