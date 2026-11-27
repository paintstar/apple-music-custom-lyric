import os
import ShinAppleKit
import Testing
@testable import ShinMusicScript

struct VocabularyReadbackTests {
    @Test("第一次读到目标后又返回歌曲开头，只发布随后稳定的例句位置")
    func waitsForStablePositionAfterInitialMatch() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(position: 21), Fixtures.snapshot(position: 42),
            Fixtures.snapshot(position: 0.186), Fixtures.snapshot(position: 42.2), Fixtures.snapshot(position: 42.3)
        ], vocabularyResult: .positionRequested(42_000))
        let controller = MusicScriptPlaybackController(executor: executor, startsSampler: false)
        let received = OSAllocatedUnfairLock(initialState: [PlaybackSnapshot]())
        let subscription = controller.subscribe { snapshot in received.withLock { $0.append(snapshot) } }
        defer { subscription.cancel() }

        controller.refreshOnce()
        #expect(try await controller.playVocabularyExample(trackKey: Fixtures.refA, positionMs: 42_000) == .played)
        for _ in 0..<max(5 - executor.recordedReadCount, 0) { controller.refreshOnce() }
        #expect(received.withLock { $0.compactMap(\.positionMs) } == [21_000, 42_300])
    }

    @Test("确认绑定原曲和会话，跨曲只发布定位已确认的目标快照")
    func confirmsReplacementPosition() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(position: 21),
            Fixtures.snapshot(position: 0, pid: Fixtures.pidB),
            Fixtures.snapshot(position: 8, pid: Fixtures.pidB),
            Fixtures.snapshot(position: 8, pid: Fixtures.pidB)
        ], vocabularyResult: .positionRequested(8_000))
        let controller = MusicScriptPlaybackController(executor: executor, startsSampler: false)
        let received = OSAllocatedUnfairLock(initialState: [PlaybackSnapshot]())
        let subscription = controller.subscribe { snapshot in received.withLock { $0.append(snapshot) } }
        defer { subscription.cancel() }
        controller.refreshOnce()
        let current = controller.snapshot()
        var stale = current
        stale.sessionEpoch -= 1
        #expect(try await controller.playVocabularyExample(
            trackKey: Fixtures.refB, positionMs: 8_000, replacingQueueFor: stale
        ) == .queueProtected)
        #expect(executor.recordedCommands.isEmpty)
        #expect(try await controller.playVocabularyExample(
            trackKey: Fixtures.refB, positionMs: 8_000, replacingQueueFor: current
        ) == .played)
        #expect(executor.recordedCommands == ["vocabularyReplacing:\(Fixtures.pidA)"])
        #expect(controller.snapshot().trackKey == Fixtures.refB)
        #expect(received.withLock { $0.compactMap(\.positionMs) } == [21_000, 8_000])
    }

    @Test("例句先确认目标位置，再滤掉起点读回，普通定位到开头仍生效")
    func suppressesTransientInitPosition() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(position: 21), Fixtures.snapshot(position: 0),
            Fixtures.snapshot(position: 42), Fixtures.snapshot(position: 42),
            .noCurrentTrack(stateCode: MusicScriptPlayerState.playing),
            .snapshot(MusicScriptRawSnapshot(playerStateCode: MusicScriptPlayerState.playing, positionSeconds: 0)),
            Fixtures.snapshot(position: 0.23), Fixtures.snapshot(position: 42.4), Fixtures.snapshot(position: 0),
            Fixtures.snapshot(position: 42), Fixtures.snapshot(position: 42), Fixtures.snapshot(position: 0)
        ], vocabularyResult: .positionRequested(42_000))
        let clock = OSAllocatedUnfairLock(initialState: Int64(1_000))
        let controller = MusicScriptPlaybackController(executor: executor, sampleTime: { clock.withLock { $0 } })
        let received = OSAllocatedUnfairLock(initialState: [PlaybackSnapshot]())
        let subscription = controller.subscribe { snapshot in received.withLock { $0.append(snapshot) } }
        defer { subscription.cancel() }

        controller.refreshOnce()
        #expect(try await controller.playVocabularyExample(trackKey: Fixtures.refA, positionMs: 42_000) == .played)
        #expect(controller.snapshot().positionMs == 42_000)
        let confirmedSeq = controller.snapshot().seq
        for _ in 0..<3 {
            clock.withLock { $0 += 100 }
            controller.refreshOnce()
            #expect(controller.snapshot().seq == confirmedSeq)
            #expect(controller.snapshot().positionMs == 42_000)
        }
        controller.refreshOnce()
        #expect(controller.snapshot().positionMs == 42_400)
        try await controller.seek(positionMs: 0)
        #expect(controller.snapshot().positionMs == 0)
        #expect(try await controller.playVocabularyExample(trackKey: Fixtures.refA, positionMs: 42_000) == .played)
        clock.withLock { $0 += 2_000 }
        controller.refreshOnce()
        #expect(controller.snapshot().positionMs == 0)
        #expect(received.withLock { $0.compactMap(\.positionMs) } == [21_000, 42_000, 42_400, 0, 42_000, 0])
    }

    @Test("例句回读确认后，短暂的停止、暂停归零或曲目消失不会把歌词送回开头")
    func holdsAmbiguousStartupTransitions() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(position: 21), Fixtures.snapshot(position: 42), Fixtures.snapshot(position: 42),
            Fixtures.snapshot(state: MusicScriptPlayerState.paused, position: 0),
            Fixtures.snapshot(state: MusicScriptPlayerState.stopped, position: 0),
            .noCurrentTrack(stateCode: MusicScriptPlayerState.stopped), Fixtures.snapshot(position: 42.4)
        ], vocabularyResult: .positionRequested(42_000))
        let clock = OSAllocatedUnfairLock(initialState: Int64(1_000))
        let controller = MusicScriptPlaybackController(executor: executor, sampleTime: { clock.withLock { $0 } })
        let received = OSAllocatedUnfairLock(initialState: [PlaybackSnapshot]())
        let subscription = controller.subscribe { snapshot in received.withLock { $0.append(snapshot) } }
        defer { subscription.cancel() }

        controller.refreshOnce()
        #expect(try await controller.playVocabularyExample(trackKey: Fixtures.refA, positionMs: 42_000) == .played)
        for _ in 0..<4 { controller.refreshOnce() }
        #expect(received.withLock { $0.map(\.positionMs) } == [21_000, 42_000, 42_400])
        #expect(controller.snapshot().trackKey == Fixtures.refA)
    }

    @Test("向前后退均能过滤跳转前的陈旧位置，真实暂停和切歌及时上报")
    func retainsLegitimateStateChanges() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(position: 91), Fixtures.snapshot(position: 42), Fixtures.snapshot(position: 42),
            Fixtures.snapshot(position: 91.2), Fixtures.snapshot(position: 42.35),
            Fixtures.snapshot(state: MusicScriptPlayerState.paused, position: 42.35),
            Fixtures.snapshot(position: 0, pid: Fixtures.pidB)
        ], vocabularyResult: .positionRequested(42_000))
        let clock = OSAllocatedUnfairLock(initialState: Int64(1_000))
        let controller = MusicScriptPlaybackController(executor: executor, sampleTime: { clock.withLock { $0 } })

        controller.refreshOnce()
        #expect(try await controller.playVocabularyExample(trackKey: Fixtures.refA, positionMs: 42_000) == .played)
        controller.refreshOnce()
        #expect(controller.snapshot().positionMs == 42_000)
        controller.refreshOnce()
        #expect(controller.snapshot().positionMs == 42_350)
        controller.refreshOnce()
        #expect(controller.snapshot().status == .paused)
        #expect(controller.snapshot().positionMs == 42_350)
        controller.refreshOnce()
        #expect(controller.snapshot().trackKey == Fixtures.refB)
        #expect(controller.snapshot().positionMs == 0)
    }

    @Test("读回是另一首时立即结束定位，报告实际曲目")
    func abortsIfTrackChangesBeforeReadback() async throws {
        let executor = FakeMusicScriptExecutor(outcomes: [
            Fixtures.snapshot(position: 21), Fixtures.snapshot(position: 0, pid: Fixtures.pidB)
        ], vocabularyResult: .positionRequested(42_000))
        let clock = OSAllocatedUnfairLock(initialState: Int64(1_000))
        let controller = MusicScriptPlaybackController(executor: executor, sampleTime: { clock.withLock { $0 } })

        controller.refreshOnce()
        #expect(try await controller.playVocabularyExample(trackKey: Fixtures.refA, positionMs: 42_000) == .targetNotReady)
        #expect(controller.snapshot().trackKey == Fixtures.refB)
        #expect(controller.snapshot().positionMs == 0)
        #expect(executor.recordedReadCount == 2)
    }

    @Test("超过暂态保护时间后，开头读回重新按真实位置更新")
    func stabilizationExpires() {
        var readback = MusicVocabularyReadback(trackRef: Fixtures.refA, targetMs: 42_000, previousPositionMs: 21_000)
        readback.confirm(at: 1_000)
        var snapshot = PlaybackSnapshot(
            positionMs: 0, status: .playing, trackRef: Fixtures.refA, sampledAtMonotonicMs: 1_500
        )
        let previous = PlaybackSnapshot(
            positionMs: 42_000, status: .playing, trackRef: Fixtures.refA, sampledAtMonotonicMs: 1_000
        )
        #expect(readback.isActive(for: snapshot) && readback.shouldHold(snapshot, after: previous))
        snapshot.sampledAtMonotonicMs = 4_000
        #expect(!readback.isActive(for: snapshot))
        #expect(!readback.shouldHold(snapshot, after: previous))
    }
}
