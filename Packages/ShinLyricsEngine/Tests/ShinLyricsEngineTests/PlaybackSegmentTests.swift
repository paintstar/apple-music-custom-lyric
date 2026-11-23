import Foundation
import ShinAppleKit
import Testing
@testable import ShinLyricsEngine

/// 单句与 AB 句段播放边界查询单测：偏移换算、跨组封口、末句时长封口、
/// 未知时长末句拒绝盲猜、同时间戳组与未打轴/异常输入边界。
@Suite("单句与 AB 播放区间查询")
struct PlaybackSegmentTests {

    @Test("含 sourceOffsetMs 与 userDelayMs 的单句区间及负起点裁剪")
    func singleLineSegmentAppliesOffsetsAndClampsNegativeStart() {
        let doc = TimelineFixture.document(sourceOffsetMs: 200, lines: [
            (10_000, "偏移第一句测试文本"),
            (13_500, "偏移第二句测试文本"),
            (18_000, "偏移第三句测试文本")
        ])
        let baseIndex = LyricsTimelineIndex(document: doc, userDelayMs: 500)
        // effective = startMs - 200 + 500 = startMs + 300 -> 10_300 / 13_800 / 18_300
        let firstId = doc.lines[0].id
        let secondId = doc.lines[1].id
        #expect(
            baseIndex.playbackSegment(fromLineId: firstId, toLineId: firstId, durationMs: nil)
                == LyricsPlaybackSegment(startMs: 10_300, endMs: 13_800)
        )
        #expect(
            baseIndex.playbackSegment(fromLineId: secondId, toLineId: secondId, durationMs: 25_000)
                == LyricsPlaybackSegment(startMs: 13_800, endMs: 18_300)
        )

        // 调整 userDelay 后立即按新延迟计算区间
        let shiftedIndex = baseIndex.withUserDelayMs(-300)
        #expect(
            shiftedIndex.playbackSegment(fromLineId: firstId, toLineId: firstId, durationMs: nil)
                == LyricsPlaybackSegment(startMs: 9_500, endMs: 13_000)
        )

        // 负有效起点裁剪到 0，但终点仍为下一组有效起点；若整句完全落在 0ms 之前则返回 nil
        let negativeDoc = TimelineFixture.document(sourceOffsetMs: 3_000, lines: [
            (1_000, "整句位于零点前"),
            (2_500, "跨零点起始测试文本"),
            (5_000, "常规区间测试文本")
        ])
        let negativeIndex = LyricsTimelineIndex(document: negativeDoc, userDelayMs: 0)
        #expect(
            negativeIndex.playbackSegment(
                fromLineId: negativeDoc.lines[0].id,
                toLineId: negativeDoc.lines[0].id,
                durationMs: 10_000
            ) == nil
        )
        #expect(
            negativeIndex.playbackSegment(
                fromLineId: negativeDoc.lines[1].id,
                toLineId: negativeDoc.lines[1].id,
                durationMs: 10_000
            ) == LyricsPlaybackSegment(startMs: 0, endMs: 2_000)
        )
    }

    @Test("跨多行 AB 区间：终点取 endLineId 下一时间组起点，含定时清屏组边界")
    func multiLineSegmentUsesNextGroupBoundary() {
        let doc = TimelineFixture.document(lines: [
            (1_000, "测试句甲"),
            (3_000, "测试句乙"),
            (5_000, "测试句丙"),
            (7_200, "   "),
            (9_500, "测试句丁")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)

        #expect(
            index.playbackSegment(fromLineId: doc.lines[0].id, toLineId: doc.lines[2].id, durationMs: 15_000)
                == LyricsPlaybackSegment(startMs: 1_000, endMs: 7_200)
        )
        // 超过 durationMs 时按 durationMs 封口
        #expect(
            index.playbackSegment(fromLineId: doc.lines[0].id, toLineId: doc.lines[2].id, durationMs: 6_500)
                == LyricsPlaybackSegment(startMs: 1_000, endMs: 6_500)
        )
    }

    @Test("末句封口规则：已知 durationMs 使用时长封口，未知 durationMs 返回 nil")
    func lastGroupSegmentDependsOnKnownDuration() {
        let doc = TimelineFixture.threeGroupDocument()
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        let firstId = doc.lines[0].id
        let lastId = doc.lines[2].id

        #expect(
            index.playbackSegment(fromLineId: lastId, toLineId: lastId, durationMs: 12_000)
                == LyricsPlaybackSegment(startMs: 5_000, endMs: 12_000)
        )
        #expect(
            index.playbackSegment(fromLineId: firstId, toLineId: lastId, durationMs: 12_000)
                == LyricsPlaybackSegment(startMs: 1_000, endMs: 12_000)
        )
        #expect(index.playbackSegment(fromLineId: lastId, toLineId: lastId, durationMs: nil) == nil)
        #expect(index.playbackSegment(fromLineId: firstId, toLineId: lastId, durationMs: nil) == nil)
        #expect(index.playbackSegment(fromLineId: lastId, toLineId: lastId, durationMs: 5_000) == nil)
        #expect(index.playbackSegment(fromLineId: lastId, toLineId: lastId, durationMs: 4_000) == nil)
    }

    @Test("同时间戳组：单行或同组起止均按下一时间组起点封口")
    func sameTimestampGroupEndsAtNextGroupStart() {
        let doc = TimelineFixture.document(lines: [
            (2_000, "同组测试甲"),
            (2_000, "同组测试乙"),
            (5_400, "下一组测试丙")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        let lineA = doc.lines[0].id
        let lineB = doc.lines[1].id

        #expect(
            index.playbackSegment(fromLineId: lineA, toLineId: lineA, durationMs: nil)
                == LyricsPlaybackSegment(startMs: 2_000, endMs: 5_400)
        )
        #expect(
            index.playbackSegment(fromLineId: lineA, toLineId: lineB, durationMs: nil)
                == LyricsPlaybackSegment(startMs: 2_000, endMs: 5_400)
        )
        #expect(
            index.playbackSegment(fromLineId: lineB, toLineId: lineA, durationMs: nil)
                == LyricsPlaybackSegment(startMs: 2_000, endMs: 5_400)
        )
    }

    @Test("未打轴行、未知行与顺序倒置均返回 nil")
    func untimedUnknownAndReversedLinesReturnNil() {
        let doc = TimelineFixture.document(lines: [
            (1_000, "打轴第一句"),
            (nil, "未打轴中间句"),
            (4_000, "打轴第二句")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        let timed1 = doc.lines[0].id
        let untimed = doc.lines[1].id
        let timed2 = doc.lines[2].id

        #expect(index.playbackSegment(fromLineId: untimed, toLineId: timed2, durationMs: 10_000) == nil)
        #expect(index.playbackSegment(fromLineId: timed1, toLineId: untimed, durationMs: 10_000) == nil)
        #expect(index.playbackSegment(fromLineId: untimed, toLineId: untimed, durationMs: 10_000) == nil)
        #expect(index.playbackSegment(fromLineId: UUID(), toLineId: timed2, durationMs: 10_000) == nil)
        #expect(index.playbackSegment(fromLineId: timed1, toLineId: UUID(), durationMs: 10_000) == nil)
        #expect(index.playbackSegment(fromLineId: timed2, toLineId: timed1, durationMs: 10_000) == nil)
    }
}
