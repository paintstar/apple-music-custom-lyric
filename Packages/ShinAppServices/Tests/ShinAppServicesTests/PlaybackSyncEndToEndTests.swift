import Foundation
import Testing
import ShinAppleData
import ShinAppleKit
@testable import ShinAppServices

// Mock 端到端测试：
// 选择 A → 导入 LRC → 播放/暂停/seek → 调整延迟 → 保存（持久化）→
// 切到 B → 回到 A → 刷新（新连接模拟重启）→ A 的歌词和延迟仍正确。
// 全程使用 ShinAppleKit MockPlaybackController（ManualClock，无真实定时器），
// 快照由测试逐步转发给协调器（等价于 App 的订阅转发路径）；
// 全部夹具为原创虚构文本，不使用任何真实歌词。

@Suite("PlaybackSyncEndToEnd (Mock)")
struct PlaybackSyncEndToEndTests {

    /// 通知收集器（等价于 App 面板对协调器输出的观察）。
    private final class DisplayCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PlaybackLyricsDisplay] = []

        func append(_ value: PlaybackLyricsDisplay) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }

        var last: PlaybackLyricsDisplay? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }
    }

    private static let trackA = CatalogIdentity(storefront: "us", catalogSongId: "9200001")
    private static let trackB = CatalogIdentity(storefront: "us", catalogSongId: "9200002")

    /// E2E 专用 LRC：三组起点 1s / 3.5s / 7s，无文件 offset（原创文本）。
    private static let e2eLrc = """
    [ti:测试曲目甲]
    [ar:测试歌手甲]
    [00:01.000]闭环测试第一句
    [00:03.500]闭环测试第二句
    [00:07.000]闭环测试第三句
    闭环测试未打轴补记
    """

    private static func makeController() -> MockPlaybackController {
        MockPlaybackController(clock: ManualClock())
    }

    private static func makeCoordinator(
        store: GRDBLyricsStore,
        collector: DisplayCollector
    ) -> PlaybackLyricsCoordinator {
        PlaybackLyricsCoordinator(
            onDisplayChange: { collector.append($0) },
            delayWriter: PlaybackLyricsCoordinator.standardDelayWriter(store: store)
        )
    }

    /// 把控制器当前权威快照转发给协调器（等价 AppModel 订阅转发）。
    private func forward(
        _ controller: MockPlaybackController, to coordinator: PlaybackLyricsCoordinator
    ) {
        coordinator.update(snapshot: controller.snapshot())
    }

    /// 导入 E2E LRC（导入会话目标固定为 trackA），返回已保存文档。
    private func importLyrics(into store: GRDBLyricsStore) async throws -> LyricDocument {
        let importService = ImportWorkflowService(store: store)
        try await importService.openImportSession(
            target: ImportSessionTarget(
                track: Self.trackA,
                titleHint: "测试曲目甲",
                artistHint: "测试歌手甲",
                durationHintMs: 60_000
            )
        )
        _ = try await importService.ingest(
            fileData: Data(Self.e2eLrc.utf8),
            filename: "闭环测试.lrc"
        )
        let confirmation = try await importService.confirmImport()
        #expect(confirmation.document.lines.count == 4)
        return confirmation.document
    }

    /// 关联查询并应用到协调器（等价 App 面板刷新后写入协调器的路径）。
    private func applyAssociation(
        from store: GRDBLyricsStore,
        track: CatalogIdentity,
        epoch: Int,
        to coordinator: PlaybackLyricsCoordinator
    ) async throws {
        let association = LyricsAssociationService(store: store)
        guard case let .available(document, binding) = try await association.associationState(for: track) else {
            Issue.record("应为 available 关联状态")
            return
        }
        coordinator.applyLyrics(
            trackKey: SongBinding.trackKey(for: track),
            trackEpoch: epoch, document: document, userDelayMs: binding.userDelayMs
        )
    }

    @Test("Mock 闭环：播放→导入→同步跟随→调延迟→持久化→切歌→回到 A→刷新仍正确")
    func mockEndToEndLoop() async throws {
        let env = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(env.directory) }
        let controller = Self.makeController()
        let collector = DisplayCollector()
        let coordinator = Self.makeCoordinator(store: env.store, collector: collector)

        // 1) 选择 A：装载 [A, B] 队列并从 A 开始播放。
        controller.setMockQueue(
            [
                MockTrack(identity: Self.trackA, title: "测试曲目甲", durationMs: 60_000),
                MockTrack(identity: Self.trackB, title: "测试曲目乙", durationMs: 30_000)
            ],
            startAt: 0
        )
        forward(controller, to: coordinator)
        let epochA1 = controller.snapshot().trackEpoch
        #expect(controller.snapshot().track == Self.trackA)

        // 2) 导入 LRC → 3) 关联生效：位置 0 在首组之前 → 无当前行（不猜测）。
        let document = try await importLyrics(into: env.store)
        try await applyAssociation(from: env.store, track: Self.trackA, epoch: epochA1, to: coordinator)
        #expect(collector.last?.content == .noCurrentLine)

        // 4) 播放推进：第一组高亮跟随。
        controller.advanceTime(byMs: 1_200)
        forward(controller, to: coordinator)
        #expect(collector.last?.content == .current(lineIds: [document.lines[0].id]))

        // 5) 暂停：冻结当前行（重复快照零新通知，不猜进）。
        try await controller.pause()
        let pauseBaseline = collector.last
        forward(controller, to: coordinator)
        forward(controller, to: coordinator)
        #expect(collector.last == pauseBaseline)
        #expect(pauseBaseline?.content == .current(lineIds: [document.lines[0].id]))

        // 6) 恢复播放并推进到第二组；7) 向后 seek 立即重算回第一组。
        try await controller.play()
        controller.advanceTime(byMs: 3_000)
        forward(controller, to: coordinator)
        #expect(collector.last?.content == .current(lineIds: [document.lines[1].id]))
        try await controller.seek(positionMs: 1_100)
        forward(controller, to: coordinator)
        #expect(collector.last?.content == .current(lineIds: [document.lines[0].id]))

        // 8) 点击第三行 → 协调器反算 7,000ms → 宿主执行 seek → 第三组高亮。
        let seekTarget = coordinator.seekPositionMs(forLineId: document.lines[2].id)
        #expect(seekTarget == 7_000)
        try await controller.seek(positionMs: seekTarget ?? 0)
        forward(controller, to: coordinator)
        #expect(collector.last?.content == .current(lineIds: [document.lines[2].id]))

        // 9) 延后 0.5 秒：立即按新偏移重算（第三组有效起点 7,500 未到 → 第二组）。
        await coordinator.setDelay(500).value
        #expect(collector.last?.userDelayMs == 500)
        #expect(collector.last?.content == .current(lineIds: [document.lines[1].id]))

        // 10) 切到 B：B 无关联 → 无同步内容；旧歌词不闪回。
        try await controller.next()
        forward(controller, to: coordinator)
        let epochB = controller.snapshot().trackEpoch
        #expect(controller.snapshot().track == Self.trackB)
        #expect(collector.last?.content == .idle)

        // 11) 回到 A：新连接模拟刷新。先注入「迟到的旧 epoch 结果」→ 必须被丢弃。
        let reopened = try GRDBLyricsStore(
            path: env.directory.appendingPathComponent("lyrics.sqlite").path
        )
        try await controller.previous()
        forward(controller, to: coordinator)
        let epochA2 = controller.snapshot().trackEpoch
        #expect(controller.snapshot().track == Self.trackA)
        #expect(epochA2 > epochB)
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Self.trackA), trackEpoch: epochA1, document: document, userDelayMs: 500)
        #expect(collector.last?.content == .idle)

        // 12) 重新查询 A（关联与延迟仍在）→ 应用 → 推进后第三组正确。
        try await applyAssociation(from: reopened, track: Self.trackA, epoch: epochA2, to: coordinator)
        #expect(collector.last?.userDelayMs == 500)
        #expect(collector.last?.content == .noCurrentLine)
        controller.advanceTime(byMs: 8_000)
        forward(controller, to: coordinator)
        #expect(collector.last?.content == .current(lineIds: [document.lines[2].id]))

        // 13) 前台恢复 refresh：重算不累加，显示保持权威位置。
        coordinator.refresh()
        #expect(collector.last?.content == .current(lineIds: [document.lines[2].id]))

        // 14) 刷新证据：新连接读回绑定/文档；时间同步零写库（revision 未变）。
        try await verifyPersistence(reopened: reopened, document: document)
    }

    /// 刷新后读回验证：绑定延迟保留、文档逐字节一致、revision 未被同步路径改动。
    private func verifyPersistence(reopened: GRDBLyricsStore, document: LyricDocument) async throws {
        let binding = try await reopened.binding(for: Self.trackA)
        #expect(binding?.userDelayMs == 500)
        let persisted = try await reopened.document(id: document.id)
        #expect(persisted == document)
        #expect(persisted?.revision == document.revision)
        if case .available = try await LyricsAssociationService(store: reopened)
            .associationState(for: Self.trackB) {
            Issue.record("B 未导入过歌词，不应有可用关联")
        }
    }
}
