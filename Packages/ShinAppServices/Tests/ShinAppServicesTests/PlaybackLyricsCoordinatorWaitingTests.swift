import Testing
import ShinAppleKit
@testable import ShinAppServices

// 与协调器主测试共享夹具；等待回归分文件保持测试主体易读。
extension PlaybackLyricsCoordinatorTests {
    @Test("等待边界随 seek 重算，同一等待段不逐采样发布")
    func waitingIntervalsFollowSnapshotsWithoutProgressNotifications() throws {
        let (coordinator, collector) = Self.makeCollector()
        let doc = LyricDocument(sourceFormat: .lrc, lines: [
            LyricLine(startMs: 2_000, text: "清晨的小船驶过窗边"),
            LyricLine(startMs: 4_000, text: ""),
            LyricLine(startMs: 5_000, text: ""),
            LyricLine(startMs: 8_000, text: "纸上的风吹向远处")
        ])
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 0))
        coordinator.applyLyrics(
            trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0
        )
        let intro = try #require(collector.last?.waitingInterval)
        #expect(intro.startMs == 0 && intro.endMs == 2_000 && intro.anchorLineId == nil)
        let initialCount = collector.count
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 1_000))
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 1_000, status: .paused))
        #expect(collector.count == initialCount)

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 4_500))
        let interlude = try #require(collector.last?.waitingInterval)
        #expect(interlude.startMs == 4_000 && interlude.endMs == 8_000)
        #expect(interlude.anchorLineId == doc.lines[1].id)
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 5_500))
        #expect(collector.last?.waitingInterval == interlude)
        let sameGroupCount = collector.count
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 6_000))
        #expect(collector.count == sameGroupCount)

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 8_000))
        #expect(collector.last?.waitingInterval == nil)
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 0))
        #expect(collector.last?.waitingInterval == intro)
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: nil))
        #expect(collector.last?.waitingInterval == nil)
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackB, epoch: 2, positionMs: 0))
        #expect(collector.last?.content == .idle && collector.last?.waitingInterval == nil)
    }
}
