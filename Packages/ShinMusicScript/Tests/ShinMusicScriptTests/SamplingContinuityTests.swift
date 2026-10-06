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
            .identityChangedDuringRead
        ] + (0..<64).map { Fixtures.snapshot(position: Double(20 + $0), pid: Fixtures.pidB) })
        // 缩短真实采样周期只为使回归有界；仍由 startsSampler 默认路径自行推进。
        let controller = MusicScriptPlaybackController(executor: executor, samplingIntervalMs: 20)
        defer { controller.dispose() }
        for _ in 0..<50 {
            if executor.recordedReadCount >= 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(executor.recordedReadCount >= 4)
        #expect(controller.snapshot().trackRef == Fixtures.refB)
        #expect((controller.snapshot().positionMs ?? 0) >= 21_000)
    }
}
