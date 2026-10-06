import Foundation
import Testing
@testable import ShinAppleKit

/// 测试用线程安全计数器（处理器是 @Sendable 闭包）。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}

/// 测试用线程安全快照收集器。
private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [PlaybackSnapshot] = []
    var snapshots: [PlaybackSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return _snapshots
    }
    func append(_ snapshot: PlaybackSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        _snapshots.append(snapshot)
    }
}

/// MockPlaybackController 单元测试。
/// 全部使用原创虚构标识（"mock-song-1" 等），不含真实歌曲信息。
@Suite("MockPlaybackController")
struct MockPlaybackControllerTests {

    private func track(
        _ id: String,
        title: String? = nil,
        artist: String? = nil,
        durationMs: Int64? = 100_000
    ) -> MockTrack {
        MockTrack(
            identity: CatalogIdentity(storefront: "us", catalogSongId: id),
            title: title,
            artist: artist,
            durationMs: durationMs
        )
    }

    @Test("初始快照：未知时间为 nil 而不是 0")
    func initialSnapshotHasNilTimes() {
        let controller = MockPlaybackController()
        let snapshot = controller.snapshot()
        #expect(snapshot.trackEpoch == 0)
        #expect(snapshot.track == nil)
        #expect(snapshot.positionMs == nil)
        #expect(snapshot.durationMs == nil)
        #expect(snapshot.status == .idle)
    }

    @Test("artist 契约：MockTrack 歌手进入快照；未知保持 nil")
    func artistFlowsIntoSnapshot() {
        let controller = MockPlaybackController()
        controller.setMockQueue(
            [track("mock-song-1", title: "测试曲目一", artist: "演示歌手甲")],
            startAt: 0
        )
        let snapshot = controller.snapshot()
        #expect(snapshot.title == "测试曲目一")
        #expect(snapshot.artist == "演示歌手甲")

        // 未提供歌手时保持 nil（不冒充空串）。
        let controllerNoArtist = MockPlaybackController()
        controllerNoArtist.setMockQueue([track("mock-song-1")], startAt: 0)
        #expect(controllerNoArtist.snapshot().artist == nil)
    }

    @Test("重复订阅/退订 20 次无监听累积")
    func repeatedSubscribeCancelDoesNotAccumulate() {
        let controller = MockPlaybackController()
        controller.setMockQueue([track("mock-song-1")], startAt: 0)

        let calls = CallCounter()
        let kept = controller.subscribe { _ in calls.increment() }

        for _ in 0..<20 {
            let handle = controller.subscribe { _ in }
            handle.cancel()
        }
        #expect(controller.subscriberCount == 1)

        controller.advanceTime(byMs: 1_000)
        #expect(calls.value == 1)

        kept.cancel()
        controller.advanceTime(byMs: 1_000)
        #expect(calls.value == 1)
        #expect(controller.subscriberCount == 0)
    }

    @Test("重复取消同一句柄是安全的")
    func doubleCancelIsSafe() {
        let controller = MockPlaybackController()
        let handle = controller.subscribe { _ in }
        handle.cancel()
        handle.cancel()
        #expect(controller.subscriberCount == 0)
    }

    @Test("seek 后快照立即更新")
    func seekUpdatesSnapshot() async throws {
        let controller = MockPlaybackController()
        try await controller.setQueue(
            [CatalogIdentity(storefront: "us", catalogSongId: "mock-song-1")],
            startAt: nil
        )
        try await controller.seek(positionMs: 50_000)
        let snapshot = controller.snapshot()
        #expect(snapshot.positionMs == 50_000)
        #expect(snapshot.trackEpoch == 1)
    }

    @Test("seek 越界被裁剪到时长范围")
    func seekClampsToDuration() async throws {
        let controller = MockPlaybackController()
        controller.setMockQueue([track("mock-song-1", durationMs: 1_000)], startAt: 0)
        try await controller.seek(positionMs: 5_000)
        #expect(controller.snapshot().positionMs == 1_000)
        try await controller.seek(positionMs: -100)
        #expect(controller.snapshot().positionMs == 0)
    }

    @Test("暂停后推进时钟位置不变")
    func pausedClockAdvanceDoesNotMovePosition() async throws {
        let controller = MockPlaybackController()
        let calls = CallCounter()
        _ = controller.subscribe { _ in calls.increment() }
        controller.setMockQueue([track("mock-song-1")], startAt: 0)
        try await controller.pause()
        controller.advanceTime(byMs: 5_000)
        let snapshot = controller.snapshot()
        #expect(snapshot.positionMs == 0)
        #expect(snapshot.status == .paused)
        // setQueue 与 pause 各通知一次；暂停后推进时钟不应再通知。
        #expect(calls.value == 2)
    }

    @Test("播放中推进时钟位置前进")
    func playingClockAdvanceMovesPosition() {
        let controller = MockPlaybackController()
        controller.setMockQueue([track("mock-song-1")], startAt: 0)
        controller.advanceTime(byMs: 1_000)
        controller.advanceTime(byMs: 2_500)
        let snapshot = controller.snapshot()
        #expect(snapshot.positionMs == 3_500)
        #expect(snapshot.status == .playing)
    }

