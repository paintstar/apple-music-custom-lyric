import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

/// 使用真实周期采样任务，避免手动 refreshOnce 掩盖循环意外退出。
struct SamplingContinuityTests {
    @Test("切歌时丢弃一次混合身份快照，周期采样继续发布后续播放进度")
    func discardedIdentityBatchKeepsSamplerAlive() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(position: 10, pid: Fixtures.pidA),
            .identityChangedDuringRead,
            Fixtures.snapshot(position: 20, pid: Fixtures.pidB)
        ], repeating: Fixtures.snapshot(position: 21, pid: Fixtures.pidB))
        // 缩短真实采样周期只为使回归有界；仍由 startsSampler 默认路径自行推进。
        let controller = MusicScriptPlaybackController(executor: executor, samplingIntervalMs: 20)
        defer { controller.dispose() }
        let published = MusicTestSignal()
        let subscription = controller.subscribe { snapshot in
            if snapshot.trackRef == Fixtures.refB, (snapshot.positionMs ?? 0) >= 21_000 { published.signal() }
        }
        defer { subscription.cancel() }
        // 采样可能先于订阅完成；订阅后同时检查已发布状态，不能错过满足条件的首个通知。
        if controller.snapshot().trackRef == Fixtures.refB, (controller.snapshot().positionMs ?? 0) >= 21_000 {
            published.signal()
        }
        try #require(await published.wait(timeout: .milliseconds(500)))
        #expect(executor.recordedReadCount >= 4)
        #expect(controller.snapshot().trackRef == Fixtures.refB)
        #expect((controller.snapshot().positionMs ?? 0) >= 21_000)
    }
}
