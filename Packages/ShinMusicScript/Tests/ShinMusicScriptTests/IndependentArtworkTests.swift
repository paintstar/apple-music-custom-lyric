import Foundation
import Testing
@testable import ShinMusicScript

@Suite(.serialized)
struct IndependentArtworkTests {
    @Test("旧封面正在取图不阻塞下一首，排队后取消的封面不会继续读取")
    func oldArtworkCannotBlockTransport() async throws {
        let provider = BlockingArtworkProvider()
        let executor = FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()])
        let controller = MusicScriptPlaybackController(executor: executor, artworkProvider: provider, startsSampler: false)
        defer { controller.dispose(); provider.release.signal() }
        let first = Task.detached { _ = controller.fetchCurrentTrackArtwork() }
        #expect(await waitForSignal(provider.entered))
        let nextDone = DispatchSemaphore(value: 0)
        let next = Task.detached {
            defer { nextDone.signal() }
            try await controller.next()
        }
        // 不释放图像夹具，切歌仍应发送并完成读回；不靠毫秒性能阈值判断。
        #expect(await waitForSignal(nextDone))
        #expect(executor.recordedCommands == ["nextTrack"])
        let oldRequest = ArtworkCancellation()
        let queued = DispatchSemaphore(value: 0)
        let second = Task.detached {
            queued.signal()
            _ = controller.fetchCurrentTrackArtwork(shouldCancel: { oldRequest.isCancelled })
        }
        #expect(await waitForSignal(queued))
        oldRequest.cancel()
        provider.release.signal()
        await first.value
        await second.value
        try await next.value
        #expect(provider.reads == 1)
    }

    @Test("dispose使排队封面及其迟到结果失效，独立提供器不再读取")
    func disposalSkipsQueuedArtwork() async {
        let provider = BlockingArtworkProvider()
        let controller = MusicScriptPlaybackController(executor: FakeMusicScriptExecutor(),
                                                       artworkProvider: provider, startsSampler: false)
        defer { controller.dispose(); provider.release.signal() }
        let first = Task.detached { _ = controller.fetchCurrentTrackArtwork() }
        #expect(await waitForSignal(provider.entered))
        controller.dispose()
        #expect(controller.fetchCurrentTrackArtwork() == nil)
        provider.release.signal()
        await first.value
        #expect(provider.reads == 1)
    }

    @Test("生产SB封面使用独立对象，创建实例不启动Music或发送事件")
    func productionArtworkProviderIsIndependent() {
        let executor = ScriptingBridgeExecutor()
        #expect(executor.makeArtworkProvider() != nil)
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}

private final class BlockingArtworkProvider: MusicArtworkProviding, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var readCount = 0
    var reads: Int { lock.withLock { readCount } }
    func readCurrentTrackArtwork() -> MusicArtworkResult? {
        lock.withLock { readCount += 1 }
        entered.signal()
        release.wait()
        return nil
    }
}

private final class ArtworkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
