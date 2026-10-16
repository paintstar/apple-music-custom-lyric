import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices
import ShinLyricsProvider

// 原创夹具 + URLProtocol 挂起实际 provider 请求，验证 App 自动获取的跨 await 边界。
private enum CheckError: Error { case failed(String) }

private actor FixtureLibrary: MusicLibraryBrowsing {
    var members: [String: [MusicLibraryTrack]]
    var failedPlaylists: Set<String> = []
    init(_ members: [String: [MusicLibraryTrack]]) { self.members = members }
    func fail(_ playlist: String) { failedPlaylists.insert(playlist) }
    func recover(_ playlist: String) { failedPlaylists.remove(playlist) }
    func setTracks(_ tracks: [MusicLibraryTrack], in playlist: String) { members[playlist] = tracks }
    func prepareMusicInBackground() async throws {}
    func loadPlaylists() async throws -> [MusicLibraryPlaylist] {
        members.keys.sorted().map { MusicLibraryPlaylist(id: $0, name: "原创歌单\($0)") }
    }
    func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        guard case let .playlist(id) = source else { throw MusicLibraryError.unsupported }
        if failedPlaylists.contains(id) { throw MusicLibraryError.sourceUnavailable }
        let tracks = members[id] ?? []
        return MusicLibraryTrackPage(tracks: tracks, totalCount: tracks.count, nextOffset: nil)
    }
    func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws {
        throw MusicLibraryError.unsupported
    }
}

