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
            print("auto-fetch-check：8 项模型集成场景通过；真实 Music/网络未访问。")
        } catch {
            FileHandle.standardError.write(Data("FAIL auto-fetch-check：\(error)\n".utf8))
            exit(1)
        }
    }
}
