import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 自动获取状态存储与 diff 纯逻辑单测。

@Suite("AutoFetchStore")
struct AutoFetchStoreTests {

    @Test("diff：无快照（首次监控）不产生增删——首次只建立基准")
    func diffWithoutPreviousIsNeutral() {
        let diff = PlaylistMembershipDiffer.diff(previous: nil, current: ["a", "b"])
        #expect(diff.isEmpty)
    }

    @Test("diff：新增与移出都算出")
    func diffDetectsBothDirections() {
        let diff = PlaylistMembershipDiffer.diff(
            previous: ["a", "b", "c"],
            current: ["b", "d"]
        )
        #expect(diff.added == ["d"])
        #expect(diff.removed == ["a", "c"])
    }

    @Test("设置：保存与读回一致；playlistIDs 空数组也持久化")
    func settingsRoundTrip() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let repo = AutoFetchStore(store: store)

        var settings = await repo.loadSettings()
        #expect(!settings.isEnabled)
        #expect(settings.playlistIDs.isEmpty)

        settings.isEnabled = true
        settings.playlistIDs = ["pl-1", "pl-2"]
        try await repo.saveSettings(settings)

        let reread = await repo.loadSettings()
        #expect(reread.isEnabled)
        #expect(reread.playlistIDs == ["pl-1", "pl-2"])