private final class HTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let tracks: [Int64: MusicLibraryTrack]
    private var currentSong: Int64 = 0
    private var held: FixtureURLProtocol?
    private var holdNextLyrics: Bool
    private var holdSong: Int64?
    private var failuresRemaining: [Int64: Int]
    private var lyricCounts: [Int64: Int] = [:]
    private var searchCounts: [String: Int] = [:]

    init(tracks: [Int64: MusicLibraryTrack], hold: Bool = false, holdSong: Int64? = nil, failures: [Int64: Int] = [:]) {
        self.tracks = tracks
        holdNextLyrics = hold
        self.holdSong = holdSong
        failuresRemaining = failures
    }
    var hasHeldResponse: Bool { lock.withLock { held != nil } }
    func lyricsCount(_ id: Int64) -> Int { lock.withLock { lyricCounts[id, default: 0] } }
    func searchesCount(_ title: String) -> Int { lock.withLock { searchCounts[title, default: 0] } }
    func selectSong(_ id: Int64) { lock.withLock { currentSong = id } }

    func receive(_ transport: FixtureURLProtocol) {
        guard let url = transport.request.url else {
            transport.reject(); return
        }
        if url.host == NeteaseLyricsClient.apiHost, url.path == NeteaseLyricsClient.searchPath {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "s" })?.value
            guard let (id, track) = tracks.first(where: { _, track in
                query == "\(track.title) \(track.artist ?? "")"
            }) else {
                transport.reject(); return
            }
            lock.withLock { searchCounts[track.title, default: 0] += 1 }
            let object: [String: Any] = ["code": 200, "result": ["songs": [[
                "id": id, "name": track.title, "duration": track.durationMs ?? 20_000,
                "artists": [["name": track.artist ?? "原创歌手"]]
            ]]]]
            transport.respond(data: try! JSONSerialization.data(withJSONObject: object), status: 200)
            return
        }
        guard url.host == NeteaseLyricsClient.eapiHost, url.path == NeteaseLyricsClient.eapiLyricPath else {
            transport.reject(); return
        }
        let decision: (hold: Bool, fail: Bool) = lock.withLock {
            lyricCounts[currentSong, default: 0] += 1
            let fail = failuresRemaining[currentSong, default: 0] > 0
            if fail { failuresRemaining[currentSong, default: 0] -= 1 }
            if holdNextLyrics || holdSong == currentSong {
                holdNextLyrics = false
                holdSong = nil
                held = transport
                return (true, fail)
            }
            return (false, fail)
        }
        if !decision.hold { deliver(transport, fail: decision.fail) }
    }

    func release() throws {
        let transport = lock.withLock { () -> FixtureURLProtocol? in
            defer { held = nil }
            return held
        }
        guard let transport else { throw CheckError.failed("请求未进入挂起点") }
        deliver(transport, fail: false)
    }
    private func deliver(_ transport: FixtureURLProtocol, fail: Bool) {
        let lyrics = "[00:01.000]纸舟慢慢越过晨光\n[00:06.000]窗边留下一片晴朗"
        let object: [String: Any] = ["code": 200, "lrc": ["lyric": lyrics]]
        transport.respond(data: try! JSONSerialization.data(withJSONObject: object), status: fail ? 503 : 200)
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    private let requestLock = NSLock()
    private var stopped = false
    nonisolated(unsafe) private static var fixture: HTTPFixture?
    static func install(_ fixture: HTTPFixture) { stateLock.withLock { Self.fixture = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.stateLock.withLock({ Self.fixture }) else { reject(); return }
        fixture.receive(self)
    }
    override func stopLoading() { requestLock.withLock { stopped = true } }
    func reject() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    func respond(data: Data, status: Int) {
        guard !requestLock.withLock({ stopped }) else { return }
        guard let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)
        else { reject(); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureFetchService: LyricsFetchServicing {
    let fixture: HTTPFixture
    let client: NeteaseLyricsClient
    init(_ fixture: HTTPFixture) {
        self.fixture = fixture
        FixtureURLProtocol.install(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        client = NeteaseLyricsClient(session: URLSession(configuration: configuration), minimumRequestInterval: 0)
    }
    func searchSongs(query: String) async throws -> [NeteaseSongCandidate] { try await client.searchSongs(query: query) }
    func fetchLyrics(songId: Int64) async throws -> NeteaseLyrics {
        fixture.selectSong(songId)
        return try await client.fetchLyrics(songId: songId)
    }
}

private actor ManualSearchFixture: LyricsFetchServicing {
    private(set) var keywords: [String] = []
    let candidates: [NeteaseSongCandidate]
    init(candidates: [NeteaseSongCandidate] = []) { self.candidates = candidates }
    func searchSongs(query: String) async throws -> [NeteaseSongCandidate] {
        keywords.append(query)
        return candidates
    }
    func fetchLyrics(songId: Int64) async throws -> NeteaseLyrics {
        NeteaseLyrics(songId: songId, originalLRC: "[00:01.000]原创纸舟沿岸出发", translatedLRC: nil)
    }
}

private final class SilentSubscription: PlaybackSubscriptionHandle, @unchecked Sendable { func cancel() {} }
private final class SilentController: PlaybackController, @unchecked Sendable {
    func snapshot() -> PlaybackSnapshot { PlaybackSnapshot() }
    func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle {
        SilentSubscription()
    }
    func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws {}
    func seek(positionMs: Int64) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    func dispose() {}
}

@main
private struct AutoFetchCheck {
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckError.failed(message) }
    }
    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition() {
            if clock.now >= deadline { throw CheckError.failed("等待超时：\(message)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func track(_ id: String, _ title: String) -> MusicLibraryTrack {
        MusicLibraryTrack(persistentID: id, title: title, artist: "原创歌手甲", durationMs: 20_000)
    }
    @MainActor static func makeStore(_ root: URL, _ name: String) throws -> GRDBLyricsStore {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
    }
    @MainActor static func configure(_ model: AutoFetchModel, playlists: [String]) async throws {
        try await model.repository.saveSettings(AutoFetchSettings(isEnabled: true, playlistIDs: playlists))
        for id in playlists {
            try await model.repository.saveSnapshot(PlaylistMembershipSnapshot(
                playlistID: id, playlistName: "原创歌单\(id)", memberTrackKeys: []
            ))
        }
        await model.reloadState()
    }

    @MainActor static func manualWins(_ root: URL) async throws {
        let song = track("FA000001", "晨光纸舟")
        let store = try makeStore(root, "manual-wins")
        let http = HTTPFixture(tracks: [1001: song], hold: true)
        let model = AutoFetchModel(store: store, library: FixtureLibrary(["A": [song]]), fetchService: FixtureFetchService(http))
        try await configure(model, playlists: ["A"])
        let refresh = Task { await model.refreshNow() }
        try await wait("歌词 HTTP 已挂起") { http.hasHeldResponse }
        let manual = LyricDocument(lines: [LyricLine(startMs: 0, text: "人工留下原创的一行")])
        let binding = SongBinding(persistentID: song.persistentID, lyricDocumentId: manual.id)
        try await store.save(document: manual, binding: binding)
        try http.release()
        await refresh.value
        try require(try await store.document(forTrackKey: song.trackRef) == manual, "自动结果替换了人工歌词")
        try require(try await store.binding(forTrackKey: song.trackRef) == binding, "自动结果改写了人工绑定")
        try require(try await store.allDocuments().count == 1, "自动管线留下孤立文档")
        print("PASS 请求挂起期间人工保存优先，自动结果不换绑、不留孤立文档")
    }

    @MainActor static func failedPlaylistProtects(_ root: URL) async throws {
        let song = track("FA000002", "晴窗星影")
        let store = try makeStore(root, "failed-playlist")
        let provenance = FetchProvenance(provider: "netease", externalRef: "netease:song:1002", matchKind: .autoHigh,
                                         queryTitle: song.title, queryArtist: song.artist)
        let document = LyricDocument(metadata: provenance.metadataFields(fetchedAt: LyricTimestamp.now(), revisionAtFetch: 1),
                                     lines: [LyricLine(startMs: 0, text: "星影落在原创晴窗")])
        try require(document.isAutoFetched && document.isUneditedSinceFetch && !document.hasManualTranslation,
                    "夹具必须满足自动删除候选条件")
        try await store.save(document: document, binding: SongBinding(persistentID: song.persistentID, lyricDocumentId: document.id))
        let library = FixtureLibrary(["A": [], "B": [song]])
        await library.fail("B")
        let http = HTTPFixture(tracks: [1002: song])
        let model = AutoFetchModel(store: store, library: library, fetchService: FixtureFetchService(http))
        try await configure(model, playlists: ["A", "B"])
        for id in ["A", "B"] {
            try await model.repository.saveSnapshot(PlaylistMembershipSnapshot(
                playlistID: id, playlistName: "原创歌单\(id)", memberTrackKeys: [song.trackRef]
            ))
        }
        await model.refreshNow()
        try require(try await store.document(forTrackKey: song.trackRef) == document,
                    "B 读取失败时无法证明离开所有歌单，不应删除歌词")
        try require(model.lastRunSummary?.contains("暂缓清理") == true, "歌单读取失败未说明暂缓清理")
        await library.recover("B")
        await model.refreshNow()
        try require(try await store.document(forTrackKey: song.trackRef) == document,
                    "读取恢复后歌曲仍属于 B，不应清理")
        await library.setTracks([], in: "B")
        await model.refreshNow()
        try require(try await store.document(id: document.id) == nil,
                    "读取恢复且移出所有歌单后未清理自动歌词")
        print("PASS A 移出而 B 读取失败时保留；读取恢复后按实际成员准确清理")
    }

    @MainActor static func failedFetchRetries(_ root: URL) async throws {
        let failed = track("FA000010", "慢云小桥")
        let succeeded = track("FA000011", "暖风湖面")
        let store = try makeStore(root, "retry")
        let http = HTTPFixture(tracks: [1010: failed, 1011: succeeded], failures: [1010: 1])
        let model = AutoFetchModel(store: store, library: FixtureLibrary(["A": [failed, succeeded]]), fetchService: FixtureFetchService(http))
        try await configure(model, playlists: ["A"])
        await model.refreshNow()
        try require(try await store.binding(forTrackKey: failed.trackRef) == nil, "首次失败被当成成功")
        try require(try await store.binding(forTrackKey: succeeded.trackRef) != nil, "同轮成功项未落位")
        await model.refreshNow()
        try require(try await store.binding(forTrackKey: failed.trackRef) != nil, "第二轮未重试首次失败项")
        try require(http.lyricsCount(1010) == 2 && http.lyricsCount(1011) == 1, "失败项/成功项的请求去重错误")
        await model.refreshNow()
        try require(http.lyricsCount(1010) == 2 && http.lyricsCount(1011) == 1, "成功基准仍重复取词")
        try require(http.searchesCount(succeeded.title) == 1, "已成功项仍重复搜索")
        print("PASS 失败项第二轮重试，成功项不重复搜索或取词")
    }

    @MainActor static func partialProgressSurvivesRestart(_ root: URL, interrupt: Bool) async throws {
        let succeeded = track("FA000040", "晨岸竹影")
        let unfinished = track("FA000041", "长桥微雨")
        let store = try makeStore(root, interrupt ? "interrupted-restart" : "failed-restart")
        let library = FixtureLibrary(["A": [succeeded, unfinished]])
        let http = HTTPFixture(tracks: [1040: succeeded, 1041: unfinished],
                               holdSong: interrupt ? 1041 : nil, failures: interrupt ? [:] : [1041: 1])
        let model = AutoFetchModel(store: store, library: library, fetchService: FixtureFetchService(http))
        try await configure(model, playlists: ["A"])
        if interrupt {
            let refresh = Task { await model.refreshNow() }
            try await wait("成功项落位后第二项请求挂起") { http.hasHeldResponse }
            try require(try await store.binding(forTrackKey: succeeded.trackRef) != nil,
                        "中断前第一项必须已成功落位")
            refresh.cancel()
            try http.release()
            await refresh.value
        } else {
            await model.refreshNow()
        }
        guard let saved = try await store.document(forTrackKey: succeeded.trackRef) else {
            throw CheckError.failed("部分完成轮次未保留成功项")
        }
        try require(saved.isAutoFetched && saved.isUneditedSinceFetch, "成功夹具不是未编辑的自动歌词")
        try require(try await store.binding(forTrackKey: unfinished.trackRef) == nil, "失败或中断项意外落库")
        await library.setTracks([unfinished], in: "A")
        // 使用相同持久化库创建全新模型，不复用原模型的内存队列或运行令牌。
        let restarted = AutoFetchModel(store: store, library: library, fetchService: FixtureFetchService(http))
        await restarted.refreshNow()
        try require(try await store.binding(forTrackKey: succeeded.trackRef) == nil,
                    "成功项在失败/中断后移出歌单，重启后仍遗留绑定")
        try require(try await store.document(id: saved.id) == nil, "成功项移出后未清理自动文档")
        try require(try await store.binding(forTrackKey: unfinished.trackRef) != nil, "重启后未继续未完成项")
        try require(http.lyricsCount(1040) == 1 && http.searchesCount(succeeded.title) == 1,
                    "已成功且移出的歌曲重复获取")
        try require(http.lyricsCount(1041) == 2, "未完成项没有准确重试一次")
        await restarted.refreshNow()
        try require(http.lyricsCount(1040) == 1 && http.lyricsCount(1041) == 2, "重启完成后仍重复获取")
        print(interrupt
              ? "PASS 部分成功后中断并重建模型：移出成功项仍清理，未完成项准确重试"
              : "PASS A 成功/B 失败后移出 A 并重建模型：A 清理、B 重试、成功项不重复获取")
    }

    @MainActor static func settingsInvalidate(_ root: URL, disable: Bool) async throws {
        let song = track(disable ? "FA000020" : "FA000021", disable ? "木叶轻声" : "远岸风铃")
        let store = try makeStore(root, disable ? "disabled" : "selection")
        let http = HTTPFixture(tracks: [1020: song], hold: true)
        let model = AutoFetchModel(store: store, library: FixtureLibrary(["A": [song]]), fetchService: FixtureFetchService(http))
        try await configure(model, playlists: ["A"])
        let refresh = Task { await model.refreshNow() }
        try await wait("配置变更前请求已挂起") { http.hasHeldResponse }
        if disable {
            await model.setEnabled(false)
            let afterDisable = try await store.currentSnapshot()
            try http.release()
            await refresh.value
            try require(await model.repository.loadSettings().isEnabled == false, "停用设置未持久化")
            try require(try await store.currentSnapshot() == afterDisable, "停用后旧轮继续写入持久化状态")
        } else {
            let change = Task { await model.togglePlaylist("A") }
            try await wait("取消歌单选择已生效") { model.settings.playlistIDs.isEmpty }
            try http.release()
            await refresh.value
            await change.value
            try require(await model.repository.loadSettings().playlistIDs.isEmpty, "歌单选择未持久化")
            try require(await model.repository.snapshot(playlistID: "A") == nil, "取消勾选未清除旧快照")
        }
        try require(try await store.allDocuments().isEmpty, "配置变更期间旧 HTTP 结果仍落库")
        try require(await model.repository.pendingItems().isEmpty, "配置变更期间旧结果进入待确认")
        print(disable ? "PASS 停用使挂起结果失效" : "PASS 更改歌单选择使挂起结果失效")
    }

    @MainActor static func storageSwitchStopsOldRun(_ root: URL) async throws {
        let song = track("FA000030", "浅湾新月")
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let store = try makeStore(root, "source")
        let kept = LyricDocument(lines: [LyricLine(startMs: 0, text: "手工保留的一页月光")])
        try await store.save(document: kept, binding: SongBinding(persistentID: "FA000031", lyricDocumentId: kept.id))
        let app = AppModel(isMock: false, controller: SilentController(), searchService: nil, makeLyricsDatabase: {
            LyricsDatabase.Database(store: store, locationDescription: "原创检查源库", directory: source)
        })
        await app.start()  // 初始未启用自动获取，不发网络请求。
        let http = HTTPFixture(tracks: [1030: song], hold: true)
        let oldModel = AutoFetchModel(store: store, library: FixtureLibrary(["A": [song]]), fetchService: FixtureFetchService(http))
        app.autoFetch = oldModel
        try await configure(oldModel, playlists: ["A"])
        let refresh = Task { await oldModel.refreshNow() }
        try await wait("切目录前歌词请求已挂起") { http.hasHeldResponse }
        let before = try await store.currentSnapshot()
        let switching = Task { await app.switchLyricsStorage(to: target) }
        try await wait("保存位置切换已暂停旧自动获取") { oldModel.isSuspended && app.isSwitchingStorage }
        try require(!FileManager.default.fileExists(atPath: target.appendingPathComponent("lyrics.sqlite").path),
                    "旧请求尚未退出就复制了数据库")
        try http.release()
        await refresh.value
        await switching.value
        try require(app.lyricsDatabaseDirectory?.path == target.path && app.lyricsStore !== store, "未切换到新库")
        try require(app.autoFetch !== oldModel && oldModel.isSuspended, "切换后旧自动获取模型仍可执行")
        try require(try await store.currentSnapshot() == before, "切换期间旧轮改写了旧库")
        let copied = try GRDBLyricsStore(path: target.appendingPathComponent("lyrics.sqlite").path)
        try require(try await copied.currentSnapshot() == before, "复制快照被旧请求结果污染")
        await oldModel.refreshNow()
        try require(http.lyricsCount(1030) == 1, "切换后旧模型仍发出新请求")
        try require(try await copied.currentSnapshot() == before, "旧模型复用改写了新库")
        print("PASS 真实 AppModel 切目录先停止旧轮，旧库与复制快照保持一致")
    }

    @MainActor static func resourceDeletionStopsQueuedWork(_ root: URL) async throws {
        let first = track("FA000060", "原创晨曦纸船")
        let target = track("FA000061", "原创山间云窗")
        let other = track("FA000062", "原创湖畔小灯")
        let store = try makeStore(root, "resource-deletion")
        let kept = LyricDocument(lines: [LyricLine(startMs: 0, text: "用户准备放弃的原创云窗歌词")])
        try await store.save(document: kept, binding: SongBinding(persistentID: target.persistentID, lyricDocumentId: kept.id))
        let library = FixtureLibrary(["A": [first, target, other]])
        let http = HTTPFixture(tracks: [1060: first, 1061: target, 1062: other], holdSong: 1060)
        let model = AutoFetchModel(store: store, library: library, fetchService: FixtureFetchService(http))
        try await configure(model, playlists: ["A"])
        try await model.repository.enqueuePending(PendingAutoFetchItem(
            trackKey: target.trackRef, title: target.title, artist: target.artist,
            topCandidateTitle: nil, topCandidateArtist: nil
        ))
        let refresh = Task { await model.refreshNow() }
        try await wait("删前第一项 HTTP 挂起") { http.hasHeldResponse }
        let revision = model.stateRevision
        let settingChange = Task { await model.setEnabled(true) }
        try await wait("设置变更使旧轮失效") { model.stateRevision > revision }
        var queuedRefreshEntered = false
        let queuedRefresh = Task {
            queuedRefreshEntered = true
            await model.refreshNow()
        }
        try await wait("另一轮刷新已排队") { queuedRefreshEntered }
        let clock = ContinuousClock()
        let started = clock.now
        let shouldResume = try await model.suspendForResourceDeletion(trackKeys: [target.trackRef])
        try require(clock.now - started < .seconds(2), "资源删除仍在等待整个 HTTP 超时")
        try require(shouldResume && model.isSuspended, "资源删除未持有自动获取暂停")
        await refresh.value
        await queuedRefresh.value
        await settingChange.value
        try require(!model.isRefreshing, "取消后旧刷新仍在运行")
        try http.release() // 已取消 URLProtocol 不应再回写旧响应。
        try require(try await model.repository.workItems().allSatisfy {
            $0.kind != .fetch || $0.trackKey != target.trackRef
        }, "目标歌曲的获取待办未持久移除")
        try require(await model.repository.pendingItems().allSatisfy { $0.trackKey != target.trackRef }, "目标待确认项未移除")
        _ = try await store.deleteAssociation(forTrackKey: target.trackRef,
                                             expectedDocumentId: kept.id, expectedRevision: kept.revision)
        model.resume()
        await model.refreshNow()
        try require(try await store.document(forTrackKey: target.trackRef) == nil, "主动刷新重抓了用户删除的歌词")
        try require(http.searchesCount(target.title) == 0 && http.lyricsCount(1061) == 0, "删除后没有成员变化却重新请求目标")
        let firstBinding = try await store.binding(forTrackKey: first.trackRef)
        let otherBinding = try await store.binding(forTrackKey: other.trackRef)
        try require(firstBinding != nil && otherBinding != nil, "其他歌曲未继续既有获取待办")
        try require(!(await model.repository.ignoredTrackKeys()).contains(target.trackRef), "资源删除误加永久忽略清单")
        await library.setTracks([first, other], in: "A")
        await model.refreshNow()
        await library.setTracks([first, target, other], in: "A")
        await model.refreshNow()
        try require(try await store.binding(forTrackKey: target.trackRef) != nil && http.lyricsCount(1061) == 1,
                    "真实移出再加入后目标歌曲未按新成员变化获取")
        print("PASS 显式删除取消旧轮及排队刷新，清目标持久待办；其他工作继续，再次入歌单可重新获取")
    }

    @MainActor static func resourceDeletionFailureRestoresState(_ root: URL) async throws {
        let store = try makeStore(root, "resource-deletion-failure")
        let model = AutoFetchModel(store: store, library: FixtureLibrary([:]),
                                   fetchService: FixtureFetchService(HTTPFixture(tracks: [:])))
        try await store.setSettingValue("damaged-json", forKey: AutoFetchStore.workKey)
        for alreadySuspended in [false, true] {
            if alreadySuspended { try await model.suspendAndWait() }
            do {
                _ = try await model.suspendForResourceDeletion(trackKeys: ["music-script:persistent:FA000063"])
                throw CheckError.failed("损坏待办应拒绝删除准备")
            } catch is ShinAppleDataError {}
            try require(model.isSuspended == alreadySuspended, "准备删除失败未恢复原暂停状态")
        }
        model.resume()
        print("PASS 删除准备失败恢复此前暂停状态，不让自动获取永久暂停")
    }

    @MainActor static func verifyOnlineTitlePrefill() async throws {
        let examples = [
            ("  原创晨岸 \n", "原创晨岸"),
            ("原创晨岸(feat. 纸灯)", "原创晨岸"),
            ("原创晨岸 [现场]", "原创晨岸"),
            ("原创晨岸(现场) [客席]", "原创晨岸"),
            ("原创晨岸（现场）［客席］", "原创晨岸"),
            ("原创晨岸（现场［客席（纸灯）］）", "原创晨岸"),
            ("原创晨岸[现场 (客席)]", "原创晨岸"),
            ("原创(纸舟)晨岸 [现场]", "原创(纸舟)晨岸"),
            ("原创[纸舟]晨岸", "原创[纸舟]晨岸"),
            ("原创晨岸(现场", "原创晨岸(现场"),
            ("原创晨岸[现场)", "原创晨岸[现场)"),
            ("原创晨岸（现场］", "原创晨岸（现场］"),
            ("(原创晨岸)", "(原创晨岸)"),
            (" ［原创晨岸］(现场) ", "［原创晨岸］(现场)")
        ]
        for (raw, expected) in examples {
            let query = LyricsMatchQuery(title: raw, artist: "纸舟乐队", durationMs: 20_000)
            let target = ImportSessionTarget(trackKey: "music-script:persistent:FA000054", titleHint: raw)
            let model = NeteaseLyricsFetchModel(service: ManualSearchFixture(), matchQuery: query, target: target)
            try require(model.queryTitle == expected, "末尾括号附注回填错误：\(raw)")
            try require(model.matchQuery == query && model.target == target, "回填清理改写了原始匹配或导入目标")
        }
        let returned = [
            NeteaseSongCandidate(songId: 1070, title: "原创晨岸 (Live)", artists: ["纸舟乐队"], durationMs: 20_000),
            NeteaseSongCandidate(songId: 1071, title: "原创晨岸 [翻唱]", artists: ["纸舟乐队"], durationMs: 20_000)
        ]
        let service = ManualSearchFixture(candidates: returned)
        let model = NeteaseLyricsFetchModel(
            service: service,
            matchQuery: LyricsMatchQuery(title: "原创晨岸 (Live)", artist: "纸舟乐队", durationMs: 20_000),
            target: ImportSessionTarget(trackKey: "music-script:persistent:FA000054", titleHint: "原创晨岸 (Live)")
        )
        await model.search()
        try require(await service.keywords == ["原创晨岸 纸舟乐队"], "首次搜索没有发送清理后的歌名及默认歌手")
        guard case let .candidates(ranked) = model.phase else { throw CheckError.failed("未收到手动搜索候选") }
        try require(ranked.map(\.candidate).sorted { $0.songId < $1.songId } == returned,
                    "搜索候选的原始版本信息被清理或遗漏")
        model.queryTitle = "  用户原创曲 [自选版]  "
        await model.search()
        try require(await service.keywords.last == "用户原创曲 [自选版] 纸舟乐队", "用户手填括号内容被再次清理")
    }

    @MainActor static func onlineFetchPrefillsCurrentSong() async throws {
        try await verifyOnlineTitlePrefill()
        let app = AppModel(isMock: false, controller: SilentController(), searchService: nil)
        let rawTitle = "  原创晨岸(feat. 纸灯) [现场] \n"
        var snapshot = PlaybackSnapshot(trackEpoch: 1, title: rawTitle, artist: "  纸舟乐队 \n",
                                        durationMs: 20_000, status: .paused,
                                        trackRef: "music-script:persistent:FA000050")
        app.applySnapshot(snapshot)
        app.beginOnlineFetch()
        guard let opened = app.lyricsFetchModel else { throw CheckError.failed("未打开在线获取") }
        try require(opened.queryTitle == "原创晨岸" && opened.matchQuery.title == rawTitle
                    && opened.target.titleHint == rawTitle, "当前曲目没有仅清理默认搜索歌名")
        try require(app.selectedSong == nil && opened.queryArtist == "纸舟乐队", "真实歌曲未回填快照歌手")
        try require(opened.target.artistHint == "纸舟乐队" && opened.matchQuery.artist == "纸舟乐队",
                    "导入目标与搜索匹配歌手不一致")
        opened.queryArtist = "用户填写的原创歌手"
        opened.queryTitle = "用户输入原创曲 [自选版]"
        snapshot.trackEpoch += 1
        snapshot.trackRef = "music-script:persistent:FA000051"
        snapshot.title = "新曲原创歌名（重录）"
        snapshot.artist = "新曲原创歌手"
        app.applySnapshot(snapshot)
        try require(app.lyricsFetchModel === opened && opened.queryArtist == "用户填写的原创歌手"
                    && opened.queryTitle == "用户输入原创曲 [自选版]" && opened.matchQuery.title == rawTitle
                    && opened.target.trackKey == "music-script:persistent:FA000050"
                    && opened.matchQuery.artist == "纸舟乐队", "切歌覆盖了弹窗输入或固定目标")
        for artist: String? in [nil, " \n\t"] {
            snapshot.artist = artist
            app.applySnapshot(snapshot)
            app.beginOnlineFetch()
            try require(app.lyricsFetchModel?.queryArtist == "" && app.lyricsFetchModel?.target.artistHint == nil,
                        "未知或空白歌手未保持为空")
        }

        let selected = SongSummary(identity: CatalogIdentity(storefront: "test", catalogSongId: "artist-prefill"),
                                   title: "原创旧曲", artistName: "旧曲原创歌手", durationMs: 20_000)
        let catalogApp = AppModel(isMock: false, controller: SilentController(), searchService: MockCatalogSearchService())
        catalogApp.play(selected)
        snapshot.track = selected.identity
        snapshot.trackRef = nil
        snapshot.artist = nil
        catalogApp.applySnapshot(snapshot)
        catalogApp.beginOnlineFetch()
        try require(catalogApp.lyricsFetchModel?.queryArtist == selected.artistName, "同一曲目的目录歌手未回退")
        snapshot.track = nil
        snapshot.trackRef = "music-script:persistent:FA000052"
        catalogApp.applySnapshot(snapshot)
        catalogApp.beginOnlineFetch()
        try require(catalogApp.lyricsFetchModel?.queryArtist == "", "不同曲目借用了旧选中歌曲的歌手")
        let pending = PendingAutoFetchItem(trackKey: "music-script:persistent:FA000053", title: "原创待确认［练习版］",
                                          artist: "待确认原创歌手", topCandidateTitle: nil, topCandidateArtist: nil)
        app.beginOnlineFetch(for: pending)
        try require(app.lyricsFetchModel?.queryArtist == pending.artist
                    && app.lyricsFetchModel?.queryTitle == "原创待确认"
                    && app.lyricsFetchModel?.target.titleHint == pending.title, "待确认项未正确回填自身歌名和歌手")
        print("PASS 在线获取默认清理歌名末尾附注，回填当前歌手，保留目标/候选及用户输入")
    }

    @MainActor static func importedLyricsRefreshBeforeBatchEnds(_ root: URL) async throws {
        let playing = track("FA000071", "原创晴窗纸舟")
        let waiting = track("FA000072", "原创岸边晚灯")
        let store = try makeStore(root, "live-panel-refresh")
        let http = HTTPFixture(tracks: [1071: playing, 1072: waiting], holdSong: 1072)
        let app = AppModel(isMock: false, controller: SilentController(), searchService: nil)
        app.applySnapshot(PlaybackSnapshot(trackEpoch: 1, positionMs: 1_500, durationMs: 20_000,
                                           status: .paused, trackRef: playing.trackRef))
        app.installLyricsServiceGraph(store: store, note: "原创测试临时歌词库")
        guard let panel = app.lyricsPanel else { throw CheckError.failed("歌词面板未创建") }
        app.refreshLyricsPanel()
        try await wait("首次获取前歌词面板无绑定") { panel.state == .unbound && panel.displayedTrackEpoch == 1 }
        let model = AutoFetchModel(store: store, library: FixtureLibrary(["A": [playing, waiting]]),
                                   fetchService: FixtureFetchService(http))
        model.onLibraryChanged = { [weak app] in app?.refreshLyricsPanel() }
        app.autoFetch = model
        try await configure(model, playlists: ["A"])
        let refresh = Task { await model.refreshNow() }
        try await wait("第二首歌词请求挂起") { http.hasHeldResponse }
        guard let document = try await store.document(forTrackKey: playing.trackRef) else {
            throw CheckError.failed("第一首歌词应已提交数据库")
        }
        await app.library?.refresh()
        try require(app.library?.items.contains { $0.documentId == document.id && $0.bindingCount == 1 } == true,
                    "缓存资源应能看到当前歌曲已保存歌词")
        // 后面的 HTTP 仍未结束，已成功写入的当前歌曲应立即显示。
        do {
            try await wait("整轮未结束时当前歌词已显示") { panel.currentDocumentId == document.id }
        } catch {
            model.invalidateCurrentRun()
            try http.release()
            await refresh.value
            throw error
        }
        model.invalidateCurrentRun()
        try http.release()
        await refresh.value
        try require(panel.currentDocumentId == document.id, "后续取消不得撤回已显示的歌词")
        print("PASS 当前歌词在批量获取尚未完成时即时显示，后续取消不遗留无歌词状态")
    }

    @MainActor static func main() async {
        do {
            guard let fakeHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
                throw CheckError.failed("缺少临时 HOME 隔离配置")
            }
            try require(NSHomeDirectory() == fakeHome, "HOME 隔离未生效，拒绝运行")
            try require(URLProtocol.registerClass(FixtureURLProtocol.self), "HTTP 拦截器注册失败")
            defer { URLProtocol.unregisterClass(FixtureURLProtocol.self) }
            let root = URL(fileURLWithPath: fakeHome).deletingLastPathComponent().appendingPathComponent("databases")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            UserDefaults.standard.removeObject(forKey: LyricsDatabase.overrideDefaultsKey)
            defer { UserDefaults.standard.removeObject(forKey: LyricsDatabase.overrideDefaultsKey) }
            try await manualWins(root)
            try await failedPlaylistProtects(root)
            try await failedFetchRetries(root)
            try await partialProgressSurvivesRestart(root, interrupt: false)
            try await partialProgressSurvivesRestart(root, interrupt: true)
            try await settingsInvalidate(root, disable: true)
            try await settingsInvalidate(root, disable: false)
            try await storageSwitchStopsOldRun(root)
            try await onlineFetchPrefillsCurrentSong()
            try await resourceDeletionStopsQueuedWork(root)
            try await resourceDeletionFailureRestoresState(root)
            try await importedLyricsRefreshBeforeBatchEnds(root)
            print("auto-fetch-check：12 项模型集成场景通过；真实 Music/网络未访问。")
        } catch {
            FileHandle.standardError.write(Data("FAIL auto-fetch-check：\(error)\n".utf8))
            exit(1)
        }
    }
}
