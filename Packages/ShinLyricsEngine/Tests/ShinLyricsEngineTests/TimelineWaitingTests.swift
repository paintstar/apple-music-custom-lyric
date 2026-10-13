import Foundation
import Testing
@testable import ShinLyricsEngine

@Suite("歌词等待区间")
struct TimelineWaitingTests {
    @Test("三秒是展示阈值，短空白保留清屏；前奏槽资格采用来源偏移及用户延迟")
    func indicatorThresholdUsesEffectiveIntervals() throws {
        let introDoc = TimelineFixture.document(sourceOffsetMs: 11, lines: [(3_010, "原创窗边小船")])
        let shortIntro = LyricsTimelineIndex(document: introDoc, userDelayMs: 0)
        #expect(shortIntro.waitingInterval(playbackMs: 0, durationMs: nil) != nil)
        #expect(shortIntro.indicatorIntervals.isEmpty)
        let delayed = shortIntro.withUserDelayMs(1)
        #expect(delayed.indicatorIntervals.count == 1 && delayed.indicatorIntervals[0].endMs == 3_000)
        #expect(delayed.withUserDelayMs(-1).indicatorIntervals.isEmpty)

        let shortDoc = TimelineFixture.document(lines: [(0, "原创晨光"), (1_000, ""), (3_999, "原创微风")])
        let short = LyricsTimelineIndex(document: shortDoc, userDelayMs: 0)
        #expect(short.indicatorIntervals.isEmpty)
        #expect(short.waitingInterval(playbackMs: 2_000, durationMs: nil)?.shouldShowIndicator == false)
        guard case .cleared = short.query(playbackMs: 2_000, durationMs: nil) else {
            Issue.record("省略圆点不能改变原空白的清屏语义")
            return
        }
        let longDoc = TimelineFixture.document(lines: [
            (0, "原创晨光"), (1_000, ""), (2_000, ""), (4_000, " "), (7_000, "原创微风")
        ])
        let long = LyricsTimelineIndex(document: longDoc, userDelayMs: 0)
        #expect(long.indicatorIntervals.count == 1)
        #expect(long.indicatorIntervals[0].anchorLineId == longDoc.lines[1].id)
        #expect(long.indicatorIntervals[0].startMs == 1_000 && long.indicatorIntervals[0].endMs == 7_000)
        #expect(long.waitingInterval(playbackMs: 1_000, durationMs: nil)
                == long.waitingInterval(playbackMs: 6_999, durationMs: nil))
    }

    @Test("前奏从零起算，开头连续空白不重启等待")
    func introductionHasStableInterval() throws {
        let doc = TimelineFixture.document(lines: [
            (2_000, ""), (3_000, "  "), (5_000, "风吹过纸做的小船")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        let interval = try #require(index.waitingInterval(playbackMs: 0, durationMs: 10_000))
        #expect(interval == LyricsWaitingInterval(
            startMs: 0, endMs: 5_000, nextLineId: doc.lines[2].id, anchorLineId: doc.lines[0].id
        ))
        for position: Int64 in [1_999, 2_000, 3_000, 4_999] {
            #expect(index.waitingInterval(playbackMs: position, durationMs: 10_000) == interval)
        }
        #expect(index.waitingInterval(playbackMs: 5_000, durationMs: 10_000) == nil)

        let noBlankDoc = TimelineFixture.document(lines: [(2_000, "云朵停在画纸上")])
        let noBlank = LyricsTimelineIndex(document: noBlankDoc, userDelayMs: 0)
        #expect(noBlank.waitingInterval(playbackMs: 0, durationMs: nil) == LyricsWaitingInterval(
            startMs: 0, endMs: 2_000, nextLineId: noBlankDoc.lines[0].id, anchorLineId: nil
        ))
    }

    @Test("明确空白段合并且只应用一次来源偏移和用户延迟")
    func blankRunUsesEffectiveTimes() throws {
        let doc = TimelineFixture.document(sourceOffsetMs: 1_000, lines: [
            (1_000, "窗边亮着一盏灯"), (3_000, ""), (4_000, ""),
            (6_000, "纸飞机绕过屋顶"), (9_000, "")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 500)
        let interval = try #require(index.waitingInterval(playbackMs: 2_500, durationMs: nil))
        #expect(interval == LyricsWaitingInterval(
            startMs: 2_500, endMs: 5_500, nextLineId: doc.lines[3].id, anchorLineId: doc.lines[1].id
        ))
        #expect(index.waitingInterval(playbackMs: 2_499, durationMs: nil) == nil)
        #expect(index.waitingInterval(playbackMs: 3_500, durationMs: nil) == interval)
        #expect(index.waitingInterval(playbackMs: 5_499, durationMs: nil) == interval)
        #expect(index.waitingInterval(playbackMs: 5_500, durationMs: nil) == nil)
        #expect(index.waitingInterval(playbackMs: 9_000, durationMs: nil) == nil)
        #expect(index.withUserDelayMs(1_000).waitingInterval(playbackMs: 3_000, durationMs: nil)?.endMs == 6_000)
    }

    @Test("未知位置、曲末及不可到达的下一句没有等待")
    func invalidAndEndedPositionsDoNotWait() {
        let doc = TimelineFixture.document(lines: [(1_000, ""), (5_000, "远处传来虚构的歌声")])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        #expect(index.waitingInterval(playbackMs: nil, durationMs: 10_000) == nil)
        #expect(index.waitingInterval(playbackMs: -1, durationMs: 10_000) == nil)
        #expect(index.waitingInterval(playbackMs: 1_000, durationMs: 5_000) == nil)
        #expect(index.waitingInterval(playbackMs: 1_000, durationMs: 4_000) == nil)
        #expect(index.waitingInterval(playbackMs: 4_000, durationMs: 4_000) == nil)
        #expect(index.waitingInterval(playbackMs: 1_000, durationMs: 5_001) != nil)
        let negativeStart = LyricsTimelineIndex(document: doc, userDelayMs: -6_000)
        #expect(negativeStart.waitingInterval(playbackMs: 0, durationMs: nil) == nil)
    }

    @Test("长句不推测间奏，全空白或无后续句不展示倒计时")
    func noInferredSingingEnd() {
        let doc = TimelineFixture.document(lines: [
            (0, "这是一句可以唱很久的原创文字"), (30_000, "下一句原创文字"), (35_000, "")
        ])
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        #expect(index.waitingInterval(playbackMs: 20_000, durationMs: 40_000) == nil)
        #expect(index.waitingInterval(playbackMs: 36_000, durationMs: 40_000) == nil)
        let blankOnly = LyricsTimelineIndex(
            document: TimelineFixture.document(lines: [(1_000, ""), (2_000, " ")]), userDelayMs: 0
        )
        #expect(blankOnly.waitingInterval(playbackMs: 0, durationMs: nil) == nil)
        #expect(blankOnly.waitingInterval(playbackMs: 1_500, durationMs: nil) == nil)
    }
}
