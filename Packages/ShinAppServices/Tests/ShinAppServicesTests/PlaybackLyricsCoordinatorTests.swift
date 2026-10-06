import Foundation
import Testing
import ShinAppleData
import ShinAppleKit
import ShinLyricsEngine
@testable import ShinAppServices

// 协调器单元测试：播放事件、竞争条件与查询性能。
// 切歌不闪回（身份/epoch 双重丢弃）、组变化去抖（千级快照零多余通知）、
// 暂停冻结/seek 重算/未知时间不猜测/前台 refresh 不累加、
// 偏移调整立即生效并持久化、时间同步路径零写库。
// 全部夹具为原创虚构文本，不使用任何真实歌词。

@Suite("PlaybackLyricsCoordinator")
struct PlaybackLyricsCoordinatorTests {

    // MARK: - 夹具

    /// 线程安全的通知收集器（回调 @Sendable）。
    final class DisplayCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PlaybackLyricsDisplay] = []

        func append(_ value: PlaybackLyricsDisplay) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return values.count
        }

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return values.isEmpty
        }

        var last: PlaybackLyricsDisplay? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }

        var all: [PlaybackLyricsDisplay] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// 计数写入器（记录 (trackKey, delay) 调用）。
    private final class WriterCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(String, Int64)] = []

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }

        func record(_ trackKey: String, _ delay: Int64) {
            lock.lock()
            defer { lock.unlock() }
            calls.append((trackKey, delay))
        }
    }

    /// 构造打轴文档：starts 与"同步测试第 N 行"一一对应（原创文本）。
    private static func document(starts: [Int64], sourceOffsetMs: Int64 = 0) -> LyricDocument {
        LyricDocument(
            sourceFormat: .lrc,
            sourceOffsetMs: sourceOffsetMs,
            originalFilename: "协调器测试.lrc",
            lines: starts.enumerated().map { index, start in
                LyricLine(startMs: start, text: "同步测试第\(index + 1)行")
            }
        )
    }

    static func snapshot(
        track: CatalogIdentity?,
        epoch: Int,
        positionMs: Int64?,
        durationMs: Int64? = 60_000,
        status: PlayerStatus = .playing
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            trackEpoch: epoch,
            track: track,
            title: nil,
            positionMs: positionMs,
            durationMs: durationMs,
            status: status
        )
    }

    static func makeCollector(
        delayWriter: @escaping PlaybackLyricsDelayWriter = { _, _ in }
    ) -> (PlaybackLyricsCoordinator, DisplayCollector) {
        let collector = DisplayCollector()
        let coordinator = PlaybackLyricsCoordinator(
            onDisplayChange: { collector.append($0) },
            delayWriter: delayWriter
        )
        return (coordinator, collector)
    }

    // MARK: 切歌不闪回

    @Test("切歌后旧曲目的过期关联结果被丢弃（身份与 epoch 双重校验）")
    func trackSwitchDropsStaleAssociationResults() {
        let (coordinator, collector) = Self.makeCollector()
        let docA = Self.document(starts: [1_000, 2_000])
        let docB = Self.document(starts: [1_500])

        // A 播放中，关联已生效。
        coordinator.update(snapshot: Self.snapshot(
            track: Fixture.trackA, epoch: 1, positionMs: 2_500
        ))
        coordinator.applyLyrics(
             trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: docA, userDelayMs: 0
        )
        #expect(collector.last?.content == .current(lineIds: [docA.lines[1].id]))

        // 切到 B：A 的慢关联结果尚未返回；旧歌词立即失效（不闪回）。
        coordinator.update(snapshot: Self.snapshot(
            track: Fixture.trackB, epoch: 2, positionMs: 2_000
        ))
        #expect(collector.last?.content == .idle)
        let notificationsAfterSwitch = collector.count

        // 身份过期：A 的结果迟到 → 丢弃。
        coordinator.applyLyrics(
             trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 2, document: docA, userDelayMs: 0
        )
        #expect(collector.last?.content == .idle)

        // epoch 过期：B 的旧 epoch 结果迟到 → 丢弃。
        coordinator.applyLyrics(
             trackKey: SongBinding.trackKey(for: Fixture.trackB), trackEpoch: 1, document: docB, userDelayMs: 0
        )
        #expect(collector.last?.content == .idle)

        // 正确结果到达 → B 生效；切歌之后从未再出现 A 的任何行（不闪回）。
        coordinator.applyLyrics(
             trackKey: SongBinding.trackKey(for: Fixture.trackB), trackEpoch: 2, document: docB, userDelayMs: 0
        )
        #expect(collector.last?.content == .current(lineIds: [docB.lines[0].id]))
        let bLineIds = Set(docB.lines.map(\.id))
        for display in collector.all.dropFirst(notificationsAfterSwitch)
        where display.content.isCurrent {
            let ids = display.currentLineIds ?? []
            #expect(ids.allSatisfy { bLineIds.contains($0) })
        }
    }

    @Test("曲目重新装载（同身份、新 epoch）后旧结果同样被丢弃")
    func sameTrackNewEpochDropsStaleResult() {
        let (coordinator, collector) = Self.makeCollector()
        let doc = Self.document(starts: [1_000])

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 1_500))
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)
        #expect(collector.last?.content == .current(lineIds: [doc.lines[0].id]))

        // 用户重新点播同一首：epoch 递增 → 旧装载失效，等新关联。
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 2, positionMs: 0))
        #expect(collector.last?.content == .idle)
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)
        #expect(collector.last?.content == .idle)
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 2, document: doc, userDelayMs: 0)
        // position 0 在首组之前 → 无当前行（不是闪回，是正确重算）。
        #expect(collector.last?.content == .noCurrentLine)
    }

    // MARK: 组变化去抖

    @Test("同组内 1,000 个快照只按组变化次数通知（同步零写库）")
    func thousandSnapshotsNotifyOnlyOnGroupChange() {
        let counter = WriterCounter()
        let (coordinator, collector) = Self.makeCollector(delayWriter: { track, delay in
            counter.record(track, delay)
        })
        let doc = Self.document(starts: [1_000, 2_000, 5_000])

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 0))
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)
        let baseline = collector.count
        #expect(collector.last?.content == .noCurrentLine)

        // 位置 0→9,990，步进 10：恰好 1,000 个快照，穿过 3 个时间组。
        var position: Int64 = 0
        for _ in 0..<1_000 {
            coordinator.update(snapshot: Self.snapshot(
                track: Fixture.trackA, epoch: 1, positionMs: position
            ))
            position += 10
        }
        // 新增通知 = 组变化次数：进入 1,000 / 2,000 / 5,000 三组。
        #expect(collector.count - baseline == 3)
        #expect(collector.last?.content == .current(lineIds: [
            doc.lines[2].id
        ]))
        // 时间同步绝不写库：整个同步会话写入器零调用。
        #expect(counter.callCount == 0)
    }

    // MARK: 暂停 / 未知时间 / seek / refresh

    @Test("暂停冻结当前行不猜进；positionMs=nil 无当前行不猜测")
    func pausedFreezesAndNilPositionShowsNoLine() {
        let (coordinator, collector) = Self.makeCollector()
        let doc = Self.document(starts: [1_000, 2_000])

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 1_200))
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)
        #expect(collector.last?.content == .current(lineIds: [doc.lines[0].id]))

        // 暂停后同位置反复采样：同组零通知（冻结，不猜进）。
        let frozen = collector.count
        for _ in 0..<10 {
            coordinator.update(snapshot: Self.snapshot(
                track: Fixture.trackA, epoch: 1, positionMs: 1_200, status: .paused
            ))
        }
        #expect(collector.count == frozen)
        #expect(collector.last?.content == .current(lineIds: [doc.lines[0].id]))

        // 未知时间（nil）：无当前行，不猜测。
        coordinator.update(snapshot: Self.snapshot(
            track: Fixture.trackA, epoch: 1, positionMs: nil, status: .paused
        ))
        #expect(collector.last?.content == .noCurrentLine)
    }

    @Test("seek（位置跳变）立即重算：向前与向后")
    func seekRecalculatesImmediately() {
        let (coordinator, collector) = Self.makeCollector()
        let doc = Self.document(starts: [1_000, 2_000, 5_000])

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 1_200))
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)
        #expect(collector.last?.content == .current(lineIds: [doc.lines[0].id]))

        // 向前 seek 到第三组。
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 6_000))
        #expect(collector.last?.content == .current(lineIds: [doc.lines[2].id]))

        // 向后 seek 回首组之前。
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 300))
        #expect(collector.last?.content == .noCurrentLine)

        // seek 到中间组。
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 2_100))
        #expect(collector.last?.content == .current(lineIds: [doc.lines[1].id]))
    }

    @Test("前台 refresh 重算且不累加：暂停态反复 refresh 显示不变")
    func foregroundRefreshDoesNotDrift() {
        let (coordinator, collector) = Self.makeCollector()
        let doc = Self.document(starts: [1_000])

        coordinator.update(snapshot: Self.snapshot(
            track: Fixture.trackA, epoch: 1, positionMs: 1_500, status: .paused
        ))
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)
        let expected = collector.last
        #expect(expected?.content == .current(lineIds: [doc.lines[0].id]))

        // 模拟反复回到前台：无计时器可累加，显示保持权威快照位置。
        for _ in 0..<5 {
            coordinator.refresh()
        }
        #expect(collector.count == 1) // 仅「应用歌词」产生过一次通知，refresh 零新通知
        #expect(collector.last == expected)
    }

    // MARK: 偏移调整

    @Test("正延迟延后、负延迟提前：立即按新偏移重算当前组")
    func setDelayChangesCurrentGroupImmediately() async {
        let (coordinator, collector) = Self.makeCollector()
        let doc = Self.document(starts: [1_000, 2_000])

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 2_100))
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)
        #expect(collector.last?.content == .current(lineIds: [doc.lines[1].id]))

        // +500ms：第二组有效起点变 2,500 → 位置 2,100 退回第一组（延后生效）。
        await coordinator.setDelay(500).value
        #expect(collector.last?.userDelayMs == 500)
        #expect(collector.last?.content == .current(lineIds: [doc.lines[0].id]))

        // -500ms：第二组提前到 1,500 → 位置 2,100 回到第二组（提前生效）。
        await coordinator.setDelay(-500).value
        #expect(collector.last?.userDelayMs == -500)
        #expect(collector.last?.content == .current(lineIds: [doc.lines[1].id]))

        // 连续调整不累计：回到 0 后恢复原始判定（无烘焙）。
        await coordinator.setDelay(0).value
        #expect(collector.last?.userDelayMs == 0)
        #expect(collector.last?.content == .current(lineIds: [doc.lines[1].id]))
    }

    @Test("偏移持久化：新 store 连接读回延迟，索引重建后当前行符合新偏移")
    func setDelayPersistsAndSurvivesReopen() async throws {
        let env = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(env.directory) }

        let doc = Self.document(starts: [1_000, 2_000])
        try await env.store.save(
            document: doc,
            binding: SongBinding(track: Fixture.trackA, lyricDocumentId: doc.id, userDelayMs: 0)
        )

        let collector = DisplayCollector()
        let coordinator = PlaybackLyricsCoordinator(
            onDisplayChange: { collector.append($0) },
            delayWriter: PlaybackLyricsCoordinator.standardDelayWriter(store: env.store)
        )
        coordinator.update(snapshot: Self.snapshot(
            track: Fixture.trackA, epoch: 1, positionMs: 2_100
        ))
        coordinator.applyLyrics(
             trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc,
            userDelayMs: try await env.store.binding(for: Fixture.trackA)?.userDelayMs ?? -1
        )
        #expect(collector.last?.content == .current(lineIds: [doc.lines[1].id]))

        // 延后 0.5 秒：有效起点 1,500/2,500 → 位置 2,100 停在第一组。
        await coordinator.setDelay(500).value
        #expect(collector.last?.content == .current(lineIds: [doc.lines[0].id]))

        // 模拟刷新：重新打开同一数据库连接读回绑定。
        let reopened = try GRDBLyricsStore(
            path: env.directory.appendingPathComponent("lyrics.sqlite").path
        )
        let persisted = try await reopened.binding(for: Fixture.trackA)
        #expect(persisted?.userDelayMs == 500)

        // 用持久化值重建索引：当前行符合新偏移。
        let rebuilt = LyricsTimelineIndex(document: doc, userDelayMs: persisted?.userDelayMs ?? 0)
        if case let .current(lines) = rebuilt.query(playbackMs: 2_100, durationMs: 60_000) {
            #expect(lines.map(\.id) == [doc.lines[0].id])
        } else {
            Issue.record("重建索引后应有当前行")
        }
    }

    @Test("无曲目身份时 setDelay 不触发持久化写入")
    func setDelayWithoutTrackSkipsPersist() async {
        let counter = WriterCounter()
        let (coordinator, _) = Self.makeCollector(delayWriter: { track, delay in
            counter.record(track, delay)
        })
        await coordinator.setDelay(300).value
        #expect(counter.callCount == 0)
        #expect(coordinator.currentDisplay().userDelayMs == 300)
    }

    @Test("持久化失败经 onDelayPersistError 报告且不影响内存生效")
    func setDelayPersistErrorIsReported() async {
        final class ErrorBox: @unchecked Sendable {
            var value: Error?
        }
        let box = ErrorBox()
        let coordinator = PlaybackLyricsCoordinator(
            onDisplayChange: { _ in },
            onDelayPersistError: { box.value = $0 },
            delayWriter: { _, _ in throw ShinAppleDataError.invalidBinding("注入失败") }
        )
        // 先建立曲目身份（无身份时持久化被正确跳过，见专用测试）。
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 0))
        await coordinator.setDelay(200).value
        #expect(box.value != nil)
        #expect(coordinator.currentDisplay().userDelayMs == 200)
    }

    // MARK: 点击行跳转

    @Test("点击行反算播放位置：按偏移公式反算并按 [0,duration] 裁剪")
    func seekPositionClampsToDurationAndZero() {
        let (coordinator, _) = Self.makeCollector()
        // 文件 offset 2,000ms（正值=原文件歌词提前）：行 1,000 → 有效起点 -1,000。
        let doc = Self.document(starts: [1_000, 8_000], sourceOffsetMs: 2_000)

        coordinator.update(snapshot: Self.snapshot(
            track: Fixture.trackA, epoch: 1, positionMs: 0, durationMs: 5_000
        ))
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)

        // 负有效起点裁到 0。
        #expect(coordinator.seekPositionMs(forLineId: doc.lines[0].id) == 0)
        // 超出时长的行裁到 duration。
        #expect(coordinator.seekPositionMs(forLineId: doc.lines[1].id) == 5_000)
        // 未知行 id → nil。
        #expect(coordinator.seekPositionMs(forLineId: UUID()) == nil)
    }

    @Test("未装载歌词时点击行返回 nil")
    func seekPositionWithoutLyricsIsNil() {
        let (coordinator, _) = Self.makeCollector()
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 0))
        #expect(coordinator.seekPositionMs(forLineId: UUID()) == nil)
    }

    // MARK: 空态归一

    @Test("全部未打轴的文档视为无同步内容（idle）；解除关联清空显示")
    func untimedDocumentAndUnbindNormalizeToIdle() {
        let (coordinator, collector) = Self.makeCollector()
        let untimed = LyricDocument(
            sourceFormat: .text,
            lines: [
                LyricLine(startMs: nil, text: "纯文本第一行测试"),
                LyricLine(startMs: nil, text: "纯文本第二行测试")
            ]
        )

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 5_000))
        // 初始即为 idle（与 lastNotified 初值相同）：无变化 → 零通知。
        #expect(collector.isEmpty)
        #expect(coordinator.currentDisplay().content == .idle)
        coordinator.applyLyrics(
             trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: untimed, userDelayMs: 120
        )
        // 全未打轴归一为 idle：显示无变化 → 零通知，延迟也不外露。
        #expect(collector.isEmpty)
        #expect(coordinator.currentDisplay().content == .idle)
        #expect(coordinator.currentDisplay().userDelayMs == 0)

        // 解除关联（宿主传 nil）→ 仍为 idle。
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: nil, userDelayMs: 0)
        #expect(coordinator.currentDisplay().content == .idle)

        // 之后装载有效歌词 → 正常产生通知（确认面板能看到状态机切换）。
        let timed = Self.document(starts: [1_000])
        coordinator.applyLyrics(
             trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: timed, userDelayMs: 0
        )
        #expect(collector.last?.content == .current(lineIds: [timed.lines[0].id]))
    }

    @Test("清屏边界以独立内容呈现且不同边界互不吞并")
    func clearBoundariesAreDistinguished() {
        let (coordinator, collector) = Self.makeCollector()
        let doc = LyricDocument(
            sourceFormat: .lrc,
            lines: [
                LyricLine(startMs: 1_000, text: "同步测试第一行"),
                LyricLine(startMs: 3_000, text: "   "),
                LyricLine(startMs: 4_000, text: "   ")
            ]
        )

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 3_500))
        coordinator.applyLyrics(trackKey: SongBinding.trackKey(for: Fixture.trackA), trackEpoch: 1, document: doc, userDelayMs: 0)
        #expect(collector.last?.content == .cleared(startMs: 3_000))

        // 进入第二个清屏组：startMs 不同 → 产生一次新通知（不吞并）。
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 4_500))
        #expect(collector.last?.content == .cleared(startMs: 4_000))

        // 同一清屏组内多次采样 → 零新通知。
        let frozen = collector.count
        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackA, epoch: 1, positionMs: 4_800))
        #expect(collector.count == frozen)
    }
}

extension PlaybackLyricsDisplay.Content {
    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }
}
