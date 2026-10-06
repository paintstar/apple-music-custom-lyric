import Testing
@testable import ShinLyricsEngine

/// 三组起点 1,000/2,000/5,000ms 的左闭右开边界、
/// 结束边界（时长已知/未知两版）、未知时间与纯文本规则。
@Suite("时间轴边界与首尾规则")
struct TimelineBoundaryTests {

    @Test("已知时长：0/999/1000/1999/2000/4999/5000/5999/6000 边界，左闭右开")
    func boundariesWithDurationKnown() throws {
        let index = LyricsTimelineIndex(document: TimelineFixture.threeGroupDocument(), userDelayMs: 0)
        let expectations: [(playback: Int64, text: String?)] = [
            (0, nil),
            (999, nil),
            (1_000, "第一句测试文本"),
            (1_999, "第一句测试文本"),
            (2_000, "第二句测试文本"),
            (4_999, "第二句测试文本"),
            (5_000, "第三句测试文本"),
            (5_999, "第三句测试文本"),
            (6_000, nil),
            (6_001, nil)
        ]
        for sample in expectations {
            let result = index.query(playbackMs: sample.playback, durationMs: 6_000)
            if let text = sample.text {
                let lines = try #require(currentLines(of: result), "playback=\(sample.playback)")
                #expect(lines.map(\.text) == [text], "playback=\(sample.playback)")
            } else {
                #expect(result == .noCurrentLine, "playback=\(sample.playback)")
            }
        }
    }

    @Test("未知时长：最后一组无限延续，不虚构结束时间")
    func lastGroupEnduresWithoutDuration() throws {
        let index = LyricsTimelineIndex(document: TimelineFixture.threeGroupDocument(), userDelayMs: 0)
        let playbacks: [Int64] = [5_999, 6_000, 60_000, 1_000_000]
        for playback in playbacks {
            let lines = try #require(
                currentLines(of: index.query(playbackMs: playback, durationMs: nil)),
                "playback=\(playback)"
            )
            #expect(lines.map(\.text) == ["第三句测试文本"])
        }
    }

    @Test("结束边界按播放器报告 duration 判定：恰好等于时长视为已结束")
    func endBoundaryComesFromReportedDuration() throws {
        let index = LyricsTimelineIndex(document: TimelineFixture.threeGroupDocument(), userDelayMs: 0)
        // 同一播放位置，随报告时长不同结果不同：引擎不自己猜时长
        #expect(index.query(playbackMs: 5_500, durationMs: 5_500) == .noCurrentLine)
        #expect(
            try #require(currentLines(of: index.query(playbackMs: 5_500, durationMs: 5_501))).map(\.text)
                == ["第三句测试文本"]
        )
    }

    @Test("playbackMs 为 nil 或负数一律无当前行，不猜测")
    func unknownOrNegativePlaybackHasNoCurrentLine() {
        let index = LyricsTimelineIndex(document: TimelineFixture.threeGroupDocument(), userDelayMs: 0)
        #expect(index.query(playbackMs: nil, durationMs: 6_000) == .noCurrentLine)
        #expect(index.query(playbackMs: nil, durationMs: nil) == .noCurrentLine)
        #expect(index.query(playbackMs: -1, durationMs: 6_000) == .noCurrentLine)
        #expect(index.query(playbackMs: -100_000, durationMs: nil) == .noCurrentLine)
    }

    @Test("纯文本与空文档：索引为空，任何查询都返回无当前行")
    func pureTextAndEmptyDocuments() {
        let textDoc = TimelineFixture.document(lines: [(nil, "未打轴第一句"), (nil, "未打轴第二句")])
        let textIndex = LyricsTimelineIndex(document: textDoc, userDelayMs: 0)
        #expect(textIndex.isEmpty)
        #expect(textIndex.timedLineCount == 0)
        #expect(textIndex.groupCount == 0)
        #expect(textIndex.query(playbackMs: 1_000, durationMs: 6_000) == .noCurrentLine)
        #expect(textIndex.query(playbackMs: nil, durationMs: nil) == .noCurrentLine)

        let emptyIndex = LyricsTimelineIndex(document: TimelineFixture.document(lines: []), userDelayMs: 500)
        #expect(emptyIndex.isEmpty)
        #expect(emptyIndex.query(playbackMs: 1_000, durationMs: nil) == .noCurrentLine)
    }
}
