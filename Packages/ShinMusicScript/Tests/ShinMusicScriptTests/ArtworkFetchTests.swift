import AppKit
import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

// 封面读取：控制器执行锁串行化 + 能力缺失如实返回 nil。
// 真实 Music.app 的封面行为属 MANUAL 验证。

/// 带封面能力的假执行器：记录读取次数并按编排返回结果。
/// （FakeMusicScriptExecutor 为 final：本类型独立实现 MusicScriptExecutor。）
private final class FakeArtworkExecutor: MusicScriptExecutor, MusicArtworkProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [MusicSnapshotOutcome]
    private var readCount = 0
    private let artworkLock = NSLock()
    private var artworkResult: MusicArtworkResult?
    private var artworkReadCount = 0

    init(outcomes: [MusicSnapshotOutcome], artwork: MusicArtworkResult?) {
        queue = outcomes
        artworkResult = artwork
    }

    func setArtwork(_ artwork: MusicArtworkResult?) {
        artworkLock.lock()
        defer { artworkLock.unlock() }
        artworkResult = artwork
    }

    var recordedArtworkReadCount: Int {
        artworkLock.lock()
        defer { artworkLock.unlock() }
        return artworkReadCount
    }

    func readCurrentTrackArtwork() -> MusicArtworkResult? {
        artworkLock.lock()
        defer { artworkLock.unlock() }
        artworkReadCount += 1
        return artworkResult
    }

    // MARK: MusicScriptExecutor（最小实现）
    func readSnapshot() -> MusicSnapshotOutcome {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        guard !queue.isEmpty else { return .failed(.unknown("测试队列已空")) }
        return queue.removeFirst()
    }

    func play() throws {}
    func pause() throws {}
    func nextTrack() throws {}
    func previousTrack() throws {}
    func seek(toSeconds seconds: Double) throws {}
    func playPersistentID(_ persistentID: String) throws {}

    var recordedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }
}

/// 测试图像（原创纯色，不含任何真实素材）。
private func makeTestImage() -> NSImage {
    let size = NSSize(width: 8, height: 8)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return image
}

struct ArtworkFetchTests {

    @Test("执行器具备封面能力：控制器返回同批结果并在执行锁内读取")
    func fetchReturnsResult() async {
        let artwork = MusicArtworkResult(persistentID: Fixtures.pidA, image: makeTestImage())
        let executor = FakeArtworkExecutor(outcomes: [Fixtures.snapshot()], artwork: artwork)
        let controller = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 60_000, startsSampler: false
        )
        defer { controller.dispose() }

        let fetched = controller.fetchCurrentTrackArtwork()
        #expect(fetched?.persistentID == Fixtures.pidA)
        #expect(fetched?.image.size.width == 8)
        #expect(executor.recordedArtworkReadCount == 1)
    }

    @Test("执行器无封面能力（Mock/AppleScript 兜底）：如实返回 nil")
    func fetchWithoutCapabilityReturnsNil() {
        let executor = FakeMusicScriptExecutor(outcomes: [Fixtures.snapshot()])
        let controller = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 60_000, startsSampler: false
        )
        defer { controller.dispose() }

        #expect(controller.fetchCurrentTrackArtwork() == nil)
    }

    @Test("无封面/无曲目（nil 结果）：返回 nil 不抛错")
    func fetchWithNilArtworkReturnsNil() {
        let executor = FakeArtworkExecutor(outcomes: [Fixtures.snapshot()], artwork: nil)
        let controller = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 60_000, startsSampler: false
        )
        defer { controller.dispose() }

        #expect(controller.fetchCurrentTrackArtwork() == nil)
        #expect(executor.recordedArtworkReadCount == 1)
    }

    @Test("封面读取与快照采样并发：两路读取计数之和守恒（执行锁串行化，无崩溃竞态）")
    func fetchSerializesWithSampling() async {
        let artwork = MusicArtworkResult(persistentID: Fixtures.pidB, image: makeTestImage())
        let executor = FakeArtworkExecutor(
            outcomes: (0..<50).map { _ in Fixtures.snapshot() },
            artwork: artwork
        )
        // 启动真实采样循环（60s 间隔内不会自然推进，靠 refreshOnce 驱动）。
        let controller = MusicScriptPlaybackController(
            executor: executor, samplingIntervalMs: 60_000, startsSampler: true
        )
        defer { controller.dispose() }

        let readAtStart = executor.recordedReadCount
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { @Sendable in
                    _ = controller.fetchCurrentTrackArtwork()
                    controller.refreshOnce()
                }
            }
        }
        // 全部封面读取都被记录（串行化下无丢失、无崩溃）；快照读取至少
        // 20 次（20 次 refreshOnce 各一次，另有采样循环自身的读取）。
        #expect(executor.recordedArtworkReadCount == 20)
        #expect(executor.recordedReadCount - readAtStart >= 20)
    }
}
