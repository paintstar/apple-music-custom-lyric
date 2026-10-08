import Testing
import Foundation
import ShinAppleKit
@testable import ShinMusicScript

// MARK: - 控制命令分发测试（命令发出后读回确认；失败映射 domain 错误）

struct ControlCommandTests {

    private func makeController(
        _ executor: FakeMusicScriptExecutor,
        locator: FakeMusicScriptExecutor? = nil
    ) -> MusicScriptPlaybackController {
        MusicScriptPlaybackController(
            executor: executor,
            libraryLocator: locator,
            samplingIntervalMs: 60_000,
            startsSampler: false
        )
    }

    @Test("play/pause/next/previous：命令分发 + 立即读回（readSnapshot 再执行一次）")
    func commandsDispatchAndRefresh() async throws {
        // seek 用的基线（含时长）
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot()
        ])
        let controller = makeController(executor)
        controller.refreshOnce()
        let readsAfterSetup = executor.recordedReadCount

        try await controller.play()
        #expect(executor.recordedCommands.contains("play"))
        #expect(executor.recordedReadCount == readsAfterSetup + 1)

        try await controller.pause()
        #expect(executor.recordedCommands.contains("pause"))
        try await controller.next()
        #expect(executor.recordedCommands.contains("nextTrack"))
        try await controller.previous()
        #expect(executor.recordedCommands.contains("previousTrack"))
    }

    @Test("seek：毫秒→秒在边界换算；越界裁剪到 [0, duration]；seek 后立即读回")
    func seekClampsAndRefreshes() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()])
        let controller = makeController(executor)
        controller.refreshOnce() // durationMs = 123871

        try await controller.seek(positionMs: 500_000)
        #expect(executor.recordedSeekValues == [123.871])
        try await controller.seek(positionMs: -5)
        #expect(executor.recordedSeekValues.last == 0)
        try await controller.seek(positionMs: 61_500)
        #expect(executor.recordedSeekValues.last == 61.5)
        #expect(executor.recordedCommands.contains("seek"))
    }

    @Test("时长未知时 seek：只保底非负，不猜测上限")
    func seekWithoutKnownDuration() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(duration: nil)
        ])
        let controller = makeController(executor)
        controller.refreshOnce()
        #expect(controller.snapshot().durationMs == nil)

        try await controller.seek(positionMs: 90_000)
        #expect(executor.recordedSeekValues == [90.0])
    }

    @Test("命令失败映射：Music 未运行 → musicNotRunning；权限拒绝 → unauthorized")
    func commandFailureMapping() async throws {
        let executor = FakeMusicScriptExecutor()
        let controller = makeController(executor)
        executor.failCommand("play", with: .musicNotRunning)
        await #expect(throws: PlaybackError.musicNotRunning) {
            try await controller.play()
        }
        executor.failCommand("play", with: .permissionDenied)
        await #expect(throws: PlaybackError.unauthorized) {
            try await controller.play()
        }
        executor.failCommand("nextTrack", with: .permissionDenied)
        await #expect(throws: PlaybackError.unauthorized) { try await controller.next() }
        executor.failCommand("previousTrack", with: .timeout)
        await #expect(throws: PlaybackError.unknown("music:timeout")) { try await controller.previous() }
    }

    @Test("dispose 后切歌任务取消，执行器和采样不得继续调用")
    func disposedTransportDoesNotExecute() async {
        let executor = FakeMusicScriptExecutor()
        let controller = makeController(executor)
        controller.dispose()
        await #expect(throws: CancellationError.self) { try await controller.next() }
        await #expect(throws: CancellationError.self) { try await controller.previous() }
        #expect(executor.recordedCommands.isEmpty)
        #expect(executor.recordedReadCount == 0)
    }

    @Test("setQueue(catalog)：脚本适配器如实拒绝（目录 ID 不是 persistent ID）")
    func setQueueUnsupported() async {
        let controller = makeController(FakeMusicScriptExecutor())
        let identity = CatalogIdentity(storefront: "cn", catalogSongId: "1")
        do {
            _ = try await controller.setQueue([identity], startAt: identity)
            Issue.record("setQueue 应抛错")
        } catch let error as PlaybackError {
            guard case .unknown(let detail) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(detail.contains("setQueueUnsupported"))
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test("playTrackRef：合法 persistent ID 交给点播执行器；随后读回一次")
    func playTrackRefDispatches() async throws {
        let executor = FakeMusicScriptExecutor()
        let locator = FakeMusicScriptExecutor()
        let controller = makeController(executor, locator: locator)
        try await controller.playTrackRef(Fixtures.refA)
        #expect(locator.recordedPlayedPersistentIDs == [Fixtures.pidA])
        #expect(executor.recordedPlayedPersistentIDs.isEmpty) // 主执行器不承担点播
        #expect(locator.recordedReadCount == 0) // 读回走主执行器
        #expect(executor.recordedReadCount >= 1)
    }

    @Test("playTrackRef：命名空间/白名单不符或定位不到 → trackUnavailable")
    func playTrackRefRejections() async {
        let locator = FakeMusicScriptExecutor()
        let controller = makeController(FakeMusicScriptExecutor(), locator: locator)
        await #expect(throws: PlaybackError.trackUnavailable) {
            try await controller.playTrackRef("apple-music:catalog:us:1")
        }
        await #expect(throws: PlaybackError.trackUnavailable) {
            try await controller.playTrackRef("music-script:persistent:NO$T")
        }
        locator.failCommand("playPersistentID", with: .trackNotFound)
        await #expect(throws: PlaybackError.trackUnavailable) {
            try await controller.playTrackRef(Fixtures.refA)
        }
        #expect(locator.recordedPlayedPersistentIDs == [Fixtures.pidA]) // 仅第三次到达执行器
    }

    @Test("Mock 点播契约：未知 trackRef 如实抛 trackUnavailable")
    func mockUnknownTrackRefUnavailable() async {
        let mock = MockPlaybackController()
        await #expect(throws: PlaybackError.trackUnavailable) {
            try await mock.playTrackRef(Fixtures.refA)
        }
    }
}

