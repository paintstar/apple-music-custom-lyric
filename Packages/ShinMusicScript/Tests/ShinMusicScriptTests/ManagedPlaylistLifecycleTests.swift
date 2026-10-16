import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct ManagedPlaylistLifecycleTests {
    @Test("普通点播按首曲旋转，返回完整旋转顺序相同的上下文复用，两个近期清单保留")
    func reusesExactSequence() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        let ids = [Fixtures.pidA, Fixtures.pidB]
        try context.play(ids, startingAt: Fixtures.pidB, in: .library, shuffleEnabled: false) {}
        let original = fixture.currentPlaylistID
        let copies = fixture.appendCount
        let before = fixture.operations.count
        try context.play(ids, startingAt: Fixtures.pidA, in: .library, shuffleEnabled: true) {}
        #expect(fixture.currentPlaylistID != original && fixture.appendCount == copies + 1)
        #expect(fixture.currentIDs == ids && fixture.playedID == Fixtures.pidA && fixture.shuffleEnabled == true)
        #expect(Array(fixture.operations.dropFirst(before)) == ["play-source", "create", "append", "start"])
        try context.play(Array(ids.reversed()), startingAt: Fixtures.pidB, in: .library, shuffleEnabled: false) {}
        #expect(fixture.currentPlaylistID == original && fixture.currentIDs == Array(ids.reversed()))
        #expect(fixture.playlists.count == 2 && fixture.appendCount == copies + 1)
        try context.play(ids, startingAt: Fixtures.pidB, in: .library, shuffleEnabled: false) {}
        #expect(fixture.currentPlaylistID == original && fixture.appendCount == copies + 1)
        #expect(fixture.removedIDs.isEmpty && !fixture.operations.contains("remove"))
        try context.cleanupOnQuit {}
        #expect(fixture.playlists.isEmpty)
    }

    @Test("普通复用拒绝改名、改标记、成员变化、智能清单及已丢失清单，play 已发失败不新建")
    func rejectsChangedReuseAndPreservesPending() throws {
        for change in 0..<6 {
            let fixture = ContextFixture()
            let (defaults, domain) = isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: domain) }
            let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
            try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
            let original = try #require(fixture.currentPlaylistID)
            switch change {
            case 0: fixture.playlists[original]?.name = "原创修改清单"
            case 1: fixture.playlists[original]?.token = UUID()
            case 2: fixture.playlists[original]?.ids = [Fixtures.pidB]
            case 3: fixture.playlists[original]?.isSmart = true
            case 4: fixture.playlists[original]?.ids = []
            default: fixture.playlists.removeValue(forKey: original)
            }
            try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
            #expect(fixture.currentPlaylistID != original && fixture.appendCount == 2)
            if change < 5 { #expect(fixture.playlists[original] != nil) }
            fixture.unconfirmedStartError = MusicPlaybackContextError(stage: .currentPlaylist, appleEventCode: -1712)
            #expect(throws: MusicPlaybackContextError.self) {
                try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
            }
            #expect(fixture.appendCount == 2, "已发送 play 的复用失败不能 fallback 新建")
            #expect(recordCount(defaults) == 2, "未确认的复用请求及原有所有权记录保留到安全清理")
        }
    }

    @Test("管理清单被用户清空后普通和随机都建立新上下文，保留空清单")
    func clearedManagedPlaylistIsNotReusedOrDeleted() throws {
        for shuffle in [false, true] {
            let fixture = ContextFixture()
            let (defaults, domain) = isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: domain) }
            let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
            let ids = [Fixtures.pidA, Fixtures.pidB]
            if shuffle {
                try context.shuffle(ids, in: .library) {}
            } else {
                try context.play(ids, startingAt: ids[0], in: .library, shuffleEnabled: nil) {}
            }
            let original = try #require(fixture.currentPlaylistID)
            fixture.playlists[original]?.ids = []
            if shuffle {
                try context.shuffle(ids, in: .library) {}
            } else {
                try context.play(ids, startingAt: ids[0], in: .library, shuffleEnabled: nil) {}
            }
            #expect(fixture.currentPlaylistID != original && fixture.currentIDs == ids)
            #expect(fixture.playlists[original]?.ids.isEmpty == true && fixture.creationCount == 2)
            try context.cleanupOnQuit {}
            #expect(fixture.playlists[original]?.ids.isEmpty == true)
        }
    }

    @Test("退出停止后清理当前和 pending 清单，释放 pending 必须先确认 stopped")
    func cleansCurrentAndPendingOnlyAfterStop() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
        fixture.unconfirmedStartError = MusicPlaybackContextError(stage: .currentPlaylist, appleEventCode: -1712)
        #expect(throws: MusicPlaybackContextError.self) {
            try context.play([Fixtures.pidB], startingAt: Fixtures.pidB, in: .library, shuffleEnabled: false) {}
        }
        #expect(recordCount(defaults) == 2 && fixture.playlists.count == 2)
        try context.cleanupOnQuit {}
        #expect(fixture.stopCount == 1 && !fixture.isPlaying)
        #expect(fixture.playlists.isEmpty && fixture.removedIDs.count == 2 && recordCount(defaults) == 0)
        try context.cleanupOnQuit {}
        #expect(fixture.stopCount == 1, "无所有权记录时不发送 Music 事件")
    }

    @Test("退出停止失败、超时、未停止或 Music 未运行都不删清单、不释放 pending")
    func stopFailuresKeepRecords() throws {
        for failure in 0..<4 {
            let fixture = ContextFixture()
            let (defaults, domain) = isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: domain) }
            let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
            fixture.unconfirmedStartError = CancellationError()
            #expect(throws: CancellationError.self) {
                try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
            }
            let originalData = defaults.data(forKey: "ShinApple.musicPlaybackContexts")
            switch failure {
            case 0: fixture.stopError = MusicPlaybackContextError(stage: .cleanup, appleEventCode: -1743)
            case 1: fixture.stopError = MusicPlaybackContextError(stage: .cleanup, appleEventCode: -1712)
            case 2: fixture.stopConfirmed = false
            default: fixture.musicRunning = false
            }
            #expect(throws: MusicPlaybackContextError.self) { try context.cleanupOnQuit {} }
            #expect(fixture.removedIDs.isEmpty && fixture.playlists.count == 1)
            #expect(defaults.data(forKey: "ShinApple.musicPlaybackContexts") == originalData)
            if failure == 3 { #expect(fixture.stopCount == 0) }
        }
    }

    @Test("退出仅删除未改动清单，用户改名、描述、成员、智能或文件夹清单均保留")
    func quitKeepsUserChanges() throws {
        for change in 0..<5 {
            let fixture = ContextFixture()
            let (defaults, domain) = isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: domain) }
            let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
            try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
            let id = try #require(fixture.currentPlaylistID)
            switch change {
            case 0: fixture.playlists[id]?.name = "原创修改清单"
            case 1: fixture.playlists[id]?.token = UUID()
            case 2: fixture.playlists[id]?.ids.append(Fixtures.pidB)
            case 3: fixture.playlists[id]?.isSmart = true
            default: fixture.playlists[id]?.isFolder = true
            }
            try context.cleanupOnQuit {}
            #expect(fixture.playlists[id] != nil && fixture.removedIDs.isEmpty)
            #expect(recordCount(defaults) == 0, "用户修改后释放所有权，不再把用户清单视为临时清单")
        }
    }

    @Test("删除失败或停止后用户恢复播放保留记录，下次可重试")
    func deletionFailureKeepsRecord() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
        fixture.removalError = MusicPlaybackContextError(stage: .cleanup, appleEventCode: -1712)
        #expect(throws: MusicPlaybackContextError.self) { try context.cleanupOnQuit {} }
        #expect(recordCount(defaults) == 1 && fixture.playlists.count == 1)
        fixture.removalError = nil
        fixture.onRemove = { _ in fixture.isPlaying = true }
        #expect(throws: MusicPlaybackContextError.self) { try context.cleanupOnQuit {} }
        #expect(recordCount(defaults) == 1 && fixture.removedIDs.isEmpty)
        fixture.onRemove = nil
        let restarted = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try restarted.cleanupOnQuit {}
        #expect(recordCount(defaults) == 0 && fixture.playlists.isEmpty)
    }

    @Test("逐项清理及时保存；取消后不发后续删除，余下记录保留")
    func cancellationKeepsRemainingRecords() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        fixture.unconfirmedStartError = CancellationError()
        for id in [Fixtures.pidA, Fixtures.pidB] {
            #expect(throws: CancellationError.self) {
                try context.play([id], startingAt: id, in: .library, shuffleEnabled: false) {}
            }
        }
        #expect(recordCount(defaults) == 2)
        #expect(throws: CancellationError.self) {
            try context.cleanupOnQuit {
                if !fixture.removedIDs.isEmpty { throw CancellationError() }
            }
        }
        #expect(fixture.removedIDs.count == 1 && recordCount(defaults) == 1)
        try context.cleanupOnQuit {}
        #expect(fixture.playlists.isEmpty && recordCount(defaults) == 0)
    }

    @Test("退出新模板不启动 Music；删除前完整成员之后再次核对播放状态；首曲校验仍有效")
    func cleanupTemplateSafeguards() throws {
        let ownership = MusicPlaybackContextOwnership(playlistID: Fixtures.pidB, token: UUID(), trackIDs: [Fixtures.pidA])
        let cleanup = try MusicPlaybackContextScripts.remove(ownership, allowStoppedCurrent: true)
        let membersEnd = try #require(cleanup.range(of: "if actualIDs is not"))
        let deletion = try #require(cleanup.range(of: "delete targetPlaylist"))
        let lastCheck = cleanup[membersEnd.upperBound..<deletion.lowerBound]
        #expect(lastCheck.contains("set cleanupState to player state"))
        #expect(lastCheck.contains("persistent ID of current playlist"))
        #expect(cleanup.contains("if application id \"com.apple.Music\" is not running then error number -600"))
        #expect(MusicPlaybackContextScripts.stopForCleanup.contains("stop\n"))
        #expect(MusicPlaybackContextScripts.stopForCleanup.contains(MusicPlaybackContextScripts.cleanupStoppedState))
        #expect(throws: MusicLibraryError.invalidRequest) {
            try MusicPlaybackContextScripts.start(ownership, at: Fixtures.pidB, shuffleEnabled: nil, reuse: true)
        }
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let domain = "ShinMusicScript.lifecycle-test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }

    private func recordCount(_ defaults: UserDefaults) -> Int {
        MusicPlaybackContext.ownedPlaylistNames(defaults: defaults).count
    }
}
