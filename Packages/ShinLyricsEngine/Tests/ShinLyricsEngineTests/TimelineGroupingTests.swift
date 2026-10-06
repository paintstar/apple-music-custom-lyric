import Foundation
import ShinAppleKit
import Testing
@testable import ShinLyricsEngine

/// 同时间戳多行、来源顺序、定时空白清屏、未打轴行不参与高亮。
@Suite("时间组与清屏规则")
struct TimelineGroupingTests {

    @Test("同时间戳多行一起返回，保持来源顺序，多次查询 id 稳定")
    func sameTimestampLinesTogetherInSourceOrder() throws {
        let doc = TimelineFixture.document(lines: [
            (2_000, "合唱甲测试文本"),
            (2_000, "合唱乙测试文本")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        #expect(index.query(playbackMs: 1_999, durationMs: nil) == .noCurrentLine)

        let atStart = try #require(currentLines(of: index.query(playbackMs: 2_000, durationMs: nil)))
        let later = try #require(currentLines(of: index.query(playbackMs: 3_000, durationMs: nil)))
        #expect(atStart.map(\.text) == ["合唱甲测试文本", "合唱乙测试文本"])
        #expect(later.map(\.id) == atStart.map(\.id))
        #expect(atStart[0].id != atStart[1].id)
    }

    @Test("来源交错的时间戳仍按来源顺序成组（组内顺序 = 文档顺序）")
    func interleavedSourceOrder() throws {
        let doc = TimelineFixture.document(lines: [
            (2_000, "第二句测试文本"),
            (1_000, "第一句测试文本"),
            (2_000, "第三句测试文本")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        #expect(index.groupCount == 2)
        let early = try #require(currentLines(of: index.query(playbackMs: 1_500, durationMs: nil)))
        #expect(early.map(\.text) == ["第一句测试文本"])
        let late = try #require(currentLines(of: index.query(playbackMs: 2_000, durationMs: nil)))
        #expect(late.map(\.text) == ["第二句测试文本", "第三句测试文本"])
    }

    @Test("定时空白行是清屏边界：消耗区间但无可见行，可与无当前行区分")
    func blankLineClearsHighlight() throws {
        let doc = TimelineFixture.document(lines: [
            (1_000, "第一句测试文本"),
            (3_000, ""),
            (5_000, "第三句测试文本")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        #expect(
            try #require(currentLines(of: index.query(playbackMs: 2_999, durationMs: nil))).map(\.text)
                == ["第一句测试文本"]
        )

        let cleared = try #require(clearedBoundary(of: index.query(playbackMs: 3_000, durationMs: nil)))
        #expect(cleared.startMs == 3_000)
        #expect(cleared.lineIds.count == 1)

        // 清屏持续到下一组开始之前（左闭右开）
        #expect(clearedBoundary(of: index.query(playbackMs: 4_999, durationMs: nil)) != nil)
        #expect(
            try #require(currentLines(of: index.query(playbackMs: 5_000, durationMs: nil))).map(\.text)
                == ["第三句测试文本"]
        )
    }

    @Test("仅空白字符的定时行同样构成清屏边界；末组清屏按已知时长退出")
    func whitespaceOnlyLineIsClearBoundary() throws {
        let doc = TimelineFixture.document(lines: [
            (1_000, "第一句测试文本"),
            (3_000, "   ")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        #expect(clearedBoundary(of: index.query(playbackMs: 3_000, durationMs: nil)) != nil)
        // 清屏作为末组：时长未知时无限保持清屏
        #expect(clearedBoundary(of: index.query(playbackMs: 600_000, durationMs: nil)) != nil)
        // 时长已知：边界左闭右开
        #expect(clearedBoundary(of: index.query(playbackMs: 5_999, durationMs: 6_000)) != nil)
        #expect(index.query(playbackMs: 6_000, durationMs: 6_000) == .noCurrentLine)
    }

    @Test("startMs=nil 的未打轴行永不参与高亮，也没有有效起点")
    func untimedLinesNeverHighlight() throws {
        let untimedId = UUID()
        let doc = LyricDocument(
            sourceFormat: .lrc,
            lines: [
                LyricLine(id: untimedId, startMs: nil, text: "未打轴测试文本"),
                LyricLine(startMs: 1_000, text: "第一句测试文本"),
                LyricLine(startMs: nil, text: "未打轴第二句测试文本")
            ]
        )

        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        #expect(index.timedLineCount == 1)
        #expect(index.groupCount == 1)
        #expect(index.query(playbackMs: 0, durationMs: nil) == .noCurrentLine)

        let playbacks: [Int64] = [1_000, 5_000, 100_000]
        for playback in playbacks {
            let lines = try #require(currentLines(of: index.query(playbackMs: playback, durationMs: nil)))
            #expect(lines.map(\.text) == ["第一句测试文本"], "playback=\(playback)")
        }
        #expect(index.effectiveStartMs(forLineId: untimedId) == nil)
        #expect(index.seekPositionMs(forLineId: untimedId, durationMs: 6_000) == nil)
    }
}
