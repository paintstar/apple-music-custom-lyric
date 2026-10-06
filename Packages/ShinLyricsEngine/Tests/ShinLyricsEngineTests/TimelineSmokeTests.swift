import Foundation
import Testing
import ShinAppleKit
@testable import ShinLyricsEngine

/// 10,000 行输入可用；索引构建一次、查询二分，耗时合理。
@Suite("10,000 行冒烟")
struct TimelineSmokeTests {

    /// 确定性伪随机（LCG），不依赖外部包，重复运行结果一致。
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }

    @Test("10,000 行：乱序输入构建 + 10,000 次查询，正确且耗时合理")
    func tenThousandLines() throws {
        let count = 10_000
        let stepMs = Int64(350)
        var generator = SeededGenerator(seed: 0xA11CE)

        // 第 i 句起点 i*350ms；文档行序打乱，检验分组排序。
        var order = Array(0..<count)
        order.shuffle(using: &generator)
        var lines: [LyricLine] = []
        lines.reserveCapacity(count)
        for i in order {
            lines.append(LyricLine(startMs: Int64(i) * stepMs, text: "第\(i)句测试文本"))
        }
        let doc = LyricDocument(sourceFormat: .lrc, lines: lines)

        let buildStart = ContinuousClock.now
        let index = LyricsTimelineIndex(document: doc, userDelayMs: 0)
        let buildElapsed = ContinuousClock.now - buildStart
        #expect(index.timedLineCount == count)
        #expect(index.groupCount == count)
        #expect(buildElapsed < .seconds(2), "构建耗时 \(buildElapsed)")

        // 10,000 次散布查询：第 p/350 组必须命中对应文本。
        let duration: Int64 = 3_600_000
        let queryStart = ContinuousClock.now
        for j in 0..<count {
            let playback = Int64(j) * 331
            let lines = try #require(currentLines(of: index.query(playbackMs: playback, durationMs: duration)))
            let expectedIndex = Int(playback / stepMs)
            #expect(lines.count == 1)
            #expect(lines[0].text == "第\(expectedIndex)句测试文本", "playback=\(playback)")
        }
        let queryElapsed = ContinuousClock.now - queryStart
        #expect(queryElapsed < .seconds(2), "10,000 次查询耗时 \(queryElapsed)")

        // 典型偏移查询与跳转反算在大型索引上同样成立。
        let offsetIndex = index.withUserDelayMs(500)
        let someId = try #require(doc.lines.first { $0.startMs == 70_000 }?.id)
        #expect(offsetIndex.effectiveStartMs(forLineId: someId) == 70_500)
        #expect(offsetIndex.seekPositionMs(forLineId: someId, durationMs: duration) == 70_500)
    }
}
