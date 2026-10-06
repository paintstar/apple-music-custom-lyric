import Testing
import Foundation
import ShinAppleKit
@testable import ShinMusicScript

// MARK: - 快照发布测试（FakeExecutor 驱动；startsSampler=false 保持确定性）

struct SnapshotPublishTests {

    private func makeController(_ executor: FakeMusicScriptExecutor) -> MusicScriptPlaybackController {
        MusicScriptPlaybackController(
            executor: executor,
            samplingIntervalMs: 60_000,
            startsSampler: false
        )
    }

    @Test("初始快照：无曲目、未知时间为 nil、会话/能力已填充")
    func initialSnapshot() {
        let controller = makeController(FakeMusicScriptExecutor())
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .idle)
        #expect(snapshot.trackRef == nil)
        #expect(snapshot.positionMs == nil)
        #expect(snapshot.durationMs == nil)
        #expect(snapshot.title == nil)
        #expect(snapshot.sessionEpoch >= 1)
        #expect(snapshot.capabilities == PlaybackCapabilities(
            playPause: true, next: true, previous: true, seek: true
        ))
    }

    @Test("快照解析：全部采样字段正确填充；秒→毫秒在适配器边界完成")
    func snapshotParsedFully() {
        let executor = FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()])
        let controller = makeController(executor)
        controller.refreshOnce()
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .playing)
        #expect(snapshot.trackRef == Fixtures.refA)
        #expect(snapshot.trackEpoch == 1)
        #expect(snapshot.title == "测试曲目甲")
        #expect(snapshot.artist == "测试歌手乙")
        #expect(snapshot.positionMs == 106_773)
        #expect(snapshot.durationMs == 123_871)
        #expect(snapshot.seq >= 1)
        #expect(snapshot.sampledAtMonotonicMs > 0)
        #expect(snapshot.requestDurationMs >= 0)
        #expect(snapshot.errorCode == nil)
    }

    @Test("切歌 epoch 递增：A→B→A 各递增一次；歌名与 trackRef 跟随实际曲目")
    func trackEpochIncrementsOnChange() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(pid: Fixtures.pidA, title: "测试曲目甲"),
            Fixtures.snapshot(pid: Fixtures.pidB, title: "测试曲目丙", duration: 200.5),
            Fixtures.snapshot(pid: Fixtures.pidA, title: "测试曲目甲")
        ])
        let controller = makeController(executor)
        controller.refreshOnce()
        #expect(controller.snapshot().trackEpoch == 1)
        #expect(controller.snapshot().trackRef == Fixtures.refA)
        controller.refreshOnce()
        let second = controller.snapshot()
        #expect(second.trackEpoch == 2)
        #expect(second.trackRef == Fixtures.refB)
        #expect(second.title == "测试曲目丙")
        #expect(second.durationMs == 200_500)
        controller.refreshOnce()
        #expect(controller.snapshot().trackEpoch == 3)
        #expect(controller.snapshot().trackRef == Fixtures.refA)
    }

    @Test("Music 未运行：状态 notRunning，位置/时长/歌名全部 nil（不保留旧值冒充）")
    func notRunningState() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(),
            .musicNotRunning
        ])
        let controller = makeController(executor)
        controller.refreshOnce()
        #expect(controller.snapshot().status == .playing)
        controller.refreshOnce()
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .notRunning)
        #expect(snapshot.trackRef == nil)
        #expect(snapshot.positionMs == nil)
        #expect(snapshot.durationMs == nil)
        #expect(snapshot.title == nil)
        // 曲目卸载是生命周期变化：epoch 递增。
        #expect(snapshot.trackEpoch == 2)
    }

    @Test("运行但无曲目：状态 noTrack，无假数据")
    func noTrackState() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            .noCurrentTrack(stateCode: MusicScriptPlayerState.paused)
        ])
        let controller = makeController(executor)
        controller.refreshOnce()
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .noTrack)
        #expect(snapshot.positionMs == nil)
        #expect(snapshot.trackRef == nil)
    }

    @Test("同批身份不一致：整批丢弃，快照保持上一发布值，不发通知")
    func identityChangedBatchDiscarded() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(),
            .identityChangedDuringRead,
            Fixtures.snapshot(pid: Fixtures.pidB, title: "测试曲目丙")
        ])
        let controller = makeController(executor)
        let counter = NotificationCounter()
        _ = controller.subscribe { snapshot in counter.record(snapshot) }
        controller.refreshOnce()
        let before = controller.snapshot()
        #expect(counter.notificationCount == 1)
        #expect(controller.refreshOnce()) // 丢弃混合批次，但必须保持后续采样循环运行
        let after = controller.snapshot()
        #expect(after.contentValue == before.contentValue)
        #expect(counter.notificationCount == 1) // 未发布
        controller.refreshOnce()
        #expect(controller.snapshot().trackRef == Fixtures.refB)
        #expect(counter.notificationCount == 2)
    }

    @Test("读取失败（权限拒绝）：error + 稳定码，值字段 nil，trackRef 保留，位置不冒充")
    func failedReadMapsToErrorState() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(),
            .failed(.permissionDenied)
        ])
        let controller = makeController(executor)
        controller.refreshOnce()
        controller.refreshOnce()
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .error)
        #expect(snapshot.errorCode == "music:permissionDenied")
        #expect(snapshot.positionMs == nil)
        #expect(snapshot.durationMs == nil)
        #expect(snapshot.title == nil)
        #expect(snapshot.trackRef == Fixtures.refA) // 身份未变，epoch 不动
        #expect(snapshot.trackEpoch == 1)
    }

    @Test("单字段失败（position）：fieldUnavailable 稳定码，positionMs 为 nil")
    func fieldFailureKeepsNilPosition() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            .failed(.fieldUnavailable("playerPosition"))
        ])
        let controller = makeController(executor)
        controller.refreshOnce()
        let snapshot = controller.snapshot()
        #expect(snapshot.status == .error)
        #expect(snapshot.errorCode == "music:fieldUnavailable:playerPosition")
        #expect(snapshot.positionMs == nil)
    }

    @Test("非有限位置：换算为 nil，状态保持 playing（采样不冒充时间）")
    func nonFinitePositionBecomesNil() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(position: .nan),
            Fixtures.snapshot(position: .infinity)
        ])
        let controller = makeController(executor)
        controller.refreshOnce()
        #expect(controller.snapshot().positionMs == nil)
        #expect(controller.snapshot().status == .playing)
        controller.refreshOnce()
        #expect(controller.snapshot().positionMs == nil)
    }

    @Test("内容未变化不重复发布：订阅者只收到一次；seq 只在发布时递增可见")
    func unchangedContentNotRepublished() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(),
            Fixtures.snapshot()
        ])
        let controller = makeController(executor)
        let counter = NotificationCounter()
        _ = controller.subscribe { snapshot in counter.record(snapshot) }
        controller.refreshOnce()
        controller.refreshOnce()
        #expect(counter.notificationCount == 1)
        #expect(controller.snapshot().positionMs == 106_773)
    }

    @Test("会话编号：同一控制器快照 sessionEpoch 稳定；新控制器单调递增")
    func sessionEpochStablePerController() {
        let first = makeController(FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()]))
        first.refreshOnce()
        let epoch = first.snapshot().sessionEpoch
        first.refreshOnce()
        #expect(first.snapshot().sessionEpoch == epoch) // 同一会话内稳定
        let second = makeController(FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()]))
        second.refreshOnce()
        // 并行测试下其他用例会同时构造控制器（进程级计数器）：
        // 只断言严格递增，不断言恰好 +1。
        #expect(second.snapshot().sessionEpoch > epoch)
    }
}