    @Test("next/previous 递增 trackEpoch")
    func trackSwitchingIncrementsEpoch() async throws {
        let controller = MockPlaybackController()
        controller.setMockQueue(
            [track("mock-song-1"), track("mock-song-2"), track("mock-song-3")],
            startAt: 0
        )
        #expect(controller.snapshot().trackEpoch == 1)
        try await controller.next()
        #expect(controller.snapshot().track?.catalogSongId == "mock-song-2")
        #expect(controller.snapshot().trackEpoch == 2)
        try await controller.next()
        #expect(controller.snapshot().trackEpoch == 3)
        // 末尾再 next：不切歌，进入 ended。
        try await controller.next()
        #expect(controller.snapshot().status == .ended)
        #expect(controller.snapshot().trackEpoch == 3)
        try await controller.previous()
        #expect(controller.snapshot().track?.catalogSongId == "mock-song-2")
        #expect(controller.snapshot().trackEpoch == 4)
        #expect(controller.snapshot().positionMs == 0)
    }

    @Test("播放结束自动切下一首")
    func playbackEndAutoAdvances() {
        let controller = MockPlaybackController()
        controller.setMockQueue(
            [track("mock-song-1", durationMs: 1_000), track("mock-song-2", durationMs: 60_000)],
            startAt: 0
        )
        controller.advanceTime(byMs: 1_500)
        let snapshot = controller.snapshot()
        #expect(snapshot.track?.catalogSongId == "mock-song-2")
        #expect(snapshot.trackEpoch == 2)
        #expect(snapshot.positionMs == 0)
        #expect(snapshot.status == .playing)
    }

    @Test("末尾曲目播放结束进入 ended")
    func playbackEndWithoutNextEntersEnded() {
        let controller = MockPlaybackController()
        controller.setMockQueue([track("mock-song-1", durationMs: 1_000)], startAt: 0)
        controller.advanceTime(byMs: 1_200)
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .ended)
        #expect(snapshot.positionMs == 1_000)
    }

    @Test("关闭自动续播后结束停在 ended")
    func autoAdvanceDisabledStopsAtEnd() {
        let controller = MockPlaybackController(autoAdvanceOnEnd: false)
        controller.setMockQueue(
            [track("mock-song-1", durationMs: 1_000), track("mock-song-2", durationMs: 60_000)],
            startAt: 0
        )
        controller.advanceTime(byMs: 1_500)
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .ended)
        #expect(snapshot.track?.catalogSongId == "mock-song-1")
    }

    @Test("缓冲态保持最后已知位置")
    func bufferingKeepsLastKnownPosition() {
        let controller = MockPlaybackController()
        controller.setMockQueue([track("mock-song-1")], startAt: 0)
        controller.advanceTime(byMs: 2_000)
        controller.simulateBuffering()
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .buffering)
        #expect(snapshot.positionMs == 2_000)
    }

    @Test("错误注入：未知时间保持 nil，绝不冒充 0")
    func errorInjectionKeepsUnknownTimeNil() async throws {
        let controller = MockPlaybackController()
        controller.injectError(.trackUnavailable)
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .error)
        #expect(snapshot.errorCode == "trackUnavailable")
        #expect(snapshot.positionMs == nil)
        #expect(snapshot.durationMs == nil)
    }

    @Test("空队列 play 抛出 trackUnavailable")
    func playWithoutQueueThrows() async {
        let controller = MockPlaybackController()
        await #expect(throws: PlaybackError.trackUnavailable) {
            try await controller.play()
        }
    }

    @Test("dispose 清空全部监听")
    func disposeClearsAllListeners() async throws {
        let controller = MockPlaybackController()
        let calls = CallCounter()
        _ = controller.subscribe { _ in calls.increment() }
        _ = controller.subscribe { _ in calls.increment() }
        #expect(controller.subscriberCount == 2)

        controller.dispose()
        #expect(controller.subscriberCount == 0)

        // dispose 后变更不再通知。
        try await controller.setQueue(
            [CatalogIdentity(storefront: "us", catalogSongId: "mock-song-1")],
            startAt: nil
        )
        #expect(calls.value == 0)

        // dispose 后新订阅立即失效。
        _ = controller.subscribe { _ in calls.increment() }
        #expect(controller.subscriberCount == 0)
        controller.advanceTime(byMs: 1_000)
        #expect(calls.value == 0)
    }

    @Test("相同操作序列产生相同快照")
    func deterministicOutputForSameInput() async throws {
        func run() async -> [PlaybackSnapshot] {
            let controller = MockPlaybackController()
            let collector = SnapshotCollector()
            _ = controller.subscribe { collector.append($0) }
            controller.setMockQueue(
                [track("mock-song-1", durationMs: 5_000), track("mock-song-2", durationMs: 5_000)],
                startAt: 0
            )
            controller.advanceTime(byMs: 2_000)
            try? await controller.seek(positionMs: 4_500)
            controller.advanceTime(byMs: 1_000)
            try? await controller.next()
            controller.advanceTime(byMs: 500)
            collector.append(controller.snapshot())
            return collector.snapshots
        }

        let first = await run()
        let second = await run()
        #expect(first == second)
        #expect(!first.isEmpty)
    }
}
