import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct MusicPlaybackContextTests {
    private var ids: [String] { (1...50).map { String(format: "%016X", $0) } }

    @Test("筛选播放把指定首曲置首并按批建立全部成员，再设置随机；连续播放不堆积歌单")
    func buildsAndReplacesContext() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play(ids, startingAt: ids[4], in: .library, shuffleEnabled: true) {}
        #expect(fixture.currentIDs == Array(ids[4...]) + Array(ids[..<4]))
        #expect(fixture.playedID == ids[4] && fixture.shuffleEnabled == true)
        #expect(fixture.appendCount == 3)
        #expect(fixture.playlists.count == 1)
        try context.play(Array(ids.suffix(2)), startingAt: ids[49], in: .library, shuffleEnabled: false) {}
        #expect(fixture.currentIDs == [ids[49], ids[48]])
        #expect(fixture.playlists.count == 1 && fixture.shuffleEnabled == false)
        // App 重启仍只清理经本机记录和所有权重新核对的旧专用歌单。
        let restarted = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try restarted.play([ids[0]], startingAt: ids[0], in: .library, shuffleEnabled: true) {}
        #expect(fixture.playlists.count == 1 && fixture.currentIDs == [ids[0]])
    }

    @Test("取消批次不启动旧请求，清理精确确认的暂存歌单并保留原播放")
    func cancellationBeforeStart() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play([ids[0]], startingAt: ids[0], in: .library, shuffleEnabled: false) {}
        let original = fixture.currentPlaylistID
        let previousAppends = fixture.appendCount
        #expect(throws: CancellationError.self) {
            try context.play(ids, startingAt: ids[1], in: .library, shuffleEnabled: true) {
                if fixture.appendCount > previousAppends { throw CancellationError() }
            }
        }
        #expect(fixture.currentPlaylistID == original && fixture.playlists.count == 1)
        #expect(fixture.playedID == ids[0])
    }

    @Test("用户增删成员或改变所有权后不删除；部分写入失败不推测成员、不启动播放")
    func keepsModifiedAndPartiallyWrittenPlaylists() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play(Array(ids.prefix(2)), startingAt: ids[0], in: .library, shuffleEnabled: false) {}
        let modifiedID = try #require(fixture.currentPlaylistID)
        fixture.removeLastTrack(from: modifiedID)
        try context.play([ids[2]], startingAt: ids[2], in: .library, shuffleEnabled: true) {}
        #expect(fixture.playlists[modifiedID]?.ids == [ids[0]])
        let original = fixture.currentPlaylistID
        fixture.failPartialAppend = true
        #expect(throws: MusicLibraryError.contentsChanged) {
            try context.play(ids, startingAt: ids[3], in: .library, shuffleEnabled: true) {}
        }
        #expect(fixture.currentPlaylistID == original && fixture.playedID == ids[2])
        #expect(fixture.playlists.count == 3, "成员未知时保守保留，不能按预期前缀误删")
    }

    @Test("用户把新管理歌单改成旧固定名后不再清理该歌单")
    func keepsRenamedContext() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play([ids[0]], startingAt: ids[0], in: .library, shuffleEnabled: true) {}
        let renamedID = try #require(fixture.currentPlaylistID)
        fixture.playlists[renamedID]?.name = MusicPlaybackContextScripts.playlistName
        try context.play([ids[1]], startingAt: ids[1], in: .library, shuffleEnabled: true) {}
        #expect(fixture.playlists[renamedID]?.ids == [ids[0]])
        #expect(fixture.playlists.count == 2)
    }

    @Test("上下文已播放但随机确认失败时明确报告并保留真实列表，后续重试可清理")
    func modeFailurePreservesPlayingContext() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        fixture.failShuffle = true
        #expect(throws: MusicLibraryError.playbackModeUnconfirmed) {
            try context.play(Array(ids.prefix(2)), startingAt: ids[0], in: .library, shuffleEnabled: true) {}
        }
        #expect(fixture.currentIDs == Array(ids.prefix(2)) && fixture.playlists.count == 1)
        fixture.failShuffle = false
        try context.play([ids[2]], startingAt: ids[2], in: .library, shuffleEnabled: true) {}
        #expect(fixture.currentIDs == [ids[2]] && fixture.playlists.count == 1)
    }

    @Test("play已发送但异步确认超时或取消时，失败重试不删待切换歌单；新上下文确认后才清理")
    func preservesUnconfirmedRequestsAcrossRetries() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        let failures: [any Error] = [MusicPlaybackContextError(stage: .currentPlaylist, appleEventCode: -1712), CancellationError()]
        for failure in failures {
            fixture.unconfirmedStartError = failure
            do {
                try context.play([ids[0]], startingAt: ids[0], in: .library, shuffleEnabled: true) {}
                Issue.record("应保留未确认请求并报告错误")
            } catch { }
            #expect(fixture.playlists.count == 1)
            fixture.failCreate = true
            #expect(throws: MusicPlaybackContextError.self) {
                try context.play([ids[1]], startingAt: ids[1], in: .library, shuffleEnabled: true) {}
            }
            #expect(fixture.playlists.count == 1, "紧接重试也不能抢先删除可能正在异步启动的歌单")
            fixture.failCreate = false
            fixture.unconfirmedStartError = nil
            try context.play([ids[1]], startingAt: ids[1], in: .library, shuffleEnabled: true) {}
            #expect(fixture.playlists.count == 1 && fixture.currentIDs == [ids[1]])
            fixture.currentPlaylistID = nil
        }
    }

    @Test("完整原歌单和资料库随机直接播放且不复制；筛选集合首次建立，重复随机复用准确上下文")
    func nativeAndReusedShuffleAvoidCopying() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        let source = MusicLibrarySource.playlist(id: Fixtures.pidB)
        fixture.nativeSources[source] = ids
        fixture.nativeSources[.library] = ids
        try context.shuffle(ids, in: source) {}
        #expect(fixture.currentPlaylistID == Fixtures.pidB && fixture.appendCount == 0 && fixture.playlists.isEmpty)
        #expect(fixture.nativeSources[source] == ids && fixture.shuffleEnabled == true)
        try context.shuffle(ids, in: .library) {}
        #expect(fixture.currentPlaylistID == Fixtures.pidA && fixture.appendCount == 0)
        let selection = Array(ids.prefix(10))
        try context.shuffle(selection, in: source) {}
        let ownedID = fixture.currentPlaylistID
        let copies = fixture.appendCount
        #expect(Set(fixture.currentIDs) == Set(selection) && ownedID != Fixtures.pidB && copies == 1)
        try context.shuffle(Array(selection.reversed()), in: source) {}
        #expect(fixture.currentPlaylistID == ownedID && fixture.appendCount == copies && fixture.playlists.count == 1)
        #expect(fixture.nativeSources[source] == ids, "原歌单始终保留全部成员")
    }

    @Test("复用前用户改名或成员变化时建立新上下文，不重用也不删除用户改动；native失败保留旧pending")
    func rejectsModifiedReuseAndKeepsPendingNativeFailure() throws {
        let fixture = ContextFixture()
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        let selection = Array(ids.prefix(3))
        try context.shuffle(selection, in: .library) {}
        let renamed = try #require(fixture.currentPlaylistID)
        fixture.playlists[renamed]?.name = "原创用户改名"
        try context.shuffle(selection, in: .library) {}
        #expect(fixture.currentPlaylistID != renamed && fixture.playlists[renamed] != nil)
        let modified = try #require(fixture.currentPlaylistID)
        fixture.removeLastTrack(from: modified)
        try context.shuffle(selection, in: .library) {}
        #expect(fixture.currentPlaylistID != modified && fixture.playlists[modified]?.ids.count == 2)

        fixture.unconfirmedStartError = CancellationError()
        #expect(throws: CancellationError.self) { try context.shuffle(selection, in: .library) {} }
        let pendingCount = fixture.playlists.count
        fixture.nativeSources[.playlist(id: Fixtures.pidB)] = ids
        #expect(throws: CancellationError.self) { try context.shuffle(ids, in: .playlist(id: Fixtures.pidB)) {} }
        #expect(fixture.playlists.count == pendingCount, "新原生请求未确认时不得清理上一份异步请求")
    }

    @Test("新建/引用复制/歌单启动/异步确认/随机设置/所有权删除模板通过本机公开词典编译，不发送Music事件")
    func templatesCompileAndRejectUserText() throws {
        let ownership = MusicPlaybackContextOwnership(playlistID: Fixtures.pidB, token: UUID(), trackIDs: [Fixtures.pidA])
        let scripts = try [
            MusicPlaybackContextScripts.create(token: ownership.token),
            MusicPlaybackContextScripts.append([Fixtures.pidA], to: ownership, from: .library),
            MusicPlaybackContextScripts.append([Fixtures.pidA], to: ownership, from: .playlist(id: Fixtures.pidB)),
            MusicPlaybackContextScripts.start(ownership, at: Fixtures.pidA, shuffleEnabled: true),
            MusicPlaybackContextScripts.start(ownership, at: Fixtures.pidA, shuffleEnabled: false),
            MusicPlaybackContextScripts.start(ownership, at: Fixtures.pidA, shuffleEnabled: nil),
            MusicPlaybackContextScripts.setShuffle(ownership, enabled: true),
            MusicPlaybackContextScripts.setShuffle(ownership, enabled: false),
            MusicPlaybackContextScripts.confirm(ownership, selectedID: Fixtures.pidA, shuffleEnabled: true),
            MusicPlaybackContextScripts.confirm(ownership, selectedID: nil, shuffleEnabled: nil),
            MusicPlaybackContextScripts.shuffleSource(.library, expectedIDs: [Fixtures.pidA]),
            MusicPlaybackContextScripts.shuffleSource(.playlist(id: Fixtures.pidB), expectedIDs: [Fixtures.pidA]),
            MusicPlaybackContextScripts.shuffleManaged(ownership),
            MusicPlaybackContextScripts.setSourceShuffle(Fixtures.pidB, expectedIDs: [Fixtures.pidA]),
            MusicPlaybackContextScripts.replayShuffle(Fixtures.pidB, expectedIDs: [Fixtures.pidA], ownership: nil),
            MusicPlaybackContextScripts.replayShuffle(Fixtures.pidB, expectedIDs: [Fixtures.pidA], ownership: ownership),
            MusicPlaybackContextScripts.remove(ownership)
        ]
        for source in scripts {
            let script = try #require(NSAppleScript(source: source))
            var error: NSDictionary?
            #expect(script.compileAndReturnError(&error))
            #expect(error == nil)
        }
        #expect(throws: MusicLibraryError.invalidRequest) {
            try MusicPlaybackContextScripts.append(["\" & do shell script \"example"], to: ownership, from: .library)
        }
        #expect(throws: MusicLibraryError.invalidRequest) {
            try MusicPlaybackContextScripts.append([Fixtures.pidA], to: ownership, from: .playlist(id: "untrusted"))
        }
    }

    @Test("获得OSA锁后再次检查取消，不发送已取消的上下文脚本")
    func checksCancellationInsideOSALock() {
        #expect(throws: CancellationError.self) {
            try MusicLibraryScriptExecution.execute("故意不可编译；应在构建脚本前取消") {
                throw CancellationError()
            }
        }
    }

    @Test("实际所有权模板区分用户大小写改名及描述改动，纯AppleScript执行不发送Music事件")
    func exactOwnershipTextComparison() throws {
        let ownership = MusicPlaybackContextOwnership(playlistID: Fixtures.pidB, token: UUID(), trackIDs: [], usesUniqueName: true)
        let template = try MusicPlaybackContextScripts.remove(ownership)
        let start = try #require(template.range(of: "considering case"))
        let end = try #require(template.range(of: "end considering", range: start.lowerBound..<template.endIndex))
        let comparison = String(template[start.lowerBound..<end.upperBound])
            .replacingOccurrences(of: "name of targetPlaylist", with: "targetName")
            .replacingOccurrences(of: "description of targetPlaylist", with: "targetDescription")
        let name = MusicPlaybackContextScripts.expectedName(for: ownership)
        let description = "ShinApple playback context \(ownership.token.uuidString)"
        for (testName, testDescription, expected) in [
            (name, description, "kept"), (name.lowercased(), description, "released"),
            (name, description.lowercased(), "released"), (name + " ", description, "released")
        ] {
            let script = try #require(NSAppleScript(source: """
            set targetName to "\(testName)"
            set targetDescription to "\(testDescription)"
            \(comparison)
            return "kept"
            """))
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            #expect(error == nil && result.stringValue == expected)
        }
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let domain = "ShinMusicScript.context-test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }
}

/// 内存中的原创曲目引用；测试从不启动或控制用户 Music。
private final class ContextFixture: MusicPlaybackContextExecuting, @unchecked Sendable {
    struct Playlist {
        let token: UUID
        var name: String
        var ids: [String]
    }
    var playlists: [String: Playlist] = [:]
    var currentPlaylistID: String?
    var playedID: String?
    var shuffleEnabled: Bool?
    var appendCount = 0
    var failPartialAppend = false
    var failShuffle = false
    var failCreate = false
    var unconfirmedStartError: (any Error)?
    var nativeSources: [MusicLibrarySource: [String]] = [:]
    private var creationCount = 0
    var currentIDs: [String] {
        guard let currentPlaylistID else { return [] }
        return playlists[currentPlaylistID]?.ids
            ?? nativeSources[.playlist(id: currentPlaylistID)]
            ?? (currentPlaylistID == Fixtures.pidA ? nativeSources[.library] : nil) ?? []
    }

    func create(token: UUID, checkCancellation: () throws -> Void) throws -> String {
        try checkCancellation()
        if failCreate { throw MusicPlaybackContextError(stage: .create, appleEventCode: -1728) }
        creationCount += 1
        let id = String(format: "%016X", 1_000 + creationCount)
        playlists[id] = Playlist(token: token, name: MusicPlaybackContextScripts.playlistName(for: token), ids: [])
        return id
    }

    func append(_ ids: [String], to ownership: MusicPlaybackContextOwnership, from source: MusicLibrarySource,
                checkCancellation: () throws -> Void) throws -> [String] {
        try checkCancellation()
        appendCount += 1
        if failPartialAppend {
            playlists[ownership.playlistID]?.ids.append(ids[0])
            throw MusicLibraryError.contentsChanged
        }
        playlists[ownership.playlistID]?.ids += ids
        return playlists[ownership.playlistID]?.ids ?? []
    }

    func start(_ ownership: MusicPlaybackContextOwnership, at persistentID: String, shuffleEnabled: Bool?,
               checkCancellation: () throws -> Void) throws {
        try checkCancellation()
        guard playlists[ownership.playlistID]?.ids == ownership.trackIDs else { throw MusicLibraryError.contentsChanged }
        if let unconfirmedStartError { throw unconfirmedStartError }
        currentPlaylistID = ownership.playlistID
        playedID = persistentID
        if failShuffle { throw MusicLibraryError.playbackModeUnconfirmed }
        self.shuffleEnabled = shuffleEnabled
    }

    func shuffleSource(_ ids: [String], in source: MusicLibrarySource, checkCancellation: () throws -> Void) throws -> Bool {
        try checkCancellation()
        guard let original = nativeSources[source], original.count == ids.count, Set(original) == Set(ids) else { return false }
        if let unconfirmedStartError { throw unconfirmedStartError }
        switch source {
        case .library: currentPlaylistID = Fixtures.pidA
        case let .playlist(id): currentPlaylistID = id
        }
        playedID = ids.first
        shuffleEnabled = true
        return true
    }

    func shuffleManaged(_ ownership: MusicPlaybackContextOwnership, checkCancellation: () throws -> Void) throws -> Bool {
        try checkCancellation()
        guard let playlist = playlists[ownership.playlistID], playlist.token == ownership.token,
              playlist.name == MusicPlaybackContextScripts.expectedName(for: ownership),
              playlist.ids == ownership.trackIDs else { return false }
        try start(ownership, at: ownership.trackIDs.first!, shuffleEnabled: true, checkCancellation: checkCancellation)
        return true
    }

    func remove(_ ownership: MusicPlaybackContextOwnership) throws -> Bool {
        guard let playlist = playlists[ownership.playlistID] else { return true }
        guard playlist.token == ownership.token else { return true }
        guard playlist.name == MusicPlaybackContextScripts.expectedName(for: ownership) else { return true }
        if currentPlaylistID == ownership.playlistID { return false }
        guard playlist.ids == ownership.trackIDs else { return true }
        playlists.removeValue(forKey: ownership.playlistID)
        return true
    }

    func removeLastTrack(from id: String) { playlists[id]?.ids.removeLast() }
}