// MARK: - dispose 与订阅生命周期（重复挂载/清理无累积）

struct DisposeAndSubscriptionTests {

    @Test("订阅可取消且幂等；取消后不再收到通知")
    func subscriptionCancel() {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(),
            Fixtures.snapshot(pid: Fixtures.pidB, title: "测试曲目丙")
        ])
        let controller = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 60_000, startsSampler: false
        )
        let counter = NotificationCounter()
        let handle = controller.subscribe { snapshot in counter.record(snapshot) }
        controller.refreshOnce()
        #expect(counter.notificationCount == 1)
        handle.cancel()
        handle.cancel() // 幂等
        controller.refreshOnce()
        #expect(counter.notificationCount == 1)
    }

    @Test("20 次挂载/清理循环：监听器无累积（刷新后通知数为 0）")
    func repeatedMountUnmountNoLeak() {
        let executor = FakeMusicScriptExecutor(outcomes: Array(
            repeating: Fixtures.snapshot(pid: Fixtures.pidB, title: "测试曲目丙"), count: 1
        ))
        let controller = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 60_000, startsSampler: false
        )
        let counter = NotificationCounter()
        for _ in 0..<20 {
            let handle = controller.subscribe { snapshot in counter.record(snapshot) }
            handle.cancel()
        }
        controller.refreshOnce()
        #expect(counter.notificationCount == 0)
    }

    @Test("dispose：采样停止、订阅清空、refreshOnce 不再产出（返回 false）")
    func disposeStopsEverything() {
        let executor = FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()])
        let controller = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 60_000, startsSampler: false
        )
        let counter = NotificationCounter()
        _ = controller.subscribe { snapshot in counter.record(snapshot) }
        controller.dispose()
        let published = controller.refreshOnce()
        #expect(published == false)
        #expect(counter.notificationCount == 0)
        // 快照读取仍安全（返回最后状态，不再有新采样）。
        _ = controller.snapshot()
    }

    @Test("startsSampler=false：构造后不自动采样")
    func noAutoSamplingWhenDisabled() async {
        let executor = FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()])
        _ = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 1, startsSampler: false
        )
        // 给潜在后台任务留出时间窗；不应有任何读取。
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(executor.recordedReadCount == 0)
    }

    @Test("startsSampler=true：自动采样产出快照")
    func autoSamplingWorks() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()])
        let controller = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 5, startsSampler: true
        )
        // 等待首个自动采样（5ms 间隔，宽松等待避免时序脆弱）。
        for _ in 0..<100 where controller.snapshot().trackRef == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.snapshot().trackRef == Fixtures.refA)
        #expect(executor.recordedReadCount >= 1)
        controller.dispose()
    }
}
