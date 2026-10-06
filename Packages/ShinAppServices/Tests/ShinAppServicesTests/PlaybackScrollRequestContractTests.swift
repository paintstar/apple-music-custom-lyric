import Foundation
import Testing
import ShinAppleData
import ShinAppleKit
@testable import ShinAppServices

// 滚动请求回归测试：切行高亮变化时仍须发出定位请求。
// App 层的滚动定位请求由「display.content 变化 + currentLineIds 非空」驱动
// （LyricsPanelModel.apply → requestScroll → SyncLyricsArea.onChange → scrollTo）。
// 本套件锁定协调器的输入契约：每一次组变化都必须恰好产出一条「已变化」通知，
// 且携带非空 currentLineIds——App 层据此发滚动请求；协调器漏发/多发都会让
// 滚动跟随出现「漂行/卡住」回归。夹具为原创虚构文本，不使用任何真实歌词。

/// 构造打轴文档：starts 与「滚动契约测试第 N 行」一一对应（原创文本）。
private func document(starts: [Int64]) -> LyricDocument {
    LyricDocument(
        sourceFormat: .lrc,
        originalFilename: "滚动契约测试.lrc",
        lines: starts.enumerated().map { index, start in
            LyricLine(startMs: start, text: "滚动契约测试第\(index + 1)行")
        }
    )
}

/// 线程安全的通知收集器（回调 @Sendable；与协调器测试同款最小实现）。
private final class DisplayCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PlaybackLyricsDisplay] = []

    func append(_ value: PlaybackLyricsDisplay) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var all: [PlaybackLyricsDisplay] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("PlaybackScrollRequestContract")
struct PlaybackScrollRequestContractTests {

    @Test("组每次变化都有一条携带非空当前行的变化通知（滚动请求输入）")
    func everyGroupChangeEmitsChangedDisplayWithCurrentLines() {
        let collector = DisplayCollector()
        let coordinator = PlaybackLyricsCoordinator(
            onDisplayChange: { collector.append($0) },
            delayWriter: { _, _ in }
        )
        // 5 行、每行 2 秒（原创虚构文本）。
        let doc = document(starts: [0, 2_000, 4_000, 6_000, 8_000])
        coordinator.update(snapshot: PlaybackSnapshot(
            trackEpoch: 1, track: Fixture.trackA, positionMs: 0,
            durationMs: 60_000, status: .playing
        ))
        coordinator.applyLyrics(
            trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1,
            document: doc, userDelayMs: 0
        )

        // 逐行推进到末行：每次跨组都应有「changed + 非空 currentLineIds」通知。
        for line in doc.lines {
            coordinator.update(snapshot: PlaybackSnapshot(
                trackEpoch: 1, track: Fixture.trackA, positionMs: line.startMs,
                durationMs: 60_000, status: .playing
            ))
        }

        // 首次装载 1 条 + 4 次跨组 = 5 条通知；同组内重复快照零多余通知。
        #expect(collector.all.count == doc.lines.count)
        var previousIds: [UUID] = []
        for content in collector.all.map({ $0.content }) {
            guard case let .current(lineIds) = content else {
                Issue.record("期望 current 内容，得到 \(content)")
                continue
            }
            #expect(!lineIds.isEmpty)
            #expect(lineIds != previousIds) // 相邻通知必为不同组（滚动请求的触发条件）
            previousIds = lineIds
        }
        #expect(previousIds == [doc.lines[4].id]) // 末行成为当前组
    }
}