        // 清空歌单也持久化（不是「键缺失时的默认」）。
        var cleared = reread
        cleared.playlistIDs = []
        try await repo.saveSettings(cleared)
        let afterClear = await repo.loadSettings()
        #expect(afterClear.playlistIDs.isEmpty)
    }

    @Test("快照：读写与移除")
    func snapshotRoundTrip() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let repo = AutoFetchStore(store: store)

        #expect(await repo.snapshot(playlistID: "pl-1") == nil)
        let snapshot = PlaylistMembershipSnapshot(
            playlistID: "pl-1",
            playlistName: "喜爱歌曲",
            memberTrackKeys: ["k-1", "k-2"]
        )
        try await repo.saveSnapshot(snapshot)
        let reread = await repo.snapshot(playlistID: "pl-1")
        #expect(reread == snapshot)

        await repo.removeSnapshot(playlistID: "pl-1")
        #expect(await repo.snapshot(playlistID: "pl-1") == nil)
    }

    @Test("失效观察不能同时丢失待办并推进快照")
    func invalidSnapshotCommitKeepsOldDifferences() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let repo = AutoFetchStore(store: store)
        let old = PlaylistMembershipSnapshot(playlistID: "pl-1", playlistName: "虚构歌单", memberTrackKeys: ["k-1"])
        try await repo.saveSnapshot(old)
        let next = PlaylistMembershipSnapshot(playlistID: "pl-1", playlistName: "虚构歌单", memberTrackKeys: ["k-1", "k-2"])
        let other = PlaylistMembershipSnapshot(playlistID: "pl-2", playlistName: nil, memberTrackKeys: ["k-3"])
        let work = AutoFetchWorkItem(kind: .fetch, trackKey: "k-2", playlistIDs: ["pl-1"])
        await #expect(throws: CancellationError.self) {
            try await repo.recordObservations([next, other], work: [work], activePlaylistIDs: ["pl-1", "pl-2"],
                                              isValid: { false })
        }
        #expect(await repo.snapshot(playlistID: "pl-1") == old)
        #expect(await repo.snapshot(playlistID: "pl-2") == nil)
        let remaining = PlaylistMembershipDiffer.diff(previous: old.memberTrackKeys, current: next.memberTrackKeys)
        #expect(remaining.added == ["k-2"])
        try await repo.recordObservations([next, other], work: [work], activePlaylistIDs: ["pl-1", "pl-2"],
                                          isValid: { true })
        #expect(try await repo.workItems() == [work])
        #expect(await repo.snapshot(playlistID: "pl-1") == next)
        #expect(await repo.snapshot(playlistID: "pl-2") == other)
    }

    @Test("部分成功后观察移出，重建仓库仍保留删除与失败获取待办")
    func partialSuccessThenRemovalSurvivesRestart() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let repo = AutoFetchStore(store: store)
        let fetchA = AutoFetchWorkItem(kind: .fetch, trackKey: "k-a", playlistIDs: ["pl-1"])
        let fetchB = AutoFetchWorkItem(kind: .fetch, trackKey: "k-b", playlistIDs: ["pl-1"])
        let removeA = AutoFetchWorkItem(kind: .remove, trackKey: "k-a", playlistIDs: ["pl-1"])
        func snapshot(_ keys: [String]) -> PlaylistMembershipSnapshot {
            PlaylistMembershipSnapshot(playlistID: "pl-1", playlistName: "虚构歌单", memberTrackKeys: keys)
        }
        try await repo.saveSnapshot(snapshot([]))
        try await repo.recordObservations([snapshot(["k-a", "k-b"])], work: [fetchA, fetchB],
                                          activePlaylistIDs: ["pl-1"], isValid: { true })
        try await repo.completeWork(fetchA, isValid: { true })
        // B 获取失败不确认出队；新观察依旧记录 A 的移出。
        try await repo.recordObservations([snapshot(["k-b"])], work: [removeA],
                                          activePlaylistIDs: ["pl-1"], isValid: { true })
        let restarted = AutoFetchStore(store: store)
        #expect(Set(try await restarted.workItems().map(\.id)) == Set([fetchB.id, removeA.id]))
        #expect(await restarted.snapshot(playlistID: "pl-1")?.memberTrackKeys == ["k-b"])
        try await restarted.completeWork(removeA, isValid: { true })
        try await restarted.completeWork(fetchB, isValid: { true })
        #expect(try await restarted.workItems().isEmpty)
    }

    @Test("成功后确认中断，待办不会丢失；同曲目的新移出也单独保留")
    func interruptedAcknowledgmentRetainsWork() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let repo = AutoFetchStore(store: store)
        let fetch = AutoFetchWorkItem(kind: .fetch, trackKey: "k-a", playlistIDs: ["pl-1"])
        let remove = AutoFetchWorkItem(kind: .remove, trackKey: "k-a", playlistIDs: ["pl-1"])
        let old = PlaylistMembershipSnapshot(playlistID: "pl-1", playlistName: nil, memberTrackKeys: ["k-a"])
        try await repo.recordObservations([old], work: [fetch], activePlaylistIDs: ["pl-1"], isValid: { true })
        await #expect(throws: CancellationError.self) {
            try await repo.completeWork(fetch, isValid: { false })
        }
        let next = PlaylistMembershipSnapshot(playlistID: "pl-1", playlistName: nil, memberTrackKeys: [])
        try await repo.recordObservations([next], work: [remove], activePlaylistIDs: ["pl-1"], isValid: { true })
        let items = try await AutoFetchStore(store: store).workItems()
        #expect(Set(items.map(\.id)) == Set([fetch.id, remove.id]))
    }

    @Test("取消监控只移除该歌单来源的待办；其他歌单和已获取文档保留")
    func uncheckingPlaylistPrunesOnlyItsWork() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let repo = AutoFetchStore(store: store)
        let document = try await Fixture.seedOldDocument(in: store)
        let own = AutoFetchWorkItem(kind: .remove, trackKey: "k-a", playlistIDs: ["pl-1"])
        let shared = AutoFetchWorkItem(kind: .fetch, trackKey: "k-b", playlistIDs: ["pl-1", "pl-2"])
        let snapshot = PlaylistMembershipSnapshot(playlistID: "pl-1", playlistName: nil, memberTrackKeys: [])
        try await repo.recordObservations([snapshot], work: [own, shared],
                                          activePlaylistIDs: ["pl-1", "pl-2"], isValid: { true })
        try await repo.saveSettings(AutoFetchSettings(isEnabled: true, playlistIDs: ["pl-2"]))
        await repo.removeSnapshot(playlistID: "pl-1")
        #expect(await repo.snapshot(playlistID: "pl-1") == nil)
        let remaining = try await repo.workItems()
        #expect(remaining.count == 1)
        #expect(remaining.first?.trackKey == "k-b")
        #expect(remaining.first?.playlistIDs == ["pl-2"])
        #expect(try await store.document(id: document.id) == document)
    }

    @Test("待确认队列：同 trackKey 去重、容量淘汰最旧")
    func pendingDedupAndCapacity() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let repo = AutoFetchStore(store: store)

        func item(_ key: String, at: String) -> PendingAutoFetchItem {
            PendingAutoFetchItem(
                trackKey: key, title: "测试\(key)", artist: nil,
                topCandidateTitle: "候选\(key)", topCandidateArtist: nil, enqueuedAt: at
            )
        }

        // 同 trackKey 重复入队只保留最新。
        try await repo.enqueuePending(item("k-1", at: "2026-01-01T00:00:00Z"))
        try await repo.enqueuePending(item("k-1", at: "2026-01-02T00:00:00Z"))
        var pending = await repo.pendingItems()
        #expect(pending.count == 1)
        #expect(pending.first?.enqueuedAt == "2026-01-02T00:00:00Z")

        // 超容量：最旧的被淘汰。
        for index in 0..<AutoFetchStore.pendingCapacity {
            try await repo.enqueuePending(
                item("k-bulk-\(index)", at: "2026-01-01T00:00:0\(index % 10)Z")
            )
        }
        pending = await repo.pendingItems()
        #expect(pending.count == AutoFetchStore.pendingCapacity)
        // k-1（最早）已被淘汰；bulk 序列仍在。
        #expect(!pending.contains { $0.trackKey == "k-1" })
        #expect(pending.contains { $0.trackKey == "k-bulk-0" })

        try await repo.removePending(trackKey: "k-bulk-5")
        pending = await repo.pendingItems()
        #expect(!pending.contains { $0.trackKey == "k-bulk-5" })
    }

    @Test("忽略清单与审计：追加、去重、容量")
    func ignoredAndAudit() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let repo = AutoFetchStore(store: store)

        try await repo.ignore(trackKey: "k-1")
        try await repo.ignore(trackKey: "k-1")   // 幂等
        let ignored = await repo.ignoredTrackKeys()
        #expect(ignored == ["k-1"])

        await repo.appendAudit(AutoFetchAuditEntry(
            action: .imported, trackKey: "k-2", title: "自动获取测试曲", detail: "高置信落位"
        ))
        await repo.appendAudit(AutoFetchAuditEntry(
            action: .deleted, trackKey: "k-3", title: "自动删除测试曲", detail: "移出歌单且未编辑"
        ))
        let audit = await repo.auditEntries()
        #expect(audit.count == 2)
        #expect(audit.first?.action == .deleted)   // 最近在前
    }
}
