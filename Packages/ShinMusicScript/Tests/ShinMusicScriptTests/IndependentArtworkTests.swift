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
        let first = Task { await musicTestBackground { _ = controller.fetchCurrentTrackArtwork() } }
        try #require(await provider.entered.wait())
        let nextDone = MusicTestSignal()
        let next = Task {
            defer { nextDone.signal() }
            try await controller.next()
        }
        // 不释放图像夹具，切歌仍应发送并完成读回；不靠毫秒性能阈值判断。
        try #require(await nextDone.wait())
        #expect(executor.recordedCommands == ["nextTrack"])
        let oldRequest = ArtworkCancellation()
        let queued = MusicTestSignal()
        let second = Task {
            await musicTestBackground {
                queued.signal()
                _ = controller.fetchCurrentTrackArtwork(shouldCancel: { oldRequest.isCancelled })
            }
        }
        try #require(await queued.wait())
        oldRequest.cancel()
        provider.release.signal()
        await first.value
        await second.value
        try await next.value
        #expect(provider.reads == 1)
    }

    @Test("dispose使排队封面及其迟到结果失效，独立提供器不再读取")
    func disposalSkipsQueuedArtwork() async throws {
        let provider = BlockingArtworkProvider()
        let controller = MusicScriptPlaybackController(executor: FakeMusicScriptExecutor(),
                                                       artworkProvider: provider, startsSampler: false)
        defer { controller.dispose(); provider.release.signal() }
        let first = Task { await musicTestBackground { _ = controller.fetchCurrentTrackArtwork() } }
        try #require(await provider.entered.wait())
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
}

private final class BlockingArtworkProvider: MusicArtworkProviding, @unchecked Sendable {
    let entered = MusicTestSignal()
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
