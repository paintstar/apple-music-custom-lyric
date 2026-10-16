import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct MusicPlaybackFastPathTests {
    private let ids = ["0000000000000001", "0000000000000002", "0000000000000003"]

    @Test("原生首曲整单快路不复制，非首曲旋转完整列表而非点播单曲")
    func nativePlayback() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        let source = MusicLibrarySource.playlist(id: Fixtures.pidB)
        fixture.nativeSources[source] = ids
        try context.play(ids, startingAt: ids[0], in: source, shuffleEnabled: false) {}
        #expect(fixture.currentPlaylistID == Fixtures.pidB && fixture.creationCount == 0)
        try context.play(ids, startingAt: ids[1], in: source, shuffleEnabled: false) {}
        #expect(fixture.currentIDs == [ids[1], ids[2], ids[0]] && fixture.playedID == ids[1])
        #expect(fixture.currentPlaylistID != Fixtures.pidB && fixture.creationCount == 1)
        #expect(fixture.nativeSources[source] == ids)
        let copies = fixture.appendCount
        let managedID = fixture.currentPlaylistID
        try context.play(ids, startingAt: ids[1], in: source, shuffleEnabled: nil) {}
        #expect(fixture.currentPlaylistID == managedID && fixture.appendCount == copies)
        fixture.nativeSources[.library] = ids
        try context.play(ids, startingAt: ids[0], in: .library, shuffleEnabled: nil) {}
        #expect(fixture.currentPlaylistID == Fixtures.pidA && fixture.creationCount == 1)
    }

    @Test("187首非首曲保持全部成员且按起点旋转，不能退回455首资料库")
    func completeRotation() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        let library = (1...455).map { String(format: "%016X", $0) }
        let visible = Array(library.prefix(187))
        fixture.nativeSources[.library] = library
        fixture.nativeSources[.playlist(id: Fixtures.pidB)] = visible
        try context.play(visible, startingAt: visible[92], in: .playlist(id: Fixtures.pidB), shuffleEnabled: true) {}
        #expect(fixture.currentIDs == Array(visible[92...]) + visible[..<92])
        #expect(fixture.currentIDs.count == 187 && Set(fixture.currentIDs) == Set(visible))
        #expect(fixture.playedID == visible[92] && fixture.shuffleEnabled == true)
        #expect(fixture.appendCount == 1, "连续两段可在一批内完成，逐项回退另有事件上限")
    }

    @Test("任意筛选顺序保留所有成员；实际追加前缀推进，取消仍在批次间生效")
    func partialAppendProgressAndCancellation() throws {
        let fixture = ContextFixture()
        fixture.appendLimit = 1
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play(Array(ids.reversed()), startingAt: ids[1], in: .library, shuffleEnabled: false) {}
        #expect(fixture.currentIDs == [ids[1], ids[0], ids[2]] && fixture.appendCount == 3)
        let original = fixture.currentPlaylistID
        let before = fixture.appendCount
        #expect(throws: CancellationError.self) {
            try context.play(ids, startingAt: ids[0], in: .library, shuffleEnabled: false) {
                if fixture.appendCount > before { throw CancellationError() }
            }
        }
        #expect(fixture.currentPlaylistID == original)
    }

    @Test("连续点歌仅保留两个可复用上下文，每次成功最多回收两项，失败不否定已确认播放")
    func boundedReclamation() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        for index in 0..<18 {
            let before = fixture.removedIDs.count
            try context.play(ids, startingAt: ids[index % ids.count], in: .library, shuffleEnabled: false) {}
            #expect(fixture.playlists.count <= 2)
            #expect(fixture.removedIDs.count - before <= 2)
            #expect(fixture.playedID == ids[index % ids.count])
        }
        fixture.removalError = MusicPlaybackContextError(stage: .cleanup)
        try context.play(ids, startingAt: ids[0], in: .library, shuffleEnabled: false) {}
        #expect(fixture.playedID == ids[0] && fixture.playlists.count == 3)
        fixture.removalError = nil
        try context.cleanupOnQuit {}
        #expect(fixture.playlists.isEmpty)
    }

    @Test("多次复制后取消的残留可追赶回收，持续失败项不饿死后面的旧清单")
    func catchesUpCanceledBuildsAndRotatesFailures() throws {
        for failOldest in [false, true] {
            let fixture = ContextFixture()
            let (defaults, domain) = isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: domain) }
            let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
            for index in 0..<6 {
                let before = fixture.appendCount
                let unique = String(format: "%016X", 200 + index)
                #expect(throws: CancellationError.self) {
                    try context.play(ids + [unique], startingAt: ids[0], in: .library, shuffleEnabled: false) {
                        if fixture.appendCount > before { throw CancellationError() }
                    }
                }
            }
            #expect(fixture.playlists.count == 6 && fixture.startCount == 0)
            let oldest = try #require(fixture.playlists.keys.sorted().first)
            if failOldest {
                fixture.onRemove = { id in
                    if id == oldest { throw MusicPlaybackContextError(stage: .cleanup) }
                }
            }
            for index in 0..<8 {
                let unique = String(format: "%016X", 500 + index)
                try context.play([unique], startingAt: unique, in: .library, shuffleEnabled: false) {}
            }
            #expect(fixture.playlists.count == 2 && fixture.removedIDs.count >= 6)
            #expect(!failOldest || fixture.playlists[oldest] != nil)
        }
    }

    @Test("取消不发播放；整单模板先保存随机、关闭随机后核对首曲，失败恢复偏好")
    func cancellationAndSelectionTemplate() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        #expect(throws: CancellationError.self) {
            try context.play(ids, startingAt: ids[1], in: .library, shuffleEnabled: false) { throw CancellationError() }
        }
        #expect(fixture.operations.isEmpty)
        let ownership = MusicPlaybackContextOwnership(playlistID: Fixtures.pidB, token: UUID(), trackIDs: ids)
        for script in try [MusicPlaybackContextScripts.start(ownership, at: ids[0], shuffleEnabled: false, reuse: true),
                           MusicPlaybackContextScripts.playSource(.library, expectedIDs: ids, at: ids[0])] {
            let disable = try #require(script.range(of: "set shuffle enabled to false"))
            let first = try #require(script.range(of: "if (persistent ID of track 1 of targetPlaylist)"))
            #expect(disable.lowerBound < first.lowerBound)
            #expect(script.contains("if previousShuffle is \"true\" then set shuffle enabled to true"))
            #expect(script.contains("play targetPlaylist without once"))
            #expect(!script.contains("set fixed indexing") && !script.contains("set song repeat"))
        }
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let domain = "ShinMusicScript.fast-path-test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }
}
